import SwiftUI

/// Everything that used to sit permanently on top of the video.
///
/// A remote desktop wants the whole screen, so none of this is visible
/// until asked for — three fingers on the trackpad brings it up.
private func gestureRow(_ gesture: String, _ action: String) -> some View {
    HStack {
        Text(gesture)
        Spacer()
        Text(action)
            .foregroundStyle(.secondary)
    }
    .font(.callout)
}

struct SettingsSheet: View {
    @ObservedObject var model: StreamViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $model.selectedQuality) {
                        Text("Auto").tag(QualityLevel?.none)
                        ForEach(QualityLevel.ladder, id: \.self) { level in
                            Text("\(level.width)p · \(level.bitrate / 1_000_000) Mbps")
                                .tag(QualityLevel?.some(level))
                        }
                    }
                    row("Active", model.activeQuality)
                } header: {
                    Text("Quality")
                } footer: {
                    Text(model.selectedQuality == nil
                         ? "Auto drops the resolution when the link can't keep up, and climbs back once it's been clear for a while."
                         : "Pinned. The agent will not reduce quality on a slow link, so a weak connection will stutter instead.")
                }

                Section("Stream") {
                    row("Codec", model.streamDescription.isEmpty ? "—" : model.streamDescription)
                    row("Resolution", model.streamSizeDescription)
                    row("Frames", "\(model.stats.framesReceived)")
                    row("Keyframes", "\(model.stats.keyframesReceived)")
                    row("Received", model.throughputDescription)
                    row("Jitter", String(format: "%.1f ms mean · %.1f ms peak",
                                         model.stats.meanJitterMillis,
                                         model.stats.peakJitterMillis))
                }

                Section("Connection") {
                    row("Host", model.host)
                    row("Port", model.port)
                }

                Section {
                    slider("Pointer speed", value: $model.sensitivity, range: 0.4...4.0)
                    slider("Acceleration", value: $model.maxAcceleration, range: 1.0...4.0)
                    slider("Scroll speed", value: $model.scrollSensitivity, range: 0.5...6.0)
                    Toggle("Invert scroll", isOn: $model.invertScroll)
                    Toggle("Momentum scrolling", isOn: $model.momentumScrolling)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Jitter is the spread of frame arrival times, not latency — the two clocks are never in sync, so only the variation is meaningful.")
                }

                Section {
                    Button {
                        dismiss()
                        model.takeScreenshot()
                    } label: {
                        Label("Take Screenshot", systemImage: "camera.viewfinder")
                    }
                } header: {
                    Text("Screenshot")
                } footer: {
                    Text("Captures the Mac's display at full resolution — not the scaled-down video — and saves it straight to your Photos library.")
                }

                Section {
                    Toggle("Keyboard", isOn: $model.keyboardActive)
                    Toggle("Hold left button", isOn: $model.dragLock)
                    Toggle("Floating keyboard button", isOn: $model.showKeyboardButton)
                } header: {
                    Text("Controls")
                } footer: {
                    Text(model.showKeyboardButton
                         ? "Drag the button anywhere it's out of the way. Turn it off to keep the screen clear — the keyboard is still available here."
                         : "The keyboard can only be opened from this panel while the floating button is off.")
                }

                Section {
                    gestureRow("Three fingers up", "Mission Control")
                    gestureRow("Three fingers down", "Show Desktop")
                    gestureRow("Three fingers right", "Back")
                    gestureRow("Three fingers left", "Forward")
                    gestureRow("Three-finger tap", "This panel")
                    gestureRow("Two-finger tap", "Right click")
                    gestureRow("Press and hold", "Drag")
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("The Mac cannot receive a synthetic trackpad swipe, so these ask it to perform the action directly. Switching Spaces is missing because it exists only as a window-server hotkey, and those ignore synthetic input entirely.")
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        model.disconnect()
                        dismiss()
                    }
                }

                Section {
                    gesture("Drag", "move the pointer")
                    gesture("Tap", "left click")
                    gesture("Double tap", "double click")
                    gesture("Two-finger tap", "right click")
                    gesture("Two-finger drag", "scroll")
                    gesture("Hold still, then drag", "press and drag")
                    gesture("Three-finger tap", "open this panel")
                } header: {
                    Text("Gestures")
                }
            }
            .navigationTitle("ControlMyMac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.callout.monospacedDigit())
        }
    }

    private func slider(_ label: String, value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f×", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }

    private func gesture(_ name: String, _ meaning: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(meaning)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}
