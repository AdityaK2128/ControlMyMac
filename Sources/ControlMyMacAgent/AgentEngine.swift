import ControlMyMacKit
import CoreMedia
import Foundation
import VideoToolbox

/// Owns the whole serving pipeline: capture, encode, network, quality,
/// power assertions and input injection.
///
/// Lifted out of the CLI serve loop so the Mac app and `--serve` drive
/// exactly the same code. They were briefly two separate wirings of the
/// same parts, which is precisely the arrangement that lets a fix land
/// in one path and quietly miss the other.
final class AgentEngine {

    struct Configuration {
        var port: UInt16 = Wire.defaultPort
        var fps: Int = 30
        var codec: CMVideoCodecType = kCMVideoCodecType_H264
        var startLevel: QualityLevel = QualityLevel.ladder[QualityLevel.defaultIndex]
        var autoQuality = true
        var allowInput = true
        var keepAwake = true
    }

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    /// Everything the UI needs, read in one shot so the numbers on
    /// screen always describe the same instant.
    struct Snapshot {
        var state: State = .stopped
        /// The configuration the engine is *running* with — not what
        /// the user has since typed into Settings. Comparing the two is
        /// what tells the UI a restart is needed, which beats a flag
        /// that forgets itself the moment you change tabs.
        var port: UInt16 = Wire.defaultPort
        var fps = 30
        var usesHEVC = false
        var keepAwake = true
        var startedAt: Date?
        var clients: [StreamServer.ClientInfo] = []
        var framesSent = 0
        var framesEncoded = 0
        var bytesSent = 0
        var framesDropped = 0
        var inputEvents = 0
        var qualityMode: QualityMode = .auto
        var qualityWidth = 0
        var outputWidth = 0
        var outputHeight = 0
        var inputAllowed = true
        var accessibilityGranted = false
        var secureInputActive = false
        /// False while listening with nobody connected: the capture
        /// stream and the encoder are torn down entirely, not merely
        /// paused.
        var isCapturing = false
        /// Set when capture failed to come up for an arriving client.
        /// Without this the phone would just see a blank screen and the
        /// Mac would look perfectly healthy.
        var captureError: String?
    }

    private let lock = NSLock()
    private var _state: State = .stopped
    private var startedAt: Date?

    private var server: StreamServer?
    private var session: CaptureSession?
    private var quality: QualityController?
    private var input: InputInjector?
    private var power: PowerManager?
    private var configuration = Configuration()

