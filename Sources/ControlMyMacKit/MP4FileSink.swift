import AVFoundation
import CoreMedia
import Foundation

/// M0's sink: encoded frames straight to an .mp4, no re-encoding.
///
/// `AVAssetWriterInput` with nil `outputSettings` is passthrough mode, so
/// what lands on disk is byte-for-byte what the encoder produced. That's
/// the point — playing the file back verifies the exact bitstream the
/// network sink will ship in M1.
public final class MP4FileSink: VideoSink {

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var droppedFrames = 0

    public private(set) var frameCount = 0
    public private(set) var byteCount = 0

    public init(url: URL) {
        self.url = url
    }

    public func start(formatDescription: CMFormatDescription, at presentationTime: CMTime) throws {
        // A quality change mid-stream produces a second format. An mp4
        // track has one resolution for its whole life, so keep writing
        // the original rather than truncating the file and starting over.
        guard writer == nil else {
            Log.warn("format changed mid-recording — continuing with the original resolution")
            return
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SinkError.writerFailed("cannot add passthrough video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw SinkError.writerFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: presentationTime)

        self.writer = writer
        self.input = input
        Log.info("writing to \(url.path)")
    }

    public func consume(_ frame: EncodedFrame) {
        guard let input, writer?.status == .writing else { return }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        if input.append(frame.sampleBuffer) {
            frameCount += 1
            byteCount += frame.byteCount
        } else {
            Log.warn("append failed: \(writer?.error?.localizedDescription ?? "unknown")")
        }
    }

    public func finish() async {
        guard let writer, let input else { return }
        input.markAsFinished()
        await writer.finishWriting()
        if droppedFrames > 0 {
            Log.warn("dropped \(droppedFrames) frames (writer not ready)")
        }
        if writer.status == .failed {
            Log.error("writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }
}
