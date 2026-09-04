import ControlMyMacKit
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CaptureOptions {
    var fps: Int = 30
    /// Retina panels are ~3456px wide. Encoding that is wasteful and the
    /// phone can't show it — downscale in the capture config so the
    /// scaling happens on the GPU before the encoder ever sees a frame.
    var maxWidth: Int = 1440
    var showsCursor: Bool = true
    var queueDepth: Int = 5
}

struct CaptureGeometry {
    let nativeWidth: Int
    let nativeHeight: Int
    let outputWidth: Int
    let outputHeight: Int
}

/// Wraps `SCStream` and hands complete frames to a callback.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {

    typealias FrameHandler = (CVPixelBuffer, CMTime) -> Void

    private var stream: SCStream?
    private let options: CaptureOptions
    private let onFrame: FrameHandler
    private let onIdle: () -> Void
    private let onStop: (Error) -> Void
    private let queue = DispatchQueue(label: "com.controlmymac.capture", qos: .userInteractive)

    private(set) var geometry: CaptureGeometry?
    /// Kept so the stream can be reconfigured without rediscovering
    /// shareable content, which is slow and re-checks permissions.
    private var display: SCDisplay?
    private var currentMaxWidth: Int

    init(options: CaptureOptions,
         onFrame: @escaping FrameHandler,
         onIdle: @escaping () -> Void = {},
         onStop: @escaping (Error) -> Void = { _ in }) {
        self.options = options
        self.currentMaxWidth = options.maxWidth
        self.onFrame = onFrame
        self.onIdle = onIdle
        self.onStop = onStop
    }

    func start() async throws {
        // This call is also the real permission check: without a Screen
        // Recording grant it throws rather than returning empty content.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw AgentError.noDisplay
        }

        let geometry = Self.geometry(for: display, maxWidth: options.maxWidth)
        self.geometry = geometry
        self.display = display

        // Capture the display exactly as it looks — nothing excluded.
        //
        // This used to filter out our own process, which made sense when
        // the agent was headless and had no UI worth seeing. Now that it
        // is a real app with a dashboard, excluding it meant the one
        // window you might actually want to reach from the phone — to
        // change quality, or to stop sharing — was the one window you
        // could not see. There is no feedback loop to worry about: the
        // Mac app shows numbers, never the video.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = makeConfiguration(for: geometry)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        Log.info("capture started: \(geometry.nativeWidth)x\(geometry.nativeHeight) native -> \(geometry.outputWidth)x\(geometry.outputHeight) @ \(options.fps)fps")
    }

    private func makeConfiguration(for geometry: CaptureGeometry) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = geometry.outputWidth
        config.height = geometry.outputHeight
        // Feeds VideoToolbox with no pixel-format conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = options.queueDepth
        config.showsCursor = options.showsCursor
        config.scalesToFit = true
        return config
    }

    /// Change capture resolution without tearing the stream down.
    ///
    /// `updateConfiguration` keeps the same SCStream, so there is no
    /// second permission check and no gap in frames — unlike stopping
    /// and restarting, which drops roughly a second of video.
    @discardableResult
    func reconfigure(maxWidth: Int) async throws -> CaptureGeometry {
        guard let stream, let display else { throw AgentError.noDisplay }
        guard maxWidth != currentMaxWidth else { return geometry ?? Self.geometry(for: display, maxWidth: maxWidth) }

        let geometry = Self.geometry(for: display, maxWidth: maxWidth)
        try await stream.updateConfiguration(makeConfiguration(for: geometry))
        self.geometry = geometry
        self.currentMaxWidth = maxWidth
        Log.info("capture reconfigured -> \(geometry.outputWidth)x\(geometry.outputHeight)")
        return geometry
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Log.info("capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit dedupes: on a static screen it delivers frames
        // marked .idle with no image buffer. Treating those as dropped
        // frames (or worse, as a dead link) is the classic SCK bug.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return }

        switch status {
        case .complete:
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
        case .idle, .blank, .suspended, .started, .stopped:
            onIdle()
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("stream stopped with error: \(error.localizedDescription)")
        onStop(error)
    }

    // MARK: - Geometry

    /// Backing resolution of the main display, without touching
    /// ScreenCaptureKit — so it works before any permission check.
    static func mainDisplayNativeSize() -> (width: Int, height: Int) {
        let id = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
        }
        return (Int(mode.pixelWidth), Int(mode.pixelHeight))
    }

    /// SCDisplay reports points; SCStreamConfiguration wants pixels. Ask
    /// CoreGraphics for the real backing resolution rather than guessing
    /// a 2x scale factor.
    static func geometry(for display: SCDisplay, maxWidth: Int) -> CaptureGeometry {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeW = mode.map { Int($0.pixelWidth) } ?? display.width
        let nativeH = mode.map { Int($0.pixelHeight) } ?? display.height

        let output = outputSize(nativeWidth: nativeW, nativeHeight: nativeH, maxWidth: maxWidth)
        return CaptureGeometry(nativeWidth: nativeW, nativeHeight: nativeH,
                               outputWidth: output.width, outputHeight: output.height)
    }

    /// The encoded size a given rung will produce, computed from the
    /// display alone.
    ///
    /// Separated out so callers can know the stream geometry *before*
    /// any capture exists. Pointer scaling depends on it, and with
    /// capture starting on demand there is a window where a client is
    /// connected and sending input but no frame has been encoded yet.
    static func outputSize(nativeWidth: Int, nativeHeight: Int,
                           maxWidth: Int) -> (width: Int, height: Int) {
        var outW = nativeWidth
        var outH = nativeHeight
        if nativeWidth > maxWidth {
            let scale = Double(maxWidth) / Double(nativeWidth)
            outW = maxWidth
            outH = Int((Double(nativeHeight) * scale).rounded())
        }
        // H.264 wants even dimensions; 4:2:0 chroma is subsampled by 2.
        outW -= outW % 2
        outH -= outH % 2
        return (outW, outH)
    }
}