    /// Capture runs only while somebody is watching. Encoding 30fps of
    /// a screen nobody is looking at costs about half the GPU and a
    /// third of a CPU core, all day, for nothing. The listener is a
    /// socket — it costs nothing to leave waiting, which is what makes
    /// the Mac reachable at any moment without paying for it.
    private var wantsCapture = false
    private var captureTask: Task<Void, Never>?
    private var captureError: String?
    /// Bumped every time the viewer count changes, so a scheduled idle
    /// teardown can tell whether it is still the current one.
    private var idleGeneration = 0
    /// A phone that blips off Wi-Fi and straight back should not pay for
    /// a full pipeline rebuild.
    private let idleGrace: TimeInterval = 5
    private let lifecycle = DispatchQueue(label: "com.controlmymac.engine.lifecycle")

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private func setState(_ new: State) {
        lock.lock(); _state = new; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Throws rather than logging and returning, so a GUI caller can put
    /// the reason on screen instead of asking the user to read a log.
    func start(_ config: Configuration) async throws {
        guard state != .running && state != .starting else { return }
        setState(.starting)
        configuration = config

        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            setState(.failed("Screen Recording permission is required."))
            throw AgentError.permissionDenied
        }

        // Accessibility is a separate grant. Without it CGEvent.post is
        // silently dropped — but a view-only session is still useful, so
        // this is a warning, not a failure.
        let input = InputInjector()
        input.setEnabled(config.allowInput)
        if !InputInjector.isTrusted {
            Log.warn("Accessibility permission not granted — input will be ignored")
            Log.warn(InputInjector.settingsHint)
        }

        let power = PowerManager()
        if config.keepAwake {
            // A sleeping Mac leaves the tailnet entirely, so there is
            // nothing left to connect to.
            power.preventSystemSleep()
        }

        let native = ScreenCapturer.mainDisplayNativeSize()
        let server = StreamServer(port: config.port,
                                  nativeWidth: native.width,
                                  nativeHeight: native.height,
                                  input: input)

        let quality = QualityController()
        quality.setManual(width: config.startLevel.width, bitrate: config.startLevel.bitrate)
        if config.autoQuality { quality.setAuto() }

        // The session these reach for is whichever one is alive right
        // now — it is built and torn down as viewers come and go, so
        // capturing one here would pin a dead pipeline.
        server.onKeyframeRequest = { [weak self] in self?.currentSession?.requestKeyframe() }

        server.onQualityRequest = { request in
            switch request.mode {
            case .auto:   quality.setAuto()
            case .manual: quality.setManual(width: Int(request.width), bitrate: Int(request.bitrate))
            }
        }

        quality.onChange = { [weak self, weak server] level, reason, levelChanged in
            Task {
                guard let self, let server else { return }
                // With capture idle there is no encoder to reconfigure.
                // The next one to start reads the controller's current
                // rung, so the change is not lost — just deferred.
                let session = self.currentSession
                if levelChanged, let input = self.currentInput {
                    self.syncInputGeometry(for: level, input: input)
                }
                if levelChanged, let session {
                    // Only touch the encoder when the rung actually
                    // moved: a needless rebuild emits new parameter sets
                    // and a format change, which is what wedges a
                    // client's display layer.
                    await session.reconfigure(to: level)
                }
                server.announceQuality(level,
                                       height: session?.currentGeometry?.outputHeight ?? 0,
                                       mode: quality.mode,
                                       reason: reason)
            }
        }

        server.onViewersChanged = { [weak self] count in
            if config.keepAwake {
                if count > 0 {
                    // ScreenCaptureKit delivers nothing once the display
                    // sleeps, so a client connecting to an idle Mac
                    // would otherwise get a connection and a black
                    // screen.
                    power.wakeDisplay()
                    power.preventDisplaySleep()
                } else {
                    power.allowDisplaySleep()
                }
            }
            self?.viewersChanged(count)
        }

        syncInputGeometry(for: config.startLevel, input: input)

        do {
            try server.listen()
        } catch {
            server.shutdown()
            power.releaseAll()
            setState(.failed(Self.explain(error, port: config.port)))
            throw error
        }

        install(server: server, quality: quality, input: input, power: power)

        Log.info("listening on port \(config.port) — quality \(config.autoQuality ? "auto" : "fixed") at \(config.startLevel.width)p, capture idle until a device connects")
    }

    /// Tell the input injector what stream geometry to scale against,
    /// without waiting for an encoder to exist.
    ///
    /// `StreamServer.start(formatDescription:)` also sets this from the
    /// real encoded dimensions once frames flow; both use the same
    /// arithmetic, so they agree. This one just covers the window where
    /// a phone is connected and moving the cursor before the first
    /// frame has been encoded — which, with capture starting on demand,
    /// is every single connection.
    private func syncInputGeometry(for level: QualityLevel, input: InputInjector) {
        let native = ScreenCapturer.mainDisplayNativeSize()
        let size = ScreenCapturer.outputSize(nativeWidth: native.width,
                                             nativeHeight: native.height,
                                             maxWidth: level.width)
        input.setStreamSize(width: size.width, height: size.height)
    }

    // MARK: - Capture, on demand

    private var currentSession: CaptureSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    private var currentServer: StreamServer? {
        lock.lock(); defer { lock.unlock() }
        return server
    }

