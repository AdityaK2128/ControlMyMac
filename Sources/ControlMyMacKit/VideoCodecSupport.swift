import CoreMedia
import Foundation

/// Bridges `CMSampleBuffer` <-> wire bytes in both directions.
///
/// The receiving half is what the iOS client uses to rebuild sample
/// buffers for `AVSampleBufferDisplayLayer`, so it lives here rather
/// than in either executable.
public enum VideoCodecSupport {

    // MARK: - Sending

    /// Pull SPS/PPS (or VPS/SPS/PPS for HEVC) out of a format
    /// description so they can be sent out of band.
    public static func parameterSets(from format: CMFormatDescription,
                                     codec: VideoCodec) -> (sets: [Data], nalLengthSize: Int32)? {
        var count = 0
        var nalLengthSize: Int32 = 4

        let probe: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLengthSize)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLengthSize)

        guard probe == noErr, count > 0 else { return nil }

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, nalLengthSize)
    }

    /// Copy the encoded payload out of a sample buffer.
    ///
    /// Goes through `CMBlockBufferCopyDataBytes` rather than grabbing the
    /// data pointer: a block buffer is allowed to be non-contiguous, and
    /// reading it as if it were is the kind of bug that only shows up on
    /// large frames.
    public static func payload(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                              dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    // MARK: - Receiving

    /// Rebuild a format description from parameter sets received over
    /// the wire.
    public static func makeFormatDescription(codec: VideoCodec,
                                             parameterSets: [Data],
                                             nalLengthSize: Int32) -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }

        // Keep every set's bytes alive for the duration of the call.
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var backing: [UnsafeMutablePointer<UInt8>] = []
        defer { backing.forEach { $0.deallocate() } }

        for set in parameterSets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            backing.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(set.count)
        }

        var format: CMFormatDescription?
        let status: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: nalLengthSize,
                extensions: nil,
                formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: nalLengthSize,
                formatDescriptionOut: &format)

        return status == noErr ? format : nil
    }

    /// Wrap received AVCC bytes back into a sample buffer ready for a
    /// decompression session or `AVSampleBufferDisplayLayer`.
    public static func makeSampleBuffer(payload: Data,
                                        format: CMFormatDescription,
                                        presentationTime: CMTime,
                                        duration: CMTime = .invalid) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }

        status = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)

        return status == noErr ? sampleBuffer : nil
    }
}

public extension CMTime {
    var micros: Int64 { Int64(CMTimeGetSeconds(self) * 1_000_000) }
    static func fromMicros(_ micros: Int64) -> CMTime {
        CMTime(value: CMTimeValue(micros), timescale: 1_000_000)
    }
}
