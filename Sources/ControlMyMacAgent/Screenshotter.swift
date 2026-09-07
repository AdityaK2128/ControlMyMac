import ControlMyMacKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Takes a still of the display at its real resolution.
///
/// Deliberately not a grab of the video stream: that has already been
/// scaled down to whatever rung the link can carry, so a screenshot made
/// from it would be a 1280px-wide artefact of the network rather than a
/// picture of the screen. This captures the panel natively — 3456x2234
/// on a 16" Retina — and the phone gets something worth keeping.
enum Screenshotter {

    static func capture(format: ScreenshotFormat) async -> ScreenshotMessage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                return failure(format, "no display to capture")
            }

            // Nothing excluded, matching the live stream: if you can see
            // it on the Mac you can capture it from the phone.
            let filter = SCContentFilter(display: display,
                                         excludingApplications: [],
                                         exceptingWindows: [])

            let native = ScreenCapturer.mainDisplayNativeSize()
            let configuration = SCStreamConfiguration()
            configuration.width = native.width
            configuration.height = native.height
            configuration.showsCursor = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)

            guard let data = encode(image, as: format) else {
                return failure(format, "could not encode the image")
            }

            Log.info("screenshot: \(image.width)x\(image.height) \(format.fileExtension.uppercased()), \(String(format: "%.2f", Double(data.count) / 1_000_000)) MB")

            return ScreenshotMessage(succeeded: true,
                                     format: format,
                                     width: UInt16(clamping: image.width),
                                     height: UInt16(clamping: image.height),
                                     data: data)
        } catch {
            return failure(format, error.localizedDescription)
        }
    }

    private static func failure(_ format: ScreenshotFormat, _ why: String) -> ScreenshotMessage {
        Log.error("screenshot failed: \(why)")
        return ScreenshotMessage(succeeded: false, format: format,
                                 width: 0, height: 0, message: why)
    }

    private static func encode(_ image: CGImage, as format: ScreenshotFormat) -> Data? {
        let type: UTType = (format == .heic) ? .heic : .png
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, type.identifier as CFString, 1, nil) else { return nil }

        var options: [CFString: Any] = [:]
        if format == .heic {
            // 0.9 is visually lossless on screen content and about a
            // quarter the size of PNG. Text is where lossy codecs
            // usually fall apart; HEIC at this quality does not.
            options[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
