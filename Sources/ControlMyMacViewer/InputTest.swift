import ControlMyMacKit
import CoreGraphics
import Foundation

/// Verifies the input path objectively rather than by feel.
///
/// The viewer runs on the same Mac as the agent, so it can read the real
/// cursor position before and after sending a move and check that the
/// events actually landed — including the scale conversion from stream
/// pixels to display points.
enum InputTest {

    private static var cursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func run(host: String, port: UInt16) async -> Int32 {
        let client = VideoStreamClient(host: host, port: port, clientName: "input-test")

        var streamWidth = 0
        let ready = AsyncFlag()
        client.onFormat = { _, message in
            streamWidth = Int(message.width)
            ready.signal()
        }
        client.connect()

        // Wait for the format so we know the coordinate space.
        for _ in 0..<50 where !ready.isSet {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready.isSet, streamWidth > 0 else {
            Log.error("never received a video format — is the agent running?")
            return 1
        }

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let displayWidth = bounds.width
        let scale = displayWidth / CGFloat(streamWidth)
        Log.info("stream \(streamWidth)px wide, display \(Int(displayWidth))pt — scale \(String(format: "%.3f", scale))")

        // Retry, because this measurement is only valid if nobody
        // touches the trackpad while it runs. A single nudge used to be
        // reported as "scaling is wrong", which sent me looking for a
        // bug that was not there.
        for attempt in 1...5 {
            switch await measure(client: client, scale: scale, bounds: bounds) {
            case .pass:
                client.disconnect()
                Log.info("PASS: pointer moved the expected distance and returned")
                return 0
            case .failed(let why):
                client.disconnect()
                Log.error(why)
                return 1
            case .inconclusive(let why):
                Log.warn("attempt \(attempt): \(why)")
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        client.disconnect()
        Log.error("INCONCLUSIVE: could not get a clean measurement in 5 attempts.")
        Log.error("Something else kept moving the cursor — leave the mouse alone and re-run.")
        return 3
    }

    private enum Outcome {
        case pass
        case failed(String)
        /// Measured, but something outside the test moved the cursor, so
        /// the number means nothing either way.
        case inconclusive(String)
    }

    private static func measure(client: VideoStreamClient,
                                scale: CGFloat, bounds: CGRect) async -> Outcome {
        // Watch the cursor with nothing injected. If it moves on its
        // own, a hand is on the trackpad and no measurement taken right
        // now means anything — in either axis. This catches the purely
        // horizontal nudge that the vertical-drift check below misses.
        let quiet = cursor
        try? await Task.sleep(nanoseconds: 250_000_000)
        let stillQuiet = cursor
        if abs(stillQuiet.x - quiet.x) + abs(stillQuiet.y - quiet.y) > 0.5 {
            return .inconclusive("cursor moved before the test started — something else is driving it")
        }

        let start = cursor
        Log.info("cursor before: (\(Int(start.x)), \(Int(start.y)))")

        // Deliberately small and self-reversing: this moves the real
        // cursor on someone's desktop.
        let stepPixels: Int32 = 120
        let expected = CGFloat(stepPixels) * scale

        // Near the right edge the move clamps and the distance is short
        // through no fault of the scaling. Step the other way instead.
        let direction: Int32 = (start.x + expected + 8 >= bounds.maxX) ? -1 : 1
        if direction < 0 {
            Log.info("close to the right edge — measuring leftwards instead")
        }
        guard start.x - expected - 8 > bounds.minX || direction > 0 else {
            return .inconclusive("cursor is boxed in against both edges")
        }

        client.sendPointerMove(dx: stepPixels * direction, dy: 0)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let afterMove = cursor

        client.sendPointerMove(dx: -stepPixels * direction, dy: 0)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let afterBack = cursor

        let movedBy = (afterMove.x - start.x) * CGFloat(direction)
        let returned = abs(afterBack.x - start.x)

        Log.info("cursor after \(direction > 0 ? "+" : "-")\(stepPixels)px: (\(Int(afterMove.x)), \(Int(afterMove.y)))")
        Log.info("moved \(String(format: "%.1f", movedBy))pt, expected \(String(format: "%.1f", expected))pt")

        // The test never sends any vertical delta, so any change in y is
        // proof that a hand — or another process — moved the mouse. The
        // horizontal number is then meaningless.
        let verticalDrift = abs(afterMove.y - start.y) + abs(afterBack.y - start.y)
        if verticalDrift > 2 {
            return .inconclusive("cursor drifted \(String(format: "%.0f", verticalDrift))pt vertically — something else moved the mouse")
        }

        guard abs(movedBy) > 1 else {
            return .failed("""
            cursor did not move — Accessibility permission is the usual cause
            System Settings > Privacy & Security > Accessibility
            """)
        }
        guard abs(movedBy - expected) < max(8, expected * 0.15) else {
            return .failed("moved \(String(format: "%.1f", movedBy))pt but expected \(String(format: "%.1f", expected))pt — scaling is wrong")
        }
        guard returned < 8 else {
            return .failed("cursor did not return to its starting point (off by \(String(format: "%.1f", returned))pt)")
        }

        Log.info("returned to within \(String(format: "%.1f", returned))pt of start")
        return .pass
    }

}

final class AsyncFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func signal() { lock.lock(); value = true; lock.unlock() }
}