    private var currentInput: InputInjector? {
        lock.lock(); defer { lock.unlock() }
        return input
    }

    private func viewersChanged(_ count: Int) {
        lock.lock()
        idleGeneration &+= 1
        let generation = idleGeneration
        lock.unlock()

        guard count == 0 else {
            setWantsCapture(true)
            return
        }

        // Wait a moment before tearing down: a reconnecting phone
        // arrives within a second or two, and rebuilding the pipeline
        // for it costs more than idling through the gap.
        lifecycle.asyncAfter(deadline: .now() + idleGrace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.idleGeneration == generation
            self.lock.unlock()
            guard stillCurrent, self.currentServer?.clientCount == 0 else { return }
            self.setWantsCapture(false)
        }
    }

    /// Serialised through a chained task: start and stop must never
    /// interleave, or a teardown can land on a pipeline that a start is
    /// still building.
    private func setWantsCapture(_ wanted: Bool) {
        lock.lock()
        wantsCapture = wanted
        let previous = captureTask
        captureTask = Task { [weak self] in
            await previous?.value
            await self?.reconcileCapture()
        }
        lock.unlock()
    }

    // Everything that touches the lock is a synchronous helper. An
    // `NSLock` must not be reachable from a suspension point, and the
    // async methods below are all suspension points by definition.

    private func captureIntent() -> (wanted: Bool, running: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (wantsCapture, session != nil)
    }

    /// What a new capture session needs, taken in one consistent read.
    private func captureInputs() -> (Configuration, StreamServer, QualityLevel)? {
        lock.lock(); defer { lock.unlock() }
        guard let server else { return nil }
        // Start at whatever rung the controller is on, not at the
        // configured default — otherwise every reconnect throws away
        // what auto quality learned about the link.
        return (configuration, server, quality?.current ?? configuration.startLevel)
    }

    private func adopt(_ session: CaptureSession) {
        lock.lock(); self.session = session; captureError = nil; lock.unlock()
    }

    private func recordCaptureFailure(_ message: String) {
        lock.lock(); captureError = message; lock.unlock()
    }

    private func takeSession() -> CaptureSession? {
        lock.lock(); defer { lock.unlock() }
        let existing = session
        session = nil
        return existing
    }

    private func reconcileCapture() async {
        let (wanted, running) = captureIntent()
        if wanted && !running {
            await startCapture()
        } else if !wanted && running {
            await stopCapture()
        }
    }

    private func startCapture() async {
        guard let (config, server, level) = captureInputs() else { return }

        let session = CaptureSession(
            captureOptions: CaptureOptions(fps: config.fps, maxWidth: level.width),
            bitrate: level.bitrate,
            codec: config.codec,
            sink: server)

        do {
            try await session.start()
            adopt(session)
            Log.info("capture started for \(server.clientCount) viewer(s) at \(level.width)p")
        } catch {
            recordCaptureFailure(error.localizedDescription)
            Log.error("could not start capture: \(error.localizedDescription)")
        }
    }

    private func stopCapture() async {
        guard let session = takeSession() else { return }
        // finishSink: false — the sink is the server, and finishing it
        // would close the listener along with the encoder.
        await session.stop(finishSink: false)
        session.report()
        currentServer?.clearFormat()
        Log.info("capture stopped — idle with no viewers")
    }

    /// The pieces `stop` has to take apart, lifted out under the lock in
    /// one go. Kept synchronous deliberately: `NSLock` must not be held
    /// across a suspension point, and the compiler is right to complain
    /// when it is even reachable from one.
    private struct Teardown {
        let session: CaptureSession?
        let server: StreamServer?
        let power: PowerManager?
    }

    private func install(server: StreamServer,
                         quality: QualityController, input: InputInjector,
                         power: PowerManager) {
        lock.lock()
        self.server = server
        self.quality = quality
        self.input = input
        self.power = power
        self.startedAt = Date()
        self._state = .running
        lock.unlock()
    }

