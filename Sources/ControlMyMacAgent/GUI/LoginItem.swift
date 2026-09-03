import Foundation
import ControlMyMacKit
import ServiceManagement

/// Launch at login, via the modern API.
///
/// `SMAppService.mainApp` registers the bundle itself — no helper, no
/// launchd plist to install and keep in sync. It needs a properly signed
/// bundle, so an ad-hoc build will refuse; the UI surfaces the reason
/// rather than silently doing nothing.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `.requiresApproval` means the user has to switch it on in
    /// System Settings > General > Login Items. Worth saying out loud —
    /// otherwise the toggle looks broken.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.info("registered as a login item")
            } else {
                try SMAppService.mainApp.unregister()
                Log.info("removed from login items")
            }
            return nil
        } catch {
            Log.warn("login item change failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
