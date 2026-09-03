import ControlMyMacKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var controller: AgentController
    @ObservedObject var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                if let error = controller.lastError { errorBanner(error) }
                if controller.needsRelaunch { relaunchBanner }
                connectionCard
                if controller.isRunning { statsCard }
                clientsCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("ControlMyMac")
    }

    // MARK: - Status

    private var statusCard: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                StatusDot(color: controller.statusColor,
                          animated: controller.isRunning && !controller.snapshot.clients.isEmpty)

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.statusTitle)
                        .font(.title2.weight(.semibold))
                    Text(controller.statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(controller.isRunning ? "Stop" : "Start Sharing") {
                    controller.toggle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(controller.isRunning ? .red : .accentColor)
                .disabled(!controller.isReadyToServe && !controller.isRunning)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { controller.lastError = nil }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var relaunchBanner: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Relaunch to pick up the new permission")
                        .font(.body.weight(.medium))
                    Text("macOS decides screen recording access when the app starts, so this copy is still running under the old answer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Relaunch") { controller.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        Card(title: "Connect from your iPhone",
             footnote: "Open ControlMyMac on the iPhone and enter these two values. Both devices have to be on the same tailnet.") {
            VStack(spacing: 8) {
                if let host = controller.tailscale.preferredHost {
                    CopyableValue(label: "Host", value: host) { controller.copyToPasteboard($0) }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "network.slash").foregroundStyle(.orange)
                        Text(controller.tailscale.summary)
                            .font(.callout)
                        Spacer()
                        Button("Recheck") { controller.refreshTailscale() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }

                CopyableValue(label: "Port", value: "\(prefs.port)") { controller.copyToPasteboard($0) }

                if let ip = controller.tailscale.ipv4, controller.tailscale.dnsName != nil {
                    Text("Tailscale IP \(ip) works too, if the name ever fails to resolve.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Live numbers

    private var statsCard: some View {
        Card(title: "Live") {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                          spacing: 10) {
                    StatTile(title: "Frame rate",
                             value: controller.snapshot.isCapturing
                                 ? String(format: "%.0f", controller.fps) : "Idle",
                             caption: controller.snapshot.isCapturing
                                 ? "encoding, target \(prefs.fps)" : "not encoding",
                             tint: controller.snapshot.isCapturing ? .primary : .secondary)
                    StatTile(title: "Bitrate",
                             value: String(format: "%.1f", controller.megabitsPerSecond),
                             caption: controller.snapshot.clients.isEmpty ? "no viewers" : "Mbps out")
                    StatTile(title: "Resolution",
                             value: controller.resolution,
                             caption: controller.snapshot.qualityMode == .auto ? "auto" : "fixed")
                    StatTile(title: "Uptime",
                             value: controller.uptime,
                             caption: "since start")
                    StatTile(title: "Frames sent",
                             value: "\(controller.snapshot.framesSent)",
                             caption: "\(controller.snapshot.framesEncoded) encoded")
                    StatTile(title: "Dropped",
                             value: "\(controller.snapshot.framesDropped)",
                             caption: "to backpressure",
                             tint: controller.snapshot.framesDropped > 0 ? .orange : .primary)
                    StatTile(title: "Data sent",
                             value: String(format: "%.0f MB", Double(controller.snapshot.bytesSent) / 1_000_000))
                    StatTile(title: "Input events",
                             value: "\(controller.snapshot.inputEvents)",
                             caption: controller.snapshot.inputAllowed ? nil : "view only",
                             tint: controller.snapshot.inputAllowed ? .primary : .orange)
                }

                if !controller.snapshot.isCapturing {
                    Label("Sleeping. The screen is not being captured and the encoder is shut down — only the listener is up, which costs nothing. Capture resumes the moment your iPhone connects.",
                          systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let failure = controller.snapshot.captureError {
                    Label("Capture failed to start: \(failure)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if controller.snapshot.secureInputActive {
                    Label("A password field is focused somewhere — macOS is blocking synthetic keystrokes system-wide until it loses focus.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                qualityPicker
            }
        }
    }

    private var qualityPicker: some View {
        HStack(spacing: 10) {
            Text("Quality")
                .font(.callout.weight(.medium))
            Picker("", selection: qualityBinding) {
                Text("Auto").tag(-1)
                ForEach(Array(QualityLevel.ladder.enumerated()), id: \.offset) { index, level in
                    Text(verbatim: "\(level.width)p").tag(index)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            Spacer()
            Text(verbatim: controller.snapshot.qualityMode == .auto
                 ? "Adapting to the link — currently \(controller.snapshot.qualityWidth)p"
                 : "Pinned at \(controller.snapshot.qualityWidth)p")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// -1 is Auto; anything else is an index into the shared ladder.
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

    // MARK: - Clients

    private var clientsCard: some View {
        Card(title: "Connected devices") {
            if controller.snapshot.clients.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.slash").foregroundStyle(.tertiary)
                    Text(controller.isRunning
                         ? "Nothing connected. Open the app on your iPhone."
                         : "Start sharing to accept connections.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.snapshot.clients) { client in
                        clientRow(client)
                        if client.id != controller.snapshot.clients.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func clientRow(_ client: StreamServer.ClientInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 20))
                .foregroundStyle(client.streaming ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.body.weight(.medium))
                Text(client.peer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(client.streaming ? "Streaming" : "Waiting for keyframe")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(client.streaming ? .green : .orange)
                HStack(spacing: 8) {
                    if client.hasControl {
                        Label("Input", systemImage: "cursorarrow.click")
                            .labelStyle(.titleAndIcon)
                    }
                    if client.framesDecoded > 0 {
                        Text("\(client.jitterMillis)ms jitter")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }
}
