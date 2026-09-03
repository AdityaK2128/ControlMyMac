import ControlMyMacKit
import CoreMedia
import Foundation
import Network

/// Accepts clients and pushes encoded frames at them.
///
/// Implements `VideoSink`, so swapping this in for `MP4FileSink` is the
/// entire difference between M0 and M1 as far as the capture pipeline
/// is concerned.
final class StreamServer: VideoSink {

    private let port: UInt16
    private let nativeSize: (width: Int, height: Int)
    private let queue = DispatchQueue(label: "com.controlmymac.server")
    private var listener: NWListener?

    /// Every mutation happens on `queue`, so no additional locking.
    private var videoClients: [ObjectIdentifier: VideoClient] = [:]
    private var controlClients: [ObjectIdentifier: ControlClient] = [:]
    /// Accepted but not yet identified by a hello. Without this the
    /// connection would be released the moment `accept` returns — its
    /// only other reference is a weak capture in its own handler.
    private var pending: [ObjectIdentifier: MessageConnection] = [:]
    private var storedFormat: VideoFormatMessage?

    /// Raised when a client asks for a fresh IDR — on connect, or after
    /// it loses sync.
    var onKeyframeRequest: (() -> Void)?
    /// Raised when a client picks a quality, or asks for auto.
    var onQualityRequest: ((SetQualityMessage) -> Void)?
    /// Raised on the first client connecting and the last disconnecting,
    /// so the agent can manage display sleep around real usage.
    var onViewersChanged: ((Int) -> Void)?

    /// A connected video client, plus the state that decides whether it
    /// is safe to send it anything yet.
    private final class VideoClient {
        let connection: MessageConnection
        let name: String
        let peer: String
        let connectedAt = Date()
        /// A client that has not yet received an IDR has no reference
        /// frame, so every P-frame it gets fails to decode. Hold them
        /// back until a keyframe goes out.
        var awaitingKeyframe = true
        /// Last stats the client reported about its own decoding. The
        /// server cannot see any of this from its end — dropped frames
        /// and jitter only exist on the receiving side.
        var reported: ClientStatsMessage?

        init(connection: MessageConnection, name: String, peer: String) {
            self.connection = connection
            self.name = name
            self.peer = peer
        }
    }

    private final class ControlClient {
        let connection: MessageConnection
        let name: String
        let peer: String
        init(connection: MessageConnection, name: String, peer: String) {
            self.connection = connection
            self.name = name
            self.peer = peer
        }
    }

