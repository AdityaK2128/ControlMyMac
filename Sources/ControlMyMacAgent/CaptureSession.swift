import ControlMyMacKit
import CoreMedia
import Foundation

/// Wires capture -> encode -> sink and keeps the numbers we care about.
///
/// Everything downstream of the capture callback runs on SCStream's
/// serial queue, so the pipeline needs no locking of its own; the stats
/// are read only after `stop()` has awaited the stream shutdown.
final class CaptureSession {

    private let capturer: ScreenCapturer
    private var encoder: VideoEncoder?
    private let sink: VideoSink
    private let captureOptions: CaptureOptions
    private let bitrate: Int
    private let codec: CMVideoCodecType

    private var sinkStarted = false
    private var framesCaptured = 0
    private var framesEncoded = 0
    private var idleFrames = 0
    private var keyframes = 0
    private var bytes = 0
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var stopError: Error?
    private var currentBitrate: Int
    /// Set from the server's queue, read on the capture queue.
    private let keyframeLock = NSLock()
    private var forceNextKeyframe = false

    init(captureOptions: CaptureOptions,
         bitrate: Int,
         codec: CMVideoCodecType,
         sink: VideoSink) {
        self.captureOptions = captureOptions
        self.bitrate = bitrate
        self.currentBitrate = bitrate
        self.codec = codec
        self.sink = sink

        // Placeholder so `self` can be captured in the handlers below.
        var frameHandler: ((CVPixelBuffer, CMTime) -> Void)!
        var idleHandler: (() -> Void)!
        var stopHandler: ((Error) -> Void)!

        self.capturer = ScreenCapturer(
            options: captureOptions,
            onFrame: { frameHandler($0, $1) },
            onIdle: { idleHandler() },
            onStop: { stopHandler($0) }
        )

        frameHandler = { [weak self] pixelBuffer, pts in
            self?.handleFrame(pixelBuffer, pts: pts)
        }
        idleHandler = { [weak self] in
            self?.idleFrames += 1
        }
        stopHandler = { [weak self] error in
            self?.stopError = error
        }
    }

    func start() async throws {
        try await capturer.start()
        guard let geometry = capturer.geometry else { throw AgentError.noDisplay }

        let encoder = VideoEncoder(
            options: EncoderOptions(
                width: geometry.outputWidth,
                height: geometry.outputHeight,
                fps: captureOptions.fps,
                bitrate: bitrate,
                codec: codec
            ),
            onEncoded: { [weak self] frame in
                self?.handleEncoded(frame)
            }
        )
        try encoder.start()
        self.encoder = encoder
    }

    /// Switch resolution and bitrate mid-stream.
    ///
    /// The capture config updates in place, but a VTCompressionSession
    /// is fixed-size, so the encoder is rebuilt — which means new
    /// parameter sets, which means clients need a fresh `videoFormat`
    /// and an IDR. Resetting `sinkStarted` is what triggers that.
    func reconfigure(to level: QualityLevel) async {
        guard let capturer = capturerForReconfigure else { return }
        do {
            let previous = capturer.geometry
            let geometry = try await capturer.reconfigure(maxWidth: level.width)

            // Nothing about the encoder's shape changed, so leave it
            // alone. Rebuilding it would emit new parameter sets and a
            // format change for no reason — and a format change is what
            // wedges a client's display layer.
            if previous?.outputWidth == geometry.outputWidth,
               previous?.outputHeight == geometry.outputHeight {
                if level.bitrate != currentBitrate {
                    // Bitrate is live-adjustable; no rebuild needed.
                    encoder?.setBitrate(level.bitrate)
                    currentBitrate = level.bitrate
                    Log.info("bitrate -> \(level.bitrate / 1_000_000) Mbps (no encoder rebuild)")
                }
                return
            }

            currentBitrate = level.bitrate
            encoder?.finish()
            let encoder = VideoEncoder(
                options: EncoderOptions(
                    width: geometry.outputWidth,
                    height: geometry.outputHeight,
                    fps: captureOptions.fps,
                    bitrate: level.bitrate,
                    codec: codec
                ),
                onEncoded: { [weak self] frame in self?.handleEncoded(frame) }
            )
            try encoder.start()

            sinkStarted = false
            self.encoder = encoder
            requestKeyframe()
        } catch {
            Log.error("could not reconfigure to \(level.width)p: \(error.localizedDescription)")
        }
    }

    private var capturerForReconfigure: ScreenCapturer? { capturer }

    var currentGeometry: CaptureGeometry? { capturer.geometry }

    /// Encode-side counters, for the app's live view. Read across queues
    /// without synchronisation, the same way the server's counters are:
    /// a stats display that is one frame stale is not a defect worth a
    /// lock on the capture path.
    var encodedFrameCount: Int { framesEncoded }
    var encodedByteCount: Int { bytes }

    /// `finishSink: false` stops capturing without closing the sink.
    ///
    /// That distinction is the whole idle mode: the network listener has
    /// to keep waiting for a phone long after there is anything to
    /// encode, and `StreamServer.finish()` shuts the listener down.
    func stop(finishSink: Bool = true) async {
        await capturer.stop()
        encoder?.finish()   // flushes any frames still in the encoder
        encoder = nil
        if finishSink {
            await sink.finish()
        }
    }

    // MARK: - Pipeline

    /// Ask for an IDR on the next captured frame. Called when a client
    /// connects mid-stream, or loses sync.
    func requestKeyframe() {
        keyframeLock.lock()
        forceNextKeyframe = true
        keyframeLock.unlock()
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        framesCaptured += 1
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts

        keyframeLock.lock()
        let requested = forceNextKeyframe
        forceNextKeyframe = false
        keyframeLock.unlock()

        // First frame is always an IDR so the file — and any client
        // that joins later — starts on something decodable.
        encoder?.encode(pixelBuffer, pts: pts, forceKeyframe: framesCaptured == 1 || requested)
    }

    private func handleEncoded(_ frame: EncodedFrame) {
        if !sinkStarted {
            guard let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer) else { return }
            do {
                try sink.start(formatDescription: format, at: frame.presentationTime)
                sinkStarted = true
            } catch {
                Log.error("sink failed to start: \(error.localizedDescription)")
                return
            }
        }
        framesEncoded += 1
        bytes += frame.byteCount
        if frame.isKeyframe { keyframes += 1 }
        sink.consume(frame)
    }

    // MARK: - Report

    func report() {
        let duration: Double = {
            guard let first = firstPTS, let last = lastPTS else { return 0 }
            return CMTimeGetSeconds(CMTimeSubtract(last, first))
        }()

        Log.info("---- capture summary ----")
        if let geometry = capturer.geometry {
            Log.info("resolution   \(geometry.nativeWidth)x\(geometry.nativeHeight) -> \(geometry.outputWidth)x\(geometry.outputHeight)")
        }
        Log.info("wall time    \(String(format: "%.2f", duration))s of frame timestamps")
        Log.info("captured     \(framesCaptured) frames (\(idleFrames) idle/deduped)")
        Log.info("encoded      \(framesEncoded) frames, \(keyframes) keyframes")
        if duration > 0 {
            let fps = Double(framesEncoded) / duration
            let mbps = Double(bytes) * 8 / duration / 1_000_000
            Log.info("effective    \(String(format: "%.1f", fps)) fps, \(String(format: "%.2f", mbps)) Mbps")
        }
        Log.info("payload      \(String(format: "%.2f", Double(bytes) / 1_048_576)) MiB encoded")
        if let stopError {
            Log.error("stream ended early: \(stopError.localizedDescription)")
        }
        Log.info("-------------------------")
    }
}
