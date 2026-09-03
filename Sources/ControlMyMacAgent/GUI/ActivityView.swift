import ControlMyMacKit
import SwiftUI

/// A live tail of what the agent is doing.
///
/// This is the screen that turns "it isn't working" into a specific
/// sentence — client connected, keyframe delivered, quality reduced.
/// Everything here is already in the log file; this is just the copy you
/// don't have to go looking for.
struct ActivityView: View {
    @ObservedObject var controller: AgentController
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .background(.background.secondary)
                .onChange(of: controller.logLines.count) { _, count in
                    guard autoScroll, count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard !controller.logLines.isEmpty else { return }
                    proxy.scrollTo(controller.logLines.count - 1, anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("Follow", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(controller.logLines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy") {
                    controller.copyToPasteboard(controller.logLines.joined(separator: "\n"))
                }
                Button("Reveal Log") { controller.revealLog() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .navigationTitle("Activity")
    }

    private func color(for line: String) -> Color {
        if line.contains(" ERROR ") { return .red }
        if line.contains(" WARN ")  { return .orange }
        return .primary
    }
}
