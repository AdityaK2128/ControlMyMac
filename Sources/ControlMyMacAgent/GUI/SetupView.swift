import AppKit
import ControlMyMacKit
import SwiftUI

/// The screen that answers "why isn't this working?".
///
/// Every row is a thing that must be true before an iPhone can connect,
/// with the fix one click away. The order matches the order things fail
/// in: no permission, no network, no input.
struct SetupView: View {
    @ObservedObject var controller: AgentController
    @ObservedObject var prefs: Preferences

    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                permissionsCard
                networkCard
                convenienceCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Setup")
        .onAppear { loginItemEnabled = LoginItem.isEnabled }
    }

    private var allGood: Bool {
        controller.screenRecordingGranted
            && controller.accessibilityGranted
            && controller.tailscale.isUsable
            && !controller.needsRelaunch
    }

    private var summaryCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: allGood ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(allGood ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(allGood ? "Everything is ready" : "A few things need attention")
                        .font(.title3.weight(.semibold))
                    Text(allGood
                         ? "Your Mac can be reached and controlled from the iPhone."
                         : "Work through the list below. Each item explains what breaks without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private var permissionsCard: some View {
        Card(title: "Permissions",
             footnote: "macOS decides both of these when the app launches. If you have just granted one, relaunch before testing.") {
            VStack(spacing: 0) {
                ChecklistRow(
                    status: controller.needsRelaunch ? .warning
                          : (controller.screenRecordingGranted ? .ok : .bad),
                    title: "Screen Recording",
                    detail: controller.needsRelaunch
                        ? "Granted, but this copy started before the grant. Relaunch to use it."
                        : (controller.screenRecordingGranted
                           ? "Granted. The screen can be captured."
                           : "Required. Without it there is nothing to send — the app cannot start.")
                ) {
                    if controller.needsRelaunch {
                        Button("Relaunch") { controller.relaunch() }
                            .buttonStyle(.borderedProminent)
                    } else if !controller.screenRecordingGranted {
                        Button("Grant…") { controller.requestScreenRecording() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Settings") {
                            controller.openSettings("com.apple.preference.security?Privacy_ScreenCapture")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Divider()

                ChecklistRow(
                    status: controller.accessibilityGranted ? .ok : .warning,
                    title: "Accessibility",
                    detail: controller.accessibilityGranted
                        ? "Granted. Taps, drags and typing reach the Mac."
                        : "Needed for control. Video still works without it — the cursor just won't move."
                ) {
                    if controller.accessibilityGranted {
                        Button("Settings") {
                            controller.openSettings("com.apple.preference.security?Privacy_Accessibility")
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button("Grant…") { controller.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        Card(title: "Network",
             footnote: "ControlMyMac never opens a port to the internet. The stream only exists inside your tailnet.") {
            VStack(spacing: 0) {
                ChecklistRow(
                    status: tailscaleStatus,
                    title: "Tailscale",
                    detail: tailscaleDetail
                ) {
                    HStack(spacing: 8) {
                        Button("Recheck") { controller.refreshTailscale() }
                            .buttonStyle(.borderless)
                        if TailscaleStatus.binaryPath() != nil, !controller.tailscale.isUsable {
                            Button("Open Tailscale") { openTailscale() }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Divider()

                ChecklistRow(
                    status: prefs.keepAwake ? .ok : .warning,
                    title: "Stay reachable while asleep",
                    detail: prefs.keepAwake
                        ? "Idle sleep is held off while the app runs. A sleeping Mac drops off the tailnet entirely, and no amount of retrying from the phone can wake it."
                        : "Off. If the Mac idles into sleep it leaves the tailnet and the iPhone cannot reach it at all."
                ) {
                    Toggle("", isOn: $prefs.keepAwake)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var convenienceCard: some View {
        Card(title: "Convenience") {
            VStack(spacing: 0) {
                ChecklistRow(
                    status: loginItemEnabled ? .ok : .unknown,
                    title: "Open at login",
                    detail: loginItemError
                        ?? (LoginItem.needsApproval
                            ? "Waiting for your approval in System Settings > General > Login Items."
                            : (loginItemEnabled
                               ? "ControlMyMac starts with the Mac, so it is there when you are not."
                               : "Off. You will need to open the app by hand before leaving."))
                ) {
                    Toggle("", isOn: Binding(
                        get: { loginItemEnabled },
                        set: { wanted in
                            loginItemError = LoginItem.set(wanted)
                            loginItemEnabled = LoginItem.isEnabled
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider()

                ChecklistRow(
                    status: prefs.startOnLaunch ? .ok : .unknown,
                    title: "Start sharing automatically",
                    detail: prefs.startOnLaunch
                        ? "The listener comes up as soon as the app opens."
                        : "Off. You will press Start yourself each time."
                ) {
                    Toggle("", isOn: $prefs.startOnLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var tailscaleStatus: ChecklistStatus {
        switch controller.tailscale.state {
        case .running:      return controller.tailscale.isUsable ? .ok : .warning
        case .stopped,
             .needsLogin:   return .bad
        case .notInstalled: return .bad
        case .unknown:      return .warning
        }
    }

    private var tailscaleDetail: String {
        switch controller.tailscale.state {
        case .running:
            if let host = controller.tailscale.preferredHost {
                return "Connected as \(host)."
            }
            return "Running, but it has not been given an address yet."
        case .stopped:
            return "Switched off. Turn it on from the Tailscale menu bar item — the iPhone reaches this Mac over the tailnet and nothing else."
        case .needsLogin:
            return "Installed but not logged in."
        case .notInstalled:
            return "Not found. Without it the iPhone has no route to this Mac from outside your home network."
        case .unknown(let why):
            return why
        }
    }

    /// Bring the Tailscale app forward so its menu bar item is one click
    /// away. Turning it on is the user's decision, not ours to automate.
    private func openTailscale() {
        let app = URL(fileURLWithPath: "/Applications/Tailscale.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        NSWorkspace.shared.open(app)
    }
}