    /// What the Mac app shows in its client list. A snapshot: reading it
    /// must not hand out references into the server's own state.
    struct ClientInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let peer: String
        let connectedAt: Date
        let hasControl: Bool
        let framesDecoded: Int
        let framesDropped: Int
        let jitterMillis: Int
        let streaming: Bool
    }

    private(set) var framesHeldForKeyframe = 0

    private(set) var framesSent = 0
    private(set) var framesDroppedForBackpressure = 0
    private var dropsSinceLastCheck = 0
    private(set) var bytesSent = 0

    /// Frames handed to the kernel but not yet acknowledged. Past this,
    /// the link is behind and buffering more only converts bandwidth we
    /// don't have into latency we can't hide — so non-keyframes get
    /// dropped instead.
    private let maxPendingSends = 4
    private let helloTimeout: TimeInterval = 5

    private let input: InputInjector

    init(port: UInt16, nativeWidth: Int, nativeHeight: Int, input: InputInjector) {
        self.port = port
        self.nativeSize = (nativeWidth, nativeHeight)
        self.input = input
    }

    func listen() throws {
        let params = NWParameters.controlMyMac(serviceClass: .interactiveVideo)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:  Log.info("listening on port \(self.port)")
            case .failed(let error): Log.error("listener failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func shutdown() {
        queue.sync {
            videoClients.values.forEach { $0.connection.cancel() }
            controlClients.values.forEach { $0.connection.cancel() }
            pending.values.forEach { $0.cancel() }
            videoClients.removeAll()
            controlClients.removeAll()
            pending.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    var clientCount: Int {
        queue.sync { videoClients.count }
    }

    /// Who is connected right now, for the Mac app's client list.
    ///
    /// A viewer opens two connections — video and control — and they are
    /// merged here by name, because one iPhone showing up as two rows is
    /// an implementation detail leaking into the UI.
    var connectedClients: [ClientInfo] {
        queue.sync {
            let controlNames = Set(controlClients.values.map(\.name))
            return videoClients.values
                .sorted { $0.connectedAt < $1.connectedAt }
                .map { client in
                    ClientInfo(
                        id: client.peer,
                        name: client.name,
                        peer: client.peer,
                        connectedAt: client.connectedAt,
                        hasControl: controlNames.contains(client.name),
                        framesDecoded: Int(client.reported?.framesDecoded ?? 0),
                        framesDropped: Int(client.reported?.framesDropped ?? 0),
                        jitterMillis: Int(client.reported?.transitMillis ?? 0),
                        streaming: !client.awaitingKeyframe)
                }
        }
    }

    /// Backpressure drops since the last call — the congestion signal
    /// the quality controller acts on. Reading resets it, so each
    /// evaluation window sees only its own drops.
    func takeDropsSinceLastCheck() -> Int {
        queue.sync {
            let count = dropsSinceLastCheck
            dropsSinceLastCheck = 0
            return count
        }
    }

    /// Drop the remembered parameter sets.
    ///
    /// Called when capture stops: the sets describe an encoder that no
    /// longer exists, and handing them to a client that connects during
    /// the idle window would set up a decoder for a stream it is never
    /// going to receive. Clients wait for `videoFormat` before doing
    /// anything, so sending nothing is the correct thing to send.
    func clearFormat() {
        queue.async {
            self.storedFormat = nil
            for client in self.videoClients.values {
                client.awaitingKeyframe = true
            }
        }
    }

    /// Tell every client what the quality is now, and why.
    func announceQuality(_ level: QualityLevel, height: Int,
                         mode: QualityMode, reason: QualityChangeReason) {
        queue.async {
            let message = Message.qualityChanged(QualityChangedMessage(
                width: UInt16(clamping: level.width),
                height: UInt16(clamping: height),
                bitrate: UInt32(clamping: level.bitrate),
                mode: mode,
                reason: reason))
            for client in self.videoClients.values {
                client.connection.send(message)
            }
        }
    }

    // MARK: - Accepting

    private func accept(_ connection: NWConnection) {
        let peer = Self.describe(connection.endpoint)
        let message = MessageConnection(connection: connection, queue: queue)
        let id = ObjectIdentifier(message)

        message.onMessage = { [weak self, weak message] incoming in
            guard let self, let message else { return }
            switch incoming {
            case .hello(let hello):
                self.register(message, id: id, hello: hello, peer: peer)
            case .requestKeyframe:
                Log.info("keyframe requested by \(peer)")
                self.onKeyframeRequest?()
            case .clientStats(let stats):
                self.videoClients[id]?.reported = stats
                Log.info("client \(peer): decoded \(stats.framesDecoded), dropped \(stats.framesDropped), jitter \(stats.transitMillis)ms")

            // Input arrives on the control channel, which is why it is a
            // separate connection: a stalled video send must never delay
            // a click.
            case .pointerMove(let move):
                self.input.handlePointerMove(move)
            case .pointerButton(let button):
                self.input.handlePointerButton(button)
            case .scroll(let scroll):
                self.input.handleScroll(scroll)
            case .keyEvent(let key):
                self.input.handleKeyEvent(key)
            case .textInput(let text):
                self.input.handleTextInput(text)
            case .setQuality(let quality):
                Log.info("client \(peer) requested quality: mode=\(quality.mode == .auto ? "auto" : "manual") width=\(quality.width) bitrate=\(quality.bitrate)")
                self.onQualityRequest?(quality)

            default:
                break
            }
        }
        var lastErrorLog = Date.distantPast
        message.onError = { error in
            // One line per second is plenty: a failing socket can produce
            // one error per frame.
            if Date().timeIntervalSince(lastErrorLog) > 1 {
                lastErrorLog = Date()
                Log.warn("connection \(peer): \(error.localizedDescription)")
            }
        }
        message.onClosed = { [weak self] in
            self?.remove(id: id, peer: peer)
        }
        // Hold it until the hello arrives.
        pending[id] = message
        message.start()

        // A peer that connects and never identifies itself would
        // otherwise sit in `pending` forever.
        queue.asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard let self, let stale = self.pending.removeValue(forKey: id) else { return }
            Log.warn("no hello from \(peer) within \(Int(self.helloTimeout))s — dropping")
            stale.cancel()
        }
    }

    private func register(_ message: MessageConnection, id: ObjectIdentifier,
                          hello: HelloMessage, peer: String) {
        guard hello.version == Wire.protocolVersion else {
            Log.warn("rejecting \(peer): protocol version \(hello.version), expected \(Wire.protocolVersion)")
            pending.removeValue(forKey: id)
            message.cancel()
            return
        }

        pending.removeValue(forKey: id)

        switch hello.channel {
        case .video:
            videoClients[id] = VideoClient(connection: message, name: hello.clientName, peer: peer)
            Log.info("video client connected: \(hello.clientName) @ \(peer) — holding frames until keyframe")
            onViewersChanged?(videoClients.count)

            message.send(.serverInfo(ServerInfoMessage(
                displayWidth: UInt16(storedFormat?.width ?? 0),
                displayHeight: UInt16(storedFormat?.height ?? 0),
                nativeWidth: UInt16(clamping: nativeSize.width),
                nativeHeight: UInt16(clamping: nativeSize.height))))

            // A client joining mid-stream has no parameter sets and no
            // reference frame, so it gets both immediately.
            if let format = storedFormat {
                message.send(.videoFormat(format))
                onKeyframeRequest?()
            }

        case .control:
            controlClients[id] = ControlClient(connection: message, name: hello.clientName, peer: peer)
            Log.info("control client connected: \(hello.clientName) @ \(peer)")
        }
    }

    private func remove(id: ObjectIdentifier, peer: String) {
        pending.removeValue(forKey: id)
        if videoClients.removeValue(forKey: id) != nil {
            Log.info("video client disconnected: \(peer)")
            onViewersChanged?(videoClients.count)
        }
        if controlClients.removeValue(forKey: id) != nil {
            Log.info("control client disconnected: \(peer)")
            // A connection dropped mid-drag would otherwise leave the
            // Mac with a mouse button held down forever.
            input.releaseAll()
        }
    }

    // MARK: - VideoSink

    func start(formatDescription: CMFormatDescription, at presentationTime: CMTime) throws {
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let codec: VideoCodec = (subType == kCMVideoCodecType_HEVC) ? .hevc : .h264
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        guard let (sets, nalLengthSize) = VideoCodecSupport.parameterSets(
            from: formatDescription, codec: codec) else {
            throw SinkError.writerFailed("could not extract parameter sets")
        }

        let format = VideoFormatMessage(
            codec: codec,
            width: UInt16(clamping: Int(dimensions.width)),
            height: UInt16(clamping: Int(dimensions.height)),
            nalLengthSize: UInt8(clamping: Int(nalLengthSize)),
            parameterSets: sets)

        // Clients address the pointer in stream pixels; the injector
        // needs the same reference frame to scale into display points.
        input.setStreamSize(width: Int(dimensions.width), height: Int(dimensions.height))

        queue.async {
            self.storedFormat = format
            for client in self.videoClients.values {
                client.connection.send(.videoFormat(format))
            }
        }
        Log.info("stream format: \(codec == .hevc ? "HEVC" : "H.264") \(dimensions.width)x\(dimensions.height), \(sets.count) parameter sets, \(nalLengthSize)-byte NAL prefix")
    }

    func consume(_ frame: EncodedFrame) {
        guard let payload = VideoCodecSupport.payload(from: frame.sampleBuffer) else { return }
        let pts = frame.presentationTime.micros
        let isKeyframe = frame.isKeyframe
        let sentAt = Int64(Date().timeIntervalSince1970 * 1_000_000)

        queue.async {
            guard !self.videoClients.isEmpty else { return }

            let message = Message.videoFrame(VideoFrameMessage(
                ptsMicros: pts, sentAtMicros: sentAt,
                isKeyframe: isKeyframe, payload: payload))

            var sentToAny = false
            for client in self.videoClients.values {
                // A client that hasn't had an IDR yet cannot decode a
                // P-frame — it has no reference. Sending one produces a
                // decode failure, not a picture.
                if client.awaitingKeyframe {
                    if !isKeyframe {
                        self.framesHeldForKeyframe += 1
                        continue
                    }
                    client.awaitingKeyframe = false
                    Log.info("keyframe delivered to \(client.name) — streaming")
                }

                // Keyframes always go: dropping one strands the decoder
                // until the next IDR, which is far worse than one late
                // frame.
                if !isKeyframe && client.connection.pendingSends >= self.maxPendingSends {
                    self.framesDroppedForBackpressure += 1
                    self.dropsSinceLastCheck += 1
                    continue
                }
                client.connection.send(message)
                sentToAny = true
            }
            if sentToAny {
                self.framesSent += 1
                self.bytesSent += payload.count
            }
        }
    }

    func finish() async {
        shutdown()
    }

    // MARK: - Helpers

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "\(endpoint)"
        }
    }
}
