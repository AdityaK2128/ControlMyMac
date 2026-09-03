import AppKit
import ControlMyMacKit
import CoreMedia
import Foundation
import SwiftUI
import VideoToolbox

/// Everything the user can change, persisted to UserDefaults.
///
/// Deliberately plain: the agent reads these once when it starts, so a
/// change to `port` or `fps` only takes effect on the next start. The UI
/// says so rather than pretending otherwise.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var port: Int { didSet { write(port, "port") } }
    @Published var fps: Int { didSet { write(fps, "fps") } }
    @Published var useHEVC: Bool { didSet { write(useHEVC, "useHEVC") } }

    /// Auto lets the agent step down the ladder when the link struggles.
    @Published var autoQuality: Bool { didSet { write(autoQuality, "autoQuality") } }
    /// The rung auto starts from, and the fixed rung when auto is off.
    @Published var qualityWidth: Int { didSet { write(qualityWidth, "qualityWidth") } }

    /// View-only mode. Video keeps flowing; input is refused.
    @Published var allowInput: Bool { didSet { write(allowInput, "allowInput") } }

    @Published var startOnLaunch: Bool { didSet { write(startOnLaunch, "startOnLaunch") } }
    @Published var keepAwake: Bool { didSet { write(keepAwake, "keepAwake") } }

    @Published var showInDock: Bool {
        didSet {
            write(showInDock, "showInDock")
            Self.applyActivationPolicy(showInDock: showInDock)
        }
    }

    private init() {
        // Reading through a local rather than `self.defaults`: the
        // stored properties are not all initialised yet, so touching
        // `self` here is not allowed.
        let store = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            store.object(forKey: key) as? Int ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        port = int("port", Int(Wire.defaultPort))
        fps = int("fps", 30)
        // HEVC by default: both ends decode it in hardware, and fewer
        // bits for the same picture is exactly what a cellular link
        // wants. H.264 stays one click away as the first thing to try
        // if a device ever shows nothing.
        useHEVC = bool("useHEVC", true)
        autoQuality = bool("autoQuality", true)
        qualityWidth = int("qualityWidth", QualityLevel.ladder[QualityLevel.defaultIndex].width)
        allowInput = bool("allowInput", true)
        startOnLaunch = bool("startOnLaunch", true)
        keepAwake = bool("keepAwake", true)
        showInDock = bool("showInDock", true)
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Derived

    var codec: CMVideoCodecType {
        useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    var startLevel: QualityLevel {
        QualityLevel.nearest(width: qualityWidth)
    }

    /// A menu-bar utility with no window open has no business holding a
    /// Dock tile, but hiding it by default would make the app feel lost
    /// the first time it runs. So it is a choice, defaulting to visible.
    static func applyActivationPolicy(showInDock: Bool) {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