    private func detachAll() -> Teardown {
        lock.lock()
        // Invalidate any scheduled idle teardown, and stop the chain
        // from starting capture after we have pulled everything down.
        idleGeneration &+= 1
        wantsCapture = false
        captureTask?.cancel()
        captureTask = nil
        let parts = Teardown(session: session, server: server, power: power)
        session = nil; server = nil; power = nil
        quality = nil; input = nil
        startedAt = nil
        _state = .stopped
        lock.unlock()
        return parts
    }

    func stop() async {
        let parts = detachAll()
        let session = parts.session
        let server = parts.server
        let power = parts.power

        guard session != nil || server != nil else { return }
        await session?.stop(finishSink: false)
        server?.shutdown()
        power?.releaseAll()
        // The capture summary is the only place the encode-side numbers
        // are written down, so it belongs on every stop, not just the
        // command line's.
        session?.report()
        Log.info("stopped serving")
    }

    // MARK: - Running

    /// Feed the congestion signal in and let the controller decide.
    /// Called on the caller's own cadence — every 2s in practice, which
    /// is what `QualityController` assumes for its clean-second count.
    func tick() {
        lock.lock()
        let server = self.server
        let quality = self.quality
        lock.unlock()

        guard let server, let quality else { return }
        quality.recordDrops(server.takeDropsSinceLastCheck())
        // With nobody watching there is no link to measure, so climbing
        // the ladder would just encode at a higher resolution for no one.
        if server.clientCount > 0 {
            quality.evaluate()
        }
    }

    func setQuality(auto: Bool, level: QualityLevel) {
        lock.lock(); let quality = self.quality; lock.unlock()
        guard let quality else { return }
        if auto {
            quality.setManual(width: level.width, bitrate: level.bitrate)
            quality.setAuto()
        } else {
            quality.setManual(width: level.width, bitrate: level.bitrate)
        }
    }

    func setInputAllowed(_ allowed: Bool) {
        lock.lock(); let input = self.input; lock.unlock()
        input?.setEnabled(allowed)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let server = self.server
        let session = self.session
        let quality = self.quality
        let input = self.input
        let captureError = self.captureError
        var shot = Snapshot(state: _state,
                            port: configuration.port,
                            fps: configuration.fps,
                            usesHEVC: configuration.codec == kCMVideoCodecType_HEVC,
                            keepAwake: configuration.keepAwake,
                            startedAt: startedAt)
        lock.unlock()

        shot.captureError = captureError
        shot.accessibilityGranted = InputInjector.isTrusted
        shot.secureInputActive = InputInjector.isSecureInputEnabled
        shot.inputAllowed = input?.isEnabled ?? configuration.allowInput
        shot.inputEvents = input?.eventsPosted ?? 0

        if let server {
            shot.clients = server.connectedClients
            shot.framesSent = server.framesSent
            shot.bytesSent = server.bytesSent
            shot.framesDropped = server.framesDroppedForBackpressure
        }
        if let quality {
            shot.qualityMode = quality.mode
            shot.qualityWidth = quality.current.width
        }
        shot.framesEncoded = session?.encodedFrameCount ?? 0
        shot.isCapturing = session != nil
        if let geometry = session?.currentGeometry {
            shot.outputWidth = geometry.outputWidth
            shot.outputHeight = geometry.outputHeight
        }
        return shot
    }

    /// `listen()` fails with a bare POSIX error, which tells the user
    /// nothing. The port case is worth naming because it is the one that
    /// actually happens — two copies of the agent running at once.
    private static func explain(_ error: Error, port: UInt16) -> String {
        let text = error.localizedDescription
        if text.contains("Address already in use") || text.contains("48") {
            return "Port \(port) is already in use — another copy of ControlMyMac is probably running."
        }
        return text
    }
}
