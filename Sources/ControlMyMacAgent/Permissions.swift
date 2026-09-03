import CoreGraphics
import Foundation

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt — but only ever once per app identity.
    /// After the first denial macOS stays silent and the user has to go
    /// to System Settings by hand, which is why the caller prints a path.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static let settingsHint = """
    Grant Screen Recording, then run again:
      System Settings > Privacy & Security > Screen & System Audio Recording
    If the app is already listed and toggled on, toggle it off and on again —
    a changed code signature invalidates the existing grant.
    """
}
