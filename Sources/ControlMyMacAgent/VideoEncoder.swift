import CoreMedia
import ControlMyMacKit
import Foundation
import VideoToolbox

struct EncoderOptions {
    var width: Int
    var height: Int
    var fps: Int = 30
    var bitrate: Int = 8_000_000          // 8 Mbps; M5 drives this at runtime
    var codec: CMVideoCodecType = kCMVideoCodecType_H264
    /// Long GOP + on-demand IDR. Periodic keyframes just burn bitrate
    /// when the receiver can ask for one whenever it actually needs it.
    var maxKeyFrameInterval: Int = 600
}

/// VTCompressionSession tuned for interactive streaming rather than
/// archival quality. The settings here are the ones that decide whether
/// the remote desktop feels immediate or soupy.
final class VideoEncoder {

    typealias Output = (EncodedFrame) -> Void

    private var session: VTCompressionSession?
    private let options: EncoderOptions
    private let onEncoded: Output

    init(options: EncoderOptions, onEncoded: @escaping Output) {
        self.options = options
        self.onEncoded = onEncoded
    }

    func start() throws {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(options.width),
            height: Int32(options.height),
            codecType: options.codec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            // nil callback => must use the block-based encode entry point.
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw AgentError.encoderCreateFailed(status)
        }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, true as CFBoolean)
        // No B-frames. Reordering costs a frame of latency and buys
        // nothing for screen content.
        set(kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean)
        set(kVTCompressionPropertyKey_ProfileLevel,
            options.codec == kCMVideoCodecType_HEVC
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, options.maxKeyFrameInterval as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, options.fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, options.bitrate as CFNumber)
        // Hard ceiling over a 1s window; keeps a burst from blowing out
        // the phone's jitter buffer on cellular.
        let bytesPerSecond = options.bitrate / 8
        set(kVTCompressionPropertyKey_DataRateLimits,
            [bytesPerSecond, 1] as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)

        let codecName = options.codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
        Log.info("encoder ready: \(codecName) \(options.width)x\(options.height) @ \(options.fps)fps, \(options.bitrate / 1_000_000) Mbps")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        guard let session else { return }

        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        let duration = CMTime(value: 1, timescale: CMTimeScale(options.fps))

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer, sampleBuffer.isValid else {
                if status != noErr { Log.warn("encode callback status \(status)") }
                return
            }
            self.onEncoded(EncodedFrame(
                sampleBuffer: sampleBuffer,
                isKeyframe: Self.isKeyframe(sampleBuffer),
                presentationTime: sampleBuffer.presentationTimeStamp
            ))
        }

        if status != noErr {
            Log.warn("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    /// Runtime bitrate change — the hook M5's adaptive controller drives.
    func setBitrate(_ bitrate: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1] as CFArray)
    }

    func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Helpers

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            Log.warn("could not set \(key): \(status)")
        }
    }

    /// A sample is a sync frame unless it's explicitly tagged NotSync.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }
}
