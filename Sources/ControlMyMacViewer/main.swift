import ControlMyMacKit
import Foundation

// M1 receiver: connects to the agent, decodes every frame, and writes
// what it received back out to an .mp4.
//
// Not a UI. Its job is to prove the wire format is correct before the
// iOS client depends on it.

struct ViewerOptions {
    var host = "127.0.0.1"
    var port: UInt16 = Wire.defaultPort
    var duration: Double = 10
    var output: URL?
    var inputTest = false
    var protocolTest = false
    var qualityTest = false
    var screenshotTest = false
    var gesture: SystemGesture?
}

func parseViewerArguments() -> ViewerOptions {
    var options = ViewerOptions()
    var args = Array(CommandLine.arguments.dropFirst())

    while let flag = args.first {
        args.removeFirst()
        func value() -> String? {
            guard let v = args.first, !v.hasPrefix("--") else { return nil }
            args.removeFirst()
            return v
        }
        switch flag {
        case "--host":     if let v = value() { options.host = v }
        case "--port":     if let v = value(), let i = UInt16(v) { options.port = i }
        case "--duration": if let v = value(), let d = Double(v) { options.duration = d }
        case "--output":   if let v = value() { options.output = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        case "--input-test": options.inputTest = true
        case "--protocol-test": options.protocolTest = true
        case "--quality-test": options.qualityTest = true
        case "--screenshot-test": options.screenshotTest = true
        case "--gesture":
            if let v = value() {
                switch v {
                case "mission":  options.gesture = .missionControl
                case "desktop":  options.gesture = .showDesktop
                case "back":     options.gesture = .navigateBack
                case "forward":  options.gesture = .navigateForward
                default: Log.warn("unknown gesture: \(v)")
                }
            }
        case "--help", "-h":
            print("""
            ControlMyMacViewer (M1)
              --host <addr>       agent address    (default 127.0.0.1)
              --port <n>          agent port       (default \(Wire.defaultPort))
              --duration <sec>    how long to receive (default 10)
              --output <path>     re-mux received frames to this .mp4
              --input-test        move the real cursor and verify it landed
              --protocol-test     round-trip every message type (offline)
              --quality-test      switch resolution mid-stream and verify
              --screenshot-test   request a still and check it is full resolution
              --gesture <name>    mission | desktop | back | forward
            """)
            exit(0)
        default:
            if !flag.hasPrefix("--") { options.host = flag }
        }
    }
    return options
}

func runViewer() async -> Int32 {
    Log.configure(name: "viewer")
    let options = parseViewerArguments()

    if options.protocolTest {
        return ProtocolTest.run()
    }

    if options.qualityTest {
        return await QualityTest.run(host: options.host, port: options.port)
    }

    if options.inputTest {
        return await InputTest.run(host: options.host, port: options.port)
    }

    if let gesture = options.gesture {
        let client = VideoStreamClient(host: options.host, port: options.port,
                                       clientName: "gesture-test")
        client.connect()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        client.sendGesture(gesture)
        Log.info("sent \(gesture.label)")
        try? await Task.sleep(nanoseconds: 600_000_000)
        client.disconnect()
        return 0
    }

    if options.screenshotTest {
        return await ScreenshotTest.run(host: options.host, port: options.port,
                                        output: options.output)
    }

    let sink = options.output.map { MP4FileSink(url: $0) }
    let client = StreamClient(host: options.host,
                              port: options.port,
                              clientName: Host.current().localizedName ?? "viewer",
                              sink: sink)

    Log.info("connecting to \(options.host):\(options.port)")
    client.connect()

    let deadline = Date().addingTimeInterval(options.duration)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        client.reportStats()
    }

    client.disconnect()
    await sink?.finish()

    let seconds = options.duration
    Log.info("---- receive summary ----")
    if let info = client.serverInfo {
        Log.info("server       stream \(info.displayWidth)x\(info.displayHeight), native \(info.nativeWidth)x\(info.nativeHeight)")
    }
    Log.info("received     \(client.framesReceived) frames, \(client.keyframesReceived) keyframes")
    Log.info("decoded      \(client.decodedCount) ok, \(client.failedCount) failed")
    Log.info("throughput   \(String(format: "%.2f", Double(client.bytesReceived) * 8 / seconds / 1_000_000)) Mbps, \(String(format: "%.2f", Double(client.bytesReceived) / 1_048_576)) MiB")
    Log.info("jitter       \(String(format: "%.1f", client.jitterMillis))ms mean, \(String(format: "%.1f", client.maxJitterMillis))ms peak")
    Log.info("-------------------------")

    guard client.framesReceived > 0 else {
        Log.error("no frames received")
        return 1
    }
    guard client.failedCount == 0 else {
        Log.error("\(client.failedCount) frames failed to decode")
        return 1
    }
    return 0
}

Task {
    let code = await runViewer()
    Log.drain()
    exit(code)
}

dispatchMain()
