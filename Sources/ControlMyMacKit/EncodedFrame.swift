import CoreMedia
import Foundation

/// One encoded video frame leaving the encoder.
///
/// Deliberately carries the `CMSampleBuffer` rather than raw bytes: the
/// file sink can hand it straight to `AVAssetWriter`, and the network
/// sink (M1) can pull the block buffer out without an extra copy.
public struct EncodedFrame {
    public let sampleBuffer: CMSampleBuffer
    public let isKeyframe: Bool
    public let presentationTime: CMTime

    public init(sampleBuffer: CMSampleBuffer, isKeyframe: Bool, presentationTime: CMTime) {
        self.sampleBuffer = sampleBuffer
        self.isKeyframe = isKeyframe
        self.presentationTime = presentationTime
    }

    /// Encoded payload size in bytes, for bitrate accounting.
    public var byteCount: Int {
        CMSampleBufferGetTotalSampleSize(sampleBuffer)
    }
}
