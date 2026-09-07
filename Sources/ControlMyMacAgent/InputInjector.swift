import ApplicationServices
import Carbon
import AppKit
import ControlMyMacKit
import CoreGraphics
import Foundation

/// Turns wire input messages into real `CGEvent`s.
///
/// Requires the Accessibility permission. Without it `CGEvent.post` is
/// silently swallowed — no error, no events — which is why the agent
/// checks up front and says so rather than looking merely broken.
final class InputInjector {

    /// Size of the encoded stream, in pixels. Clients send coordinates
    /// in this space; the display is in points, so everything gets
    /// scaled on arrival.
    private var streamSize: CGSize = .zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<MouseButton> = []
    private let lock = NSLock()

    /// Where we believe the cursor is, independent of the window server.
    ///
    /// Reading the live position before every move looks more correct but
    /// races badly: at 120Hz the previous move has not landed yet, so we
    /// add the new delta to a stale base and motion is randomly lost or
    /// doubled. Integrating locally and resyncing only after a pause
    /// keeps fast movement smooth while still noticing the real mouse.
    private var virtualCursor: CGPoint?
    private var lastInjectedMove: TimeInterval = 0
    private var lastSecureInputWarning: TimeInterval = 0
    private let resyncAfterIdle: TimeInterval = 0.25

    private(set) var eventsPosted = 0

