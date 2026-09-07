import ControlMyMacKit
import Foundation

/// Round-trips every message type through encode -> decode.
///
/// Cheap insurance on the part of the input path that can be checked
/// without injecting anything into whatever app happens to be focused.
enum ProtocolTest {

    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                Log.info("  ok    \(name)")
            } else {
                Log.error("  FAIL  \(name)")
                failures += 1
            }
        }

        func roundTrip(_ message: Message) -> Message? {
            let encoded = message.encoded()
            // Strip the u32 length prefix the framer would have consumed.
            guard encoded.count >= 4 else { return nil }
            let body = encoded.subdata(in: 4 ..< encoded.count)
            return try? Message.decode(body: body)
        }

        Log.info("---- protocol round-trip ----")

        if case .pointerMove(let m)? = roundTrip(.pointerMove(
            PointerMoveMessage(mode: .relative, x: -1234, y: 5678))) {
            check("pointerMove preserves negative deltas", m.x == -1234 && m.y == 5678 && m.mode == .relative)
        } else { check("pointerMove decodes", false) }

        if case .pointerButton(let m)? = roundTrip(.pointerButton(
            PointerButtonMessage(button: .right, isDown: true, clickCount: 2))) {
            check("pointerButton preserves click count", m.button == .right && m.isDown && m.clickCount == 2)
        } else { check("pointerButton decodes", false) }

        if case .scroll(let m)? = roundTrip(.scroll(
            ScrollMessage(deltaX: -7, deltaY: 42, phase: .momentum))) {
            check("scroll preserves signs and phase",
                  m.deltaX == -7 && m.deltaY == 42 && m.phase == .momentum)
        } else { check("scroll decodes", false) }

        for gesture in SystemGesture.allCases {
            if case .gesture(let m)? = roundTrip(.gesture(GestureMessage(gesture: gesture))) {
                check("gesture \(gesture.label) round-trips", m.gesture == gesture)
            } else { check("gesture \(gesture.label) decodes", false) }
        }

        if case .requestScreenshot(let m)? = roundTrip(.requestScreenshot(
            RequestScreenshotMessage(format: .png))) {
            check("requestScreenshot preserves format", m.format == .png)
        } else { check("requestScreenshot decodes", false) }

        // A megabyte of noise: the screenshot payload is far larger than
        // anything else on this wire, and it is the one message where a
        // length or offset mistake would not show up in a small case.
        let blob = Data((0..<1_000_000).map { UInt8($0 % 251) })
        if case .screenshot(let m)? = roundTrip(.screenshot(ScreenshotMessage(
            succeeded: true, format: .heic, width: 3456, height: 2234, data: blob))) {
            check("screenshot preserves a 1 MB payload byte for byte",
                  m.succeeded && m.width == 3456 && m.height == 2234 && m.data == blob)
        } else { check("screenshot decodes", false) }

        if case .screenshot(let m)? = roundTrip(.screenshot(ScreenshotMessage(
            succeeded: false, format: .heic, width: 0, height: 0,
            message: "no display to capture"))) {
            check("screenshot carries a failure reason",
                  !m.succeeded && m.message == "no display to capture" && m.data.isEmpty)
        } else { check("screenshot failure decodes", false) }

        let mods: KeyModifiers = [.command, .shift]
        if case .keyEvent(let m)? = roundTrip(.keyEvent(
            KeyEventMessage(keyCode: VirtualKey.left, isDown: true, modifiers: mods))) {
            check("keyEvent preserves modifiers", m.keyCode == VirtualKey.left && m.isDown && m.modifiers == mods)
        } else { check("keyEvent decodes", false) }

        // Non-ASCII is the whole reason text goes over as a unicode
        // string instead of keycodes, so it had better survive.
        let tricky = "hello — ünïcødé 🎉 \"quotes\""
        if case .textInput(let m)? = roundTrip(.textInput(TextInputMessage(text: tricky))) {
            check("textInput preserves unicode", m.text == tricky)
        } else { check("textInput decodes", false) }

        if case .videoFrame(let m)? = roundTrip(.videoFrame(VideoFrameMessage(
            ptsMicros: 1_234_567_890, sentAtMicros: -42, isKeyframe: true,
            payload: Data([0, 1, 2, 250, 255])))) {
            check("videoFrame preserves payload", m.ptsMicros == 1_234_567_890 && m.sentAtMicros == -42
                  && m.isKeyframe && m.payload == Data([0, 1, 2, 250, 255]))
        } else { check("videoFrame decodes", false) }

        if case .hello(let m)? = roundTrip(.hello(
            HelloMessage(channel: .control, clientName: "iPhone 17 Pro"))) {
            check("hello preserves channel and name", m.channel == .control && m.clientName == "iPhone 17 Pro")
        } else { check("hello decodes", false) }

        // A truncated body must throw, not crash or read past the end.
        let truncated = Message.pointerMove(PointerMoveMessage(mode: .relative, x: 1, y: 2)).encoded()
        let chopped = truncated.subdata(in: 4 ..< (truncated.count - 3))
        check("truncated message throws", (try? Message.decode(body: chopped)) == nil)

        check("unknown type throws", (try? Message.decode(body: Data([0xEE]))) == nil)

        Log.info("-----------------------------")
        if failures == 0 {
            Log.info("PASS: all message types round-tripped")
            return 0
        }
        Log.error("\(failures) check(s) failed")
        return 1
    }
}
