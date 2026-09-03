import ControlMyMacKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes received frames with VideoToolbox.
///
/// The viewer doesn't display anything yet — decoding is the point.
/// If every frame decodes, the parameter sets and AVCC payloads
/// survived the wire intact, which is exactly what M2's iOS client
/// depends on.
final class FrameDecoder {

    private var session: VTDecompressionSession?
    private let lock = NSLock()

    private(set) var decoded = 0
    private(set) var failed = 0

    init(format: CMFormatDescription) throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)

        guard status == noErr, let session else {
            throw ViewerError.decoderCreateFailed(status)
        }
        self.session = session
    }

    func decode(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            self.lock.lock()
            if status == noErr, imageBuffer != nil {
                self.decoded += 1
            } else {
                self.failed += 1
            }
            self.lock.unlock()
        }

        if status != noErr {
            lock.lock(); failed += 1; lock.unlock()
        }
    }

    func finish() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }
}

enum ViewerError: LocalizedError {
    case decoderCreateFailed(OSStatus)
    case badFormat
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .decoderCreateFailed(let s): return "Could not create the decompression session (OSStatus \(s))."
        case .badFormat: return "Could not rebuild a format description from the received parameter sets."
        case .connectionFailed(let d): return "Connection failed: \(d)"
        }
    }
}
