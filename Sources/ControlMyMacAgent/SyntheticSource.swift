import ControlMyMacKit
import CoreMedia
import CoreVideo
import Foundation

/// Generates moving 4:2:0 frames so the encoder + muxer can be verified
/// without a Screen Recording grant.
///
/// Worth having permanently: when the pipeline misbehaves, this isolates
/// "capture is broken" from "encode/mux is broken" in one run.
final class SyntheticSource {

    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        self.pool = pool
    }

    /// A diagonal sweep plus a moving block — enough real motion that the
    /// resulting bitrate numbers mean something, unlike a static pattern
    /// that the encoder would squash to nothing.
    func makeFrame(index: Int) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Luma plane
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let blockX = (index * 11) % max(width - 120, 1)
            let blockY = (index * 7) % max(height - 120, 1)
            for y in 0..<height {
                let row = ptr + y * stride
                for x in 0..<width {
                    let inBlock = x >= blockX && x < blockX + 120 && y >= blockY && y < blockY + 120
                    row[x] = inBlock ? 235 : UInt8((x + y + index * 4) & 0xFF)
                }
            }
        }

        // Chroma plane (half resolution, Cb/Cr interleaved)
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let chromaHeight = height / 2
            let chromaWidth = width / 2
            for y in 0..<chromaHeight {
                let row = ptr + y * stride
                for x in 0..<chromaWidth {
                    row[x * 2]     = UInt8((x + index * 2) & 0xFF)   // Cb
                    row[x * 2 + 1] = UInt8((y + index * 3) & 0xFF)   // Cr
                }
            }
        }

        return buffer
    }
}
