import AppKit
import ControlMyMacKit
import SwiftUI

/// The Mac app.
///
/// Not marked `@main`: `main.swift` owns the entry point so the same
/// binary can still run headless for scripts and regression tests.
/// `App.main()` is the supported way to start it by hand.
struct ControlMyMacGUI: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AgentController.shared
    @StateObject private var prefs = Preferences.shared

    var body: some Scene {
        Window("ControlMyMac", id: "main") {
            RootView(controller: controller, prefs: prefs)
                .frame(minWidth: 780, minHeight: 560)
        }
        // No .windowResizability here on purpose: .contentMinSize pins
        // the window to the content's minimum and quietly overrides
        // .defaultSize, so the app opens at its smallest allowed size.
        .defaultSize(width: 960, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button(controller.isRunning ? "Stop Sharing" : "Start Sharing") {
                    controller.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContent(controller: controller, prefs: prefs)
        } label: {
            // Filled while someone is actually watching, so a glance at
            // the menu bar answers "is my screen being shared?".
            Image(systemName: controller.snapshot.clients.isEmpty
                  ? "display" : "display.and.arrow.down.fill")
        }
    }
}

/// Owns the things SwiftUI has no scene-level hook for: activation
/// policy, auto-start, and stopping cleanly on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let sizedKey = "didSetInitialWindowSize"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.applyActivationPolicy(showInDock: Preferences.shared.showInDock)
        sizeWindowOnFirstRun()
        if Preferences.shared.startOnLaunch {
            // After the first runloop turn, so a permission failure has
            // a window to land in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AgentController.shared.start()
            }
        }
    }

    /// `Scene.defaultSize` is ignored on this macOS build — the window
    /// comes up at the content's minimum instead — so the opening size
    /// is set by hand. Once only: after that the window remembers
    /// whatever size the user left it at, which is the behaviour they
    /// actually expect.
    private func sizeWindowOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.sizedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.sizedKey)

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && $0.styleMask.contains(.titled)
            }) else { return }
            window.setContentSize(NSSize(width: 980, height: 800))
            window.center()
        }
    }

    /// Clicking the Dock icon with no window open should bring the app
    /// back, not just bounce.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Closing the window leaves it running — that is the whole point of
    /// a thing you connect to from somewhere else.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("app quitting")
        Log.drain()
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var controller: AgentController
    @ObservedObject var prefs: Preferences

    enum Pane: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case setup     = "Setup"
        case activity  = "Activity"
        case settings  = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: return "display"
            case .setup:     return "checklist"
            case .activity:  return "waveform"
            case .settings:  return "gearshape"
            }
        }
    }

    @State private var selection: Pane = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.symbol)
                    .badge(pane == .setup && !setupComplete ? "!" : nil)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection {
            case .dashboard: DashboardView(controller: controller, prefs: prefs)
            case .setup:     SetupView(controller: controller, prefs: prefs)
            case .activity:  ActivityView(controller: controller)
            case .settings:  SettingsView(controller: controller, prefs: prefs)
            }
        }
        // Land on Setup the first time something is actually missing —
        // a dashboard full of dashes is a worse first impression than a
        // list of two things to click.
        .onAppear {
            controller.windowBecameVisible()
            if !setupComplete { selection = .setup }
        }
    }

    private var setupComplete: Bool {
        controller.screenRecordingGranted && !controller.needsRelaunch
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @ObservedObject var controller: AgentController
    @ObservedObject var prefs: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusTitle)
        if controller.isRunning {
            Text(verbatim: controller.snapshot.clients.isEmpty
                 ? "No devices connected"
                 : "\(controller.snapshot.clients.count) connected · \(controller.snapshot.qualityWidth)p")
        }
        if let host = controller.tailscale.preferredHost {
            Text(verbatim: "\(host):\(prefs.port)")
        }

        Divider()

        Button(controller.isRunning ? "Stop Sharing" : "Start Sharing") {
            controller.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Toggle("Allow Remote Control", isOn: Binding(
            get: { prefs.allowInput },
            set: { prefs.allowInput = $0; controller.applyLiveSettings() }))

        Divider()

        Button("Open ControlMyMac") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Quit") { controller.quit() }
            .keyboardShortcut("q")
    }
}
