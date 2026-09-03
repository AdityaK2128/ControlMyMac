import ControlMyMacKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AgentController
    @ObservedObject var prefs: Preferences

    /// Port, frame rate and codec are baked into the capture session and
    /// the listener when they start, so changing them mid-session would
    /// be a lie. The UI offers a restart instead of pretending.
    ///
    /// Derived from what the engine is actually running, not from a
    /// flag: a `@State` flag resets when you navigate away and back,
    /// which quietly hid the banner while the change was still unapplied.
    private var restartPending: Bool {
        guard controller.isRunning else { return false }
        let running = controller.snapshot
        return running.port != UInt16(clamping: prefs.port)
            || running.fps != prefs.fps
            || running.usesHEVC != prefs.useHEVC
            || running.keepAwake != prefs.keepAwake
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if restartPending { restartBanner }
                streamCard
                controlCard
                appCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
    }

    private var restartBanner: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                Text("Some of these only take effect on the next start.")
                    .font(.callout)
                Spacer()
                Button("Restart Sharing") {
                    controller.restart()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Stream

    private var streamCard: some View {
        Card(title: "Stream") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Quality") {
                    Picker("", selection: qualityBinding) {
                        Text("Auto").tag(-1)
                        ForEach(Array(QualityLevel.ladder.enumerated()), id: \.offset) { index, level in
                            Text(verbatim: "\(level.width)p · \(level.bitrate / 1_000_000) Mbps").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text(prefs.autoQuality
                     ? "Steps down quickly when frames start backing up, and climbs back only after a sustained clean spell. Bitrates are tuned for screen content, which is mostly still and compresses far better than camera video at the same size."
                     : "Fixed. The picture will stutter rather than soften if the link cannot keep up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                LabeledContent("Frame rate") {
                    Picker("", selection: $prefs.fps) {
                        Text("15 fps").tag(15)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                LabeledContent("Codec") {
                    Picker("", selection: $prefs.useHEVC) {
                        Text("H.264").tag(false)
                        Text("HEVC").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                Text(prefs.useHEVC
                     ? "Roughly a third fewer bits for the same picture, which is what matters on a cellular link. Both this Mac and the iPhone handle it in dedicated hardware, so it costs no extra battery."
                     : "Widest compatibility. Worth switching to as the first check if a device ever connects but shows nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                LabeledContent("Port") {
                    TextField("", value: $prefs.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    }
            }
        }
    }

    private var qualityBinding: Binding<Int> {
        Binding(
            get: {
                guard !prefs.autoQuality else { return -1 }
                return QualityLevel.ladder.firstIndex { $0.width == prefs.qualityWidth } ?? -1
            },
            set: { index in
                if index < 0 {
                    prefs.autoQuality = true
                } else {
                    prefs.autoQuality = false
                    prefs.qualityWidth = QualityLevel.ladder[index].width
                }
                controller.applyLiveSettings()
            }
        )
    }

    // MARK: - Control

    private var controlCard: some View {
        Card(title: "Control") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $prefs.allowInput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow remote control")
                        Text("Off means view-only: video keeps flowing, but taps and typing are ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: prefs.allowInput) { _, _ in controller.applyLiveSettings() }

                Divider()

                Toggle(isOn: $prefs.keepAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the Mac awake while running")
                        Text("A sleeping Mac leaves the tailnet, so there is nothing left to connect to. This holds off idle sleep only — closing the lid still sleeps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - App

    private var appCard: some View {
        Card(title: "App") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $prefs.startOnLaunch) {
                    Text("Start sharing when the app opens")
                }

                Toggle(isOn: $prefs.showInDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in the Dock")
                        Text("Off leaves only the menu bar item — the usual shape for something that runs all day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text("Log file")
                    Spacer()
                    Button("Reveal in Finder") { controller.revealLog() }
                }
            }
        }
    }
}