    /// View-only mode. The video keeps flowing and the client has no
    /// idea anything is different — it just gets ignored. Gated at
    /// `post` rather than in each handler so there is exactly one place
    /// that can be wrong.
    private var _isEnabled = true

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        // Release before disabling: flipping the flag mid-drag would
        // otherwise strand a held button with no way to send the up.
        if !enabled { releaseAll() }
        lock.lock(); _isEnabled = enabled; lock.unlock()
        Log.info(enabled ? "input enabled" : "input disabled — view only")
    }

    // MARK: - Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static let settingsHint = """
    Grant Accessibility so the agent can move the cursor:
      System Settings > Privacy & Security > Accessibility
    As with Screen Recording, a changed code signature invalidates an
    existing grant — toggle it off and on again if it is already listed.
    """

    func setStreamSize(width: Int, height: Int) {
        lock.lock()
        streamSize = CGSize(width: width, height: height)
        lock.unlock()
    }

    // MARK: - Geometry

    /// Display bounds in points, read fresh each time: the user can
    /// change resolution or rearrange displays mid-session.
    private var displayBounds: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    private var scale: CGSize {
        lock.lock(); let stream = streamSize; lock.unlock()
        let bounds = displayBounds
        guard stream.width > 0, stream.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: bounds.width / stream.width,
                      height: bounds.height / stream.height)
    }

    /// Where the cursor actually is right now.
    ///
    /// Read from the system rather than tracked locally — otherwise the
    /// moment the user touches the real mouse, our idea of the position
    /// diverges from the truth and never recovers.
    private var currentLocation: CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: displayBounds.midX, y: displayBounds.midY)
    }

    /// The point to apply the next delta to.
    private func moveOrigin() -> CGPoint {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let cached = virtualCursor
        let idle = now - lastInjectedMove
        lock.unlock()

        if let cached, idle < resyncAfterIdle {
            return cached
        }
        // Idle long enough that the user may have moved the real mouse.
        return currentLocation
    }

    private func rememberCursor(_ point: CGPoint) {
        lock.lock()
        virtualCursor = point
        lastInjectedMove = Date().timeIntervalSince1970
        lock.unlock()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let bounds = displayBounds
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    // MARK: - Pointer

    func handlePointerMove(_ message: PointerMoveMessage) {
        let scale = self.scale
        let target: CGPoint

        switch message.mode {
        case .relative:
            let base = moveOrigin()
            target = clamp(CGPoint(x: base.x + CGFloat(message.x) * scale.width,
                                   y: base.y + CGFloat(message.y) * scale.height))
        case .absolute:
            let bounds = displayBounds
            target = clamp(CGPoint(x: bounds.minX + CGFloat(message.x) * scale.width,
                                   y: bounds.minY + CGFloat(message.y) * scale.height))
        }

        // A move while a button is held is a *drag*. Posting mouseMoved
        // instead means text selection, window dragging, and slider
        // handles all silently do nothing.
        lock.lock(); let held = buttonsDown; lock.unlock()
        let type: CGEventType
        let button: CGMouseButton
        if held.contains(.left) {
            type = .leftMouseDragged; button = .left
        } else if held.contains(.right) {
            type = .rightMouseDragged; button = .right
        } else if held.contains(.middle) {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }

        rememberCursor(target)
        post(CGEvent(mouseEventSource: source, mouseType: type,
                     mouseCursorPosition: target, mouseButton: button))
    }

    func handlePointerButton(_ message: PointerButtonMessage) {
        let location = moveOrigin()

        lock.lock()
        if message.isDown { buttonsDown.insert(message.button) }
        else { buttonsDown.remove(message.button) }
        lock.unlock()

        let type: CGEventType
        let button: CGMouseButton
        switch message.button {
        case .left:
            type = message.isDown ? .leftMouseDown : .leftMouseUp;   button = .left
        case .right:
            type = message.isDown ? .rightMouseDown : .rightMouseUp; button = .right
        case .middle:
            type = message.isDown ? .otherMouseDown : .otherMouseUp; button = .center
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: button) else { return }
        // macOS synthesises a double-click from the click state field —
        // two separate single clicks are not equivalent.
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, message.clickCount)))
        post(event)
    }

    func handleScroll(_ message: ScrollMessage) {
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: message.deltaY),
                                  wheel2: Int32(clamping: message.deltaX),
                                  wheel3: 0) else { return }

        // Tagging the run with a phase is what makes macOS treat it as
        // one continuous trackpad scroll instead of a burst of unrelated
        // wheel clicks. Rubber-banding at the end of a list and
        // swipe-to-go-back in a browser both key off these fields and
        // ignore the deltas entirely.
        //
        // Phase and momentum phase are mutually exclusive: an event
        // carrying both is discarded, which looks exactly like scrolling
        // being broken.
        switch message.phase {
        case .began:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)   // kCGScrollPhaseBegan
        case .changed:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)   // kCGScrollPhaseChanged
        case .ended:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)   // kCGScrollPhaseEnded
        case .momentum:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) // continue
        case .momentumEnded:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3) // end
        }
        post(event)
    }

    // MARK: - System gestures

    /// The Dock's own notification entry point.
    ///
    /// This is private API, and that is a deliberate, tested choice
    /// rather than a shortcut. The supported route — synthesising the
    /// Ctrl-arrow hotkeys — does not work: on macOS 27 the window
    /// server ignores synthetic key events for its own hotkeys even
    /// from a process holding Accessibility, which was verified by
    /// posting them and screenshotting the result. This call works,
    /// needs no permission at all, and is the same mechanism every
    /// third-party window manager on the platform uses.
    ///
    /// Resolved at runtime rather than linked, so if a future macOS
    /// removes it the result is a logged warning instead of an app that
    /// will not launch.
    private static let dockNotify: (@convention(c) (CFString, Int32) -> Void)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDockSendNotification") else {
            Log.warn("CoreDockSendNotification is unavailable — Mission Control and friends will not work")
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString, Int32) -> Void).self)
    }()

    func handleGesture(_ message: GestureMessage) {
        guard isEnabled else { return }

        switch message.gesture {
        // Launching the app is what actually opens Mission Control.
        // Its Dock notification, com.apple.expose.awake, does nothing
        // on macOS 27 — unlike showdesktop's, which still works. Both
        // were tested by firing them and screenshotting the result.
        case .missionControl:  launchMissionControl()
        case .showDesktop:     sendToDock("com.apple.showdesktop.awake")

        // Back and forward are ordinary application shortcuts rather
        // than window-server hotkeys, so these do go through as
        // synthetic key events.
        case .navigateBack:    sendShortcut(key: 33, label: message.gesture.label)   // [
        case .navigateForward: sendShortcut(key: 30, label: message.gesture.label)   // ]
        }
    }

    private func launchMissionControl() {
        let app = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            Log.warn("Mission Control.app is not present")
            return
        }
        NSWorkspace.shared.openApplication(at: app,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.warn("Mission Control: \(error.localizedDescription)") }
        }
        Log.info("gesture: Mission Control (launched)")
    }

    private func sendToDock(_ notification: String) {
        guard let notify = Self.dockNotify else { return }
        notify(notification as CFString, 0)
        Log.info("gesture: \(notification)")
    }

    private func sendShortcut(key: CGKeyCode, label: String) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        post(down)
        post(up)
        Log.info("gesture: \(label) (cmd+key)")
    }

    /// True when some app has enabled secure event input — a focused
    /// password field, a password manager, Terminal's secure keyboard
    /// entry. While it is on, macOS drops synthetic key events system
    /// wide and there is nothing this process can do about it.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    private static func cgFlags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift)    { flags.insert(.maskShift) }
        if modifiers.contains(.control)  { flags.insert(.maskControl) }
        if modifiers.contains(.option)   { flags.insert(.maskAlternate) }
        if modifiers.contains(.command)  { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    func handleKeyEvent(_ message: KeyEventMessage) {
        guard warnIfSecureInput() else { return }
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(message.keyCode),
                                  keyDown: message.isDown) else { return }
        event.flags = Self.cgFlags(message.modifiers)
        post(event)
    }

    /// Types literal text without going near a keycode table.
    ///
    /// `keyboardSetUnicodeString` makes layout, language, emoji and
    /// dictation all work identically — none of which map onto US
    /// virtual keys.
    func handleTextInput(_ message: TextInputMessage) {
        guard warnIfSecureInput() else { return }
        guard !message.text.isEmpty else { return }

        let utf16 = Array(message.text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(down)
        post(up)
    }

    /// Rate-limited so a held key doesn't fill the log.
    private func warnIfSecureInput() -> Bool {
        guard Self.isSecureInputEnabled else { return true }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let shouldWarn = now - lastSecureInputWarning > 5
        if shouldWarn { lastSecureInputWarning = now }
        lock.unlock()
        if shouldWarn {
            Log.warn("secure input is active — keystrokes are being dropped by macOS (a password field is focused somewhere)")
        }
        return false
    }

    /// Release anything still held. Called when a client disconnects, so
    /// a dropped connection mid-drag doesn't leave the Mac with a stuck
    /// mouse button.
    func releaseAll() {
        lock.lock(); let held = buttonsDown; buttonsDown.removeAll(); lock.unlock()
        guard !held.isEmpty else { return }
        Log.warn("releasing \(held.count) stuck button(s) after disconnect")
        for button in held {
            handlePointerButton(PointerButtonMessage(button: button, isDown: false))
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event, isEnabled else { return }
        event.post(tap: .cghidEventTap)
        lock.lock(); eventsPosted += 1; lock.unlock()
    }
}
