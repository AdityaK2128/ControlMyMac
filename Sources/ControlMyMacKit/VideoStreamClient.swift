import CoreMedia
import Foundation
import Network

/// Client half of the protocol: connects, tracks the format, and hands
/// back ready-to-render `CMSampleBuffer`s.
///
/// Knows nothing about what happens to a frame afterwards. The macOS
/// viewer decodes and re-muxes; the iOS app enqueues into a display
/// layer. Same code path up to that point, which is the only way the
/// verification the viewer does means anything for the phone.
public final class VideoStreamClient {

    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    public struct Stats {
        public var framesReceived = 0
        public var keyframesReceived = 0
        public var bytesReceived = 0
        public var meanJitterMillis: Double = 0
        public var peakJitterMillis: Double = 0
    }

    // Callbacks fire on the client's internal queue. UI callers hop to
    // main themselves.
    public var onFrame: ((CMSampleBuffer, VideoFrameMessage) -> Void)?
    public var onFormat: ((CMFormatDescription, VideoFormatMessage) -> Void)?
    public var onServerInfo: ((ServerInfoMessage) -> Void)?
    public var onQualityChanged: ((QualityChangedMessage) -> Void)?
    public var onState: ((State) -> Void)?

    private let host: String
    private let port: UInt16
    private let clientName: String
    private let queue = DispatchQueue(label: "com.controlmymac.client")

    private var video: MessageConnection?
    private var control: MessageConnection?
    private var format: CMFormatDescription?

    private let statsLock = NSLock()
    private var _stats = Stats()
    private var transitSamples: [Int64] = []
    /// Rolling window: unbounded this grows one entry per frame forever,
    /// and only recent history is meaningful anyway.
    private let transitWindow = 600

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    public init(host: String, port: UInt16, clientName: String) {
        self.host = host
        self.port = port
        self.clientName = clientName
    }

    public var stats: Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        var snapshot = _stats
        if let min = transitSamples.min(), transitSamples.count > 1 {
            let adjusted = transitSamples.map { Double($0 - min) / 1000 }
            snapshot.meanJitterMillis = adjusted.reduce(0, +) / Double(adjusted.count)
            snapshot.peakJitterMillis = adjusted.max() ?? 0
        }
        return snapshot
    }

    // MARK: - Lifecycle

    public func connect() {
        guard video == nil else { return }
        state = .connecting

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("invalid port \(port)")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let videoConnection = MessageConnection(
            connection: NWConnection(to: endpoint,
                                     using: .controlMyMac(serviceClass: .interactiveVideo)),
            queue: queue)
        videoConnection.onReady = { [weak self] in
            guard let self else { return }
            videoConnection.send(.hello(HelloMessage(channel: .video, clientName: self.clientName)))
            self.state = .connected
        }
        videoConnection.onMessage = { [weak self] in self?.handle($0) }
        videoConnection.onError = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
        }
        videoConnection.onClosed = { [weak self] in
            guard let self else { return }
            if case .failed = self.state {} else { self.state = .idle }
        }
        videoConnection.start()
        video = videoConnection

        let controlConnection = MessageConnection(
            connection: NWConnection(to: endpoint,
                                     using: .controlMyMac(serviceClass: .responsiveData)),
            queue: queue)
        controlConnection.onReady = { [weak self] in
            guard let self else { return }
            controlConnection.send(.hello(HelloMessage(channel: .control, clientName: self.clientName)))
            // Nothing decodable has arrived yet, so ask for an IDR now
            // rather than waiting for the next scheduled one.
            controlConnection.send(.requestKeyframe)
        }
        controlConnection.start()
        control = controlConnection
    }

    public func disconnect() {
        video?.cancel()
        control?.cancel()
        video = nil
        control = nil
        format = nil
        state = .idle
    }

    public func requestKeyframe() {
        control?.send(.requestKeyframe)
    }

    // MARK: - Input

    // Sent immediately rather than coalesced. A pointer message is 13
    // bytes; even at 120Hz that is ~1.5 KB/s, and any batching we did to
    // save that would show up directly as pointer lag.

    public func sendPointerMove(dx: Int32, dy: Int32) {
        control?.send(.pointerMove(PointerMoveMessage(mode: .relative, x: dx, y: dy)))
    }

    public func sendPointerMoveAbsolute(x: Int32, y: Int32) {
        control?.send(.pointerMove(PointerMoveMessage(mode: .absolute, x: x, y: y)))
    }

    public func sendPointerButton(_ button: MouseButton, isDown: Bool, clickCount: UInt8 = 1) {
        control?.send(.pointerButton(PointerButtonMessage(button: button,
                                                          isDown: isDown,
                                                          clickCount: clickCount)))
    }

    public func sendClick(_ button: MouseButton, clickCount: UInt8 = 1) {
        sendPointerButton(button, isDown: true, clickCount: clickCount)
        sendPointerButton(button, isDown: false, clickCount: clickCount)
    }

    public func sendScroll(dx: Int32, dy: Int32) {
        control?.send(.scroll(ScrollMessage(deltaX: dx, deltaY: dy)))
    }

    public func sendKey(_ keyCode: UInt16, modifiers: KeyModifiers = []) {
        control?.send(.keyEvent(KeyEventMessage(keyCode: keyCode, isDown: true, modifiers: modifiers)))
        control?.send(.keyEvent(KeyEventMessage(keyCode: keyCode, isDown: false, modifiers: modifiers)))
    }

    public func sendText(_ text: String) {
        control?.send(.textInput(TextInputMessage(text: text)))
    }

    public func setQuality(auto: Bool, level: QualityLevel?) {
        let message = SetQualityMessage(
            mode: auto ? .auto : .manual,
            width: UInt16(clamping: level?.width ?? 0),
            bitrate: UInt32(clamping: level?.bitrate ?? 0))
        control?.send(.setQuality(message))
    }

    public func sendStats(decoded: Int, dropped: Int) {
        let snapshot = stats
        control?.send(.clientStats(ClientStatsMessage(
            framesDecoded: UInt32(clamping: decoded),
            framesDropped: UInt32(clamping: dropped),
            transitMillis: UInt16(clamping: Int(snapshot.meanJitterMillis)))))
    }

    // MARK: - Messages

    private func handle(_ message: Message) {
        switch message {
        case .serverInfo(let info):
            onServerInfo?(info)

        case .qualityChanged(let quality):
            onQualityChanged?(quality)

        case .videoFormat(let message):
            guard let format = VideoCodecSupport.makeFormatDescription(
                codec: message.codec,
                parameterSets: message.parameterSets,
                nalLengthSize: Int32(message.nalLengthSize)) else {
                state = .failed("could not rebuild format description")
                return
            }
            self.format = format
            onFormat?(format, message)

        case .videoFrame(let message):
            handleFrame(message)

        default:
            break
        }
    }

    private func handleFrame(_ message: VideoFrameMessage) {
        guard let format else { return }   // frames before format: ignore

        guard let sampleBuffer = VideoCodecSupport.makeSampleBuffer(
            payload: message.payload,
            format: format,
            presentationTime: .fromMicros(message.ptsMicros)) else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        statsLock.lock()
        _stats.framesReceived += 1
        _stats.bytesReceived += message.payload.count
        if message.isKeyframe { _stats.keyframesReceived += 1 }
        transitSamples.append(now - message.sentAtMicros)
        if transitSamples.count > transitWindow {
            transitSamples.removeFirst(transitSamples.count - transitWindow)
        }
        statsLock.unlock()

        onFrame?(sampleBuffer, message)
    }
}
