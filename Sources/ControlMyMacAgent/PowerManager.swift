import ControlMyMacKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac reachable, and wakes the screen when someone connects.
///
/// This exists because a sleeping Mac drops off the tailnet entirely —
/// the interface goes down, the node shows offline, and no amount of
/// clever client-side retrying can reach it. Wake-on-LAN doesn't help
/// either: magic packets are layer 2 and don't cross a tailnet. The only
/// reliable answer is to not sleep in the first place.
final class PowerManager {

    private var systemSleepAssertion: IOPMAssertionID = 0
    private var displaySleepAssertion: IOPMAssertionID = 0
    private let lock = NSLock()

    /// Held for the agent's whole life: the machine must stay on the
    /// network to be reachable at all.
    ///
    /// Note this only blocks *idle* sleep. Closing the lid or choosing
    /// Sleep still works, and `pmset -c sleep 0` is still worth setting
    /// as a belt-and-braces measure.
    func preventSystemSleep() {
        lock.lock(); defer { lock.unlock() }
        guard systemSleepAssertion == 0 else { return }

        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ControlMyMac is serving a remote session" as CFString,
            &systemSleepAssertion)

        if status == kIOReturnSuccess {
            Log.info("holding system awake (idle sleep prevented)")
        } else {
            Log.warn("could not prevent idle sleep (IOReturn \(status))")
        }
    }

    /// Held only while a client is actually watching.
    ///
    /// Kept separate from the system assertion on purpose: with no one
    /// connected the display should be free to sleep normally — that
    /// costs nothing, since the machine stays awake and reachable
    /// either way.
    func preventDisplaySleep() {
        lock.lock(); defer { lock.unlock() }
        guard displaySleepAssertion == 0 else { return }

        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ControlMyMac has a viewer connected" as CFString,
            &displaySleepAssertion)

        if status == kIOReturnSuccess {
            Log.info("holding display awake while a client is connected")
        }
    }

    func allowDisplaySleep() {
        lock.lock(); defer { lock.unlock() }
        guard displaySleepAssertion != 0 else { return }
        IOPMAssertionRelease(displaySleepAssertion)
        displaySleepAssertion = 0
        Log.info("display may sleep again")
    }

    /// Wakes a sleeping *display* when a client connects.
    ///
    /// ScreenCaptureKit stops delivering frames once the display sleeps,
    /// so without this a client that connects to an idle Mac gets a
    /// connection and no picture.
    func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionDeclareUserActivity(
            "ControlMyMac client connected" as CFString,
            kIOPMUserActiveLocal,
            &assertion)
        if status == kIOReturnSuccess {
            Log.info("woke the display for an incoming client")
        }
    }

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
    }

    deinit { releaseAll() }
}
