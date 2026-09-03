import CoreMedia
import Foundation

/// Where encoded frames go.
///
/// M0 implements this with a file writer to prove out capture + encode.
/// M1 swaps in a `NWConnection`-backed sink with the same shape, which
/// is the whole point of the indirection.
public protocol VideoSink: AnyObject {
    /// Called once, with the format description from the first encoded
    /// frame. Sinks that need SPS/PPS up front (the network sink will)
    /// get them from here.
    func start(formatDescription: CMFormatDescription, at presentationTime: CMTime) throws

    func consume(_ frame: EncodedFrame)

    func finish() async
}
