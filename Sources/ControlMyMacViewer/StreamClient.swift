import ControlMyMacKit
import CoreMedia
import Foundation

/// Verification harness around `VideoStreamClient`.
///
/// Adds the two things the iOS app doesn't need — a decode pass to prove
/// every frame is valid, and a re-mux so the result can be played back.
final class StreamClient {

    private let client: VideoStreamClient
    private let sink: MP4FileSink?
    private var decoder: FrameDecoder?
    private var sinkStarted = false
    private let lock = NSLock()

    private(set) var serverInfo: ServerInfoMessage?

    init(host: String, port: UInt16, clientName: String, sink: MP4FileSink?) {
        self.sink = sink
        self.client = VideoStreamClient(host: host, port: port, clientName: clientName)

        client.onServerInfo = { [weak self] info in
            self?.serverInfo = info
            Log.info("server: stream \(info.displayWidth)x\(info.displayHeight), native \(info.nativeWidth)x\(info.nativeHeight)")
        }

        client.onFormat = { [weak self] format, message in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            do {
                self.decoder?.finish()
                self.decoder = try FrameDecoder(format: format)
                Log.info("decoder ready: \(message.codec == .hevc ? "HEVC" : "H.264") \(message.width)x\(message.height), \(message.parameterSets.count) parameter sets")
            } catch {
                Log.error(error.localizedDescription)
            }
        }

        client.onFrame = { [weak self] sampleBuffer, message in
            guard let self else { return }
            self.decoder?.decode(sampleBuffer)

            guard let sink = self.sink else { return }
            if !self.sinkStarted {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                do {
                    try sink.start(formatDescription: format,
                                   at: .fromMicros(message.ptsMicros))
                    self.sinkStarted = true
                } catch {
                    Log.error("sink: \(error.localizedDescription)")
                    return
                }
            }
            sink.consume(EncodedFrame(sampleBuffer: sampleBuffer,
                                      isKeyframe: message.isKeyframe,
                                      presentationTime: .fromMicros(message.ptsMicros)))
        }

        client.onState = { state in
            switch state {
            case .connecting: Log.info("connecting")
            case .connected:  Log.info("connected")
            case .failed(let why): Log.warn("stream: \(why)")
            case .idle: break
            }
        }
    }

    func connect() { client.connect() }

    func disconnect() {
        client.disconnect()
        decoder?.finish()
    }

    func reportStats() {
        client.sendStats(decoded: decodedCount, dropped: failedCount)
    }

    var stats: VideoStreamClient.Stats { client.stats }
    var framesReceived: Int { client.stats.framesReceived }
    var keyframesReceived: Int { client.stats.keyframesReceived }
    var bytesReceived: Int { client.stats.bytesReceived }
    var decodedCount: Int { decoder?.decoded ?? 0 }
    var failedCount: Int { decoder?.failed ?? 0 }
    var jitterMillis: Double { client.stats.meanJitterMillis }
    var maxJitterMillis: Double { client.stats.peakJitterMillis }
}
