import ControlMyMacKit
import CoreMedia
import Foundation
import VideoToolbox

// M0: capture the main display, encode it exactly the way the live
// stream will, and write the result to an .mp4. No networking yet —
// this milestone exists to prove out TCC permissions and the
// ScreenCaptureKit -> VideoToolbox path in isolation.

struct Options {
    var duration: Double = 10
    var fps: Int = 30
    var maxWidth: Int = 1440
    var bitrate: Int = 8_000_000
    var codec: CMVideoCodecType = kCMVideoCodecType_H264
    var output: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/ControlMyMac/m0-capture.mp4")
    var selfTest = false
    var serve = false
    /// The old default: record the screen to an .mp4 and exit.
    var capture = false
    var port: UInt16 = Wire.defaultPort
    var autoQuality = true
}

extension Options {
    /// With no mode flag the user double-clicked the app, so show the
    /// window. Every explicit mode stays on the command line.
    var isHeadless: Bool { serve || selfTest || capture }
}

func parseArguments() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while let flag = args.first {
        args.removeFirst()
        func value() -> String? {
            guard let v = args.first, !v.hasPrefix("--") else { return nil }
            args.removeFirst()
            return v
        }
        switch flag {
        case "--duration": if let v = value(), let d = Double(v) { options.duration = d }
        case "--fps":      if let v = value(), let i = Int(v) { options.fps = i }
        case "--width":    if let v = value(), let i = Int(v) { options.maxWidth = i }
        case "--bitrate":  if let v = value(), let i = Int(v) { options.bitrate = i }
        case "--codec":
            if let v = value() {
                options.codec = (v.lowercased() == "hevc") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            }
        case "--output":   if let v = value() { options.output = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        case "--selftest": options.selfTest = true
        case "--capture":  options.capture = true
        case "--serve":    options.serve = true
        case "--port":     if let v = value(), let i = UInt16(v) { options.port = i }
        case "--fixed-quality": options.autoQuality = false
        case "--help", "-h":
            print("""
            ControlMyMacAgent (M0)
              --duration <sec>    capture length          (default 10)
              --fps <n>           target frame rate       (default 30)
              --width <px>        max output width        (default 1440)
              --bitrate <bps>     average bitrate         (default 8000000)
              --codec h264|hevc   codec                   (default h264)
              --output <path>     .mp4 destination
              --capture           record the screen to an .mp4 and exit
                                  (the app opens its window without this)
              --selftest          encode synthetic frames instead of the
                                  screen; needs no TCC permission
              --serve             stream over the network instead of
                                  writing a file (duration 0 = forever)
              --port <n>          listen port             (default \(Wire.defaultPort))
              --fixed-quality     never adapt resolution automatically
            """)
            exit(0)
        default:
            Log.warn("ignoring unknown argument: \(flag)")
        }
    }
    return options
}


/// Encoder + muxer verification with no ScreenCaptureKit involved.
/// If this passes and a real capture doesn't, the problem is permissions
/// or SCStream — not the encode path.
func runSelfTest(_ options: Options) async -> Int32 {
    let width = options.maxWidth
    let height = (width * 10 / 16) & ~1
    let frameCount = Int(options.duration * Double(options.fps))

    Log.info("self-test: \(frameCount) synthetic frames at \(width)x\(height)")

    let source = SyntheticSource(width: width, height: height)
    let sink = MP4FileSink(url: options.output)

    var encoded = 0
    var keyframes = 0
    var bytes = 0
    var sinkStarted = false

    let encoder = VideoEncoder(
        options: EncoderOptions(width: width, height: height, fps: options.fps,
                                bitrate: options.bitrate, codec: options.codec),
        onEncoded: { frame in
            if !sinkStarted {
                guard let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer) else { return }
                do {
                    try sink.start(formatDescription: format, at: frame.presentationTime)
                    sinkStarted = true
                } catch {
                    Log.error("sink start failed: \(error.localizedDescription)")
                    return
                }
            }
            encoded += 1
            bytes += frame.byteCount
            if frame.isKeyframe { keyframes += 1 }
            sink.consume(frame)
        }
    )

    do {
        try encoder.start()
    } catch {
        Log.error("encoder start failed: \(error.localizedDescription)")
        return 1
    }

    for i in 0..<frameCount {
        guard let pixelBuffer = source.makeFrame(index: i) else {
            Log.error("could not allocate synthetic frame \(i)")
            return 1
        }
        let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(options.fps))
        encoder.encode(pixelBuffer, pts: pts, forceKeyframe: i == 0)
    }

    encoder.finish()
    await sink.finish()

    Log.info("---- self-test summary ----")
    Log.info("submitted    \(frameCount) frames")
    Log.info("encoded      \(encoded) frames, \(keyframes) keyframes")
    let seconds = Double(frameCount) / Double(options.fps)
    Log.info("effective    \(String(format: "%.2f", Double(bytes) * 8 / seconds / 1_000_000)) Mbps")
    Log.info("payload      \(String(format: "%.2f", Double(bytes) / 1_048_576)) MiB encoded")
    Log.info("-------------------------")

    guard encoded == frameCount else {
        Log.error("encoder returned \(encoded) of \(frameCount) frames")
        return 1
    }
    return 0
}

func run(_ options: Options) async -> Int32 {
    Log.info("ControlMyMac agent starting (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")

    if options.serve {
        return await runServe(options)
    }

    if options.selfTest {
        let code = await runSelfTest(options)
        if code == 0 {
            let path = options.output.path
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 0 {
                Log.info("wrote \(String(format: "%.2f", Double(size) / 1_048_576)) MiB to \(path)")
                return 0
            }
            Log.error("no output file at \(path)")
            return 1
        }
        return code
    }

    if !ScreenRecordingPermission.isGranted {
        Log.warn("Screen Recording permission not granted — prompting")
        ScreenRecordingPermission.request()
        // The grant does not apply to an already-running process, so
        // this run is over regardless of what the user clicks.
        if !ScreenRecordingPermission.isGranted {
            Log.error(AgentError.permissionDenied.localizedDescription)
            Log.error(ScreenRecordingPermission.settingsHint)
            return 2
        }
    }

    let sink = MP4FileSink(url: options.output)
    let session = CaptureSession(
        captureOptions: CaptureOptions(fps: options.fps, maxWidth: options.maxWidth),
        bitrate: options.bitrate,
        codec: options.codec,
        sink: sink
    )

    do {
        try await session.start()
    } catch {
        Log.error("could not start capture: \(error.localizedDescription)")
        Log.error(ScreenRecordingPermission.settingsHint)
        return 1
    }

    Log.info("capturing for \(options.duration)s — move some windows around so there's motion to encode")
    try? await Task.sleep(nanoseconds: UInt64(options.duration * 1_000_000_000))

    await session.stop()
    session.report()

    let path = options.output.path
    if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 0 {
        Log.info("wrote \(String(format: "%.2f", Double(size) / 1_048_576)) MiB to \(path)")
        return 0
    } else {
        Log.error("no output file at \(path)")
        return 1
    }
}

let launchOptions = parseArguments()
Log.configure(name: launchOptions.isHeadless ? "agent" : "app")

if launchOptions.isHeadless {
    Task {
        let code = await run(launchOptions)
        Log.drain()
        exit(code)
    }
    dispatchMain()
} else {
    // Not `@main`: this file is top-level code, which already owns the
    // entry point. `App.main()` is the supported way in.
    ControlMyMacGUI.main()
}
