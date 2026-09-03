import ControlMyMacKit
import Foundation

/// Exercises a live resolution change.
///
/// This is the riskiest part of the quality work: SCStream is
/// reconfigured in place, but the encoder has to be rebuilt, which means
/// new parameter sets and a new keyframe. If any of that is wrong the
/// client keeps decoding against a stale format and the picture corrupts
/// rather than failing outright — so check the format actually changes.
enum QualityTest {

    static func run(host: String, port: UInt16) async -> Int32 {
        let client = VideoStreamClient(host: host, port: port, clientName: "quality-test")

        let formats = FormatLog()
        client.onFormat = { _, message in
            formats.record(width: Int(message.width), height: Int(message.height))
        }
        var framesAfterSwitch = 0
        var switched = false
        client.onFrame = { _, _ in
            if switched { framesAfterSwitch += 1 }
        }
        client.connect()

        func waitForFormats(_ count: Int, timeout: Double = 8) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if formats.count >= count { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }

        guard await waitForFormats(1) else {
            Log.error("no initial format — is the agent running?")
            return 1
        }
        let initial = formats.last!
        Log.info("initial format: \(initial.width)x\(initial.height)")

        // Pick a rung we are not already on — otherwise a previous run
        // that left the agent at 640p makes this pass without anything
        // actually changing.
        let target = initial.width == QualityLevel.ladder.last!.width
            ? QualityLevel.ladder.first!
            : QualityLevel.ladder.last!
        Log.info("requesting \(target.width)p")
        client.setQuality(auto: false, level: target)

        guard await waitForFormats(2) else {
            Log.error("resolution never changed — reconfigure failed")
            client.disconnect()
            return 1
        }
        let reduced = formats.last!
        Log.info("format after switch: \(reduced.width)x\(reduced.height)")

        switched = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Back to auto so the agent isn't left pinned at 640p.
        client.setQuality(auto: true, level: nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        client.disconnect()

        guard reduced.width == target.width else {
            Log.error("expected \(target.width)px wide, got \(reduced.width)")
            return 1
        }
        guard reduced.width != initial.width else {
            Log.error("resolution did not actually change")
            return 1
        }
        guard framesAfterSwitch > 10 else {
            Log.error("only \(framesAfterSwitch) frames after the switch — the stream stalled")
            return 1
        }
        Log.info("PASS: \(initial.width)p -> \(reduced.width)p live, \(framesAfterSwitch) frames after switch")
        return 0
    }
}

private final class FormatLog {
    private let lock = NSLock()
    private var entries: [(width: Int, height: Int)] = []

    func record(width: Int, height: Int) {
        lock.lock(); entries.append((width, height)); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var last: (width: Int, height: Int)? { lock.lock(); defer { lock.unlock() }; return entries.last }
}
