import SwiftUI

struct ContentView: View {
    @StateObject private var model = StreamViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.isIdle {
                connectionForm
            } else {
                streamView
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!model.isIdle)
        .persistentSystemOverlays(model.isIdle ? .automatic : .hidden)
        .task {
            if model.shouldAutoConnect { model.connect() }
        }
    }

    // MARK: - Connect

    private var connectionForm: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("ControlMyMac")
                    .font(.title2.weight(.semibold))
                Text("Connect over your tailnet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                LabeledField(label: "Host", text: $model.host,
                             keyboard: .numbersAndPunctuation)
                LabeledField(label: "Port", text: $model.port,
                             keyboard: .numberPad)
            }
            .padding(.horizontal)

            if let error = model.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: model.connect) {
                Text("Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Stream

    /// Nothing permanent on top of the video. A remote desktop needs
    /// every pixel, and a status bar you can't dismiss is the first
    /// thing that gets in the way.
    private var streamView: some View {
        ZStack {
            VideoLayerView(renderer: model.renderer)
                .ignoresSafeArea()

            GeometryReader { geometry in
                ZStack {
                    TrackpadView(
                    onMove:   { model.pointerMove($0) },
                    onScroll: { model.scroll($0, phase: $1) },
                    onClick:  { model.click($0, clickCount: $1) },
                    onButton: { model.button($0, isDown: $1) },
                    onDragEngaged: { model.dragLock = $0 },
                    onShowSettings: { model.showSettings = true },
                    onGesture: { model.performGesture($0) },
                    dragLock: model.dragLock,
                    maxAcceleration: model.maxAcceleration,
                    momentumScrolling: model.momentumScrolling
                )
                    .onAppear { model.viewSize = geometry.size }
                    .onChange(of: geometry.size) { _, new in model.viewSize = new }

                    // Above the trackpad in the stack, so its own taps
                    // and drags win inside its frame.
                    if model.showKeyboardButton {
                        FloatingKeyboardButton(
                            normalizedPosition: $model.keyboardButtonPosition,
                            containerSize: geometry.size,
                            isActive: model.keyboardActive,
                            onTap: { model.toggleKeyboard() }
                        )
                    }
                }
            }
            .ignoresSafeArea()

            // Zero-sized: it exists only to own the keyboard.
            KeyCaptureView(
                isActive: $model.keyboardActive,
                onText: { model.typeText($0) },
                onDeleteBackward: { model.deleteBackward() }
            )
            .frame(width: 0, height: 0)

            VStack {
                if case .failed(let why) = model.state {
                    disconnectedBanner(why)
                } else if let notice = model.bandwidthNotice {
                    bandwidthBanner(notice)
                }
                if let status = model.screenshotStatus {
                    statusToast(status)
                }
                Spacer()
                if model.keyboardActive {
                    // Left inside the keyboard's safe area, unlike the
                    // video, so it rides above the keyboard.
                    ModifierBar(
                        modifiers: $model.modifiers,
                        onSpecialKey: { model.specialKey($0) },
                        onDismiss: { model.keyboardActive = false }
                    )
                } else {
                    HintLabel()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.bandwidthNotice)
        .animation(.easeInOut(duration: 0.2), value: model.screenshotStatus)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model)
        }
    }

    private func bandwidthBanner(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.yellow)
            Text(notice)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if model.shouldSuggestAuto {
                Spacer()
                Button("Use Auto") { model.switchToAuto() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Without the old status pill there is nothing to distinguish a
    /// dropped connection from a frozen frame, so say so explicitly.
    /// Brief confirmation over the video — a screenshot saving, or a
    /// gesture going out. Deliberately transient: a remote desktop needs
    /// every pixel, so nothing here stays.
    private func statusToast(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.65), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func disconnectedBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Disconnected").font(.caption.weight(.semibold))
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Retry") {
                model.disconnect()
                model.connect()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// Shows the gestures once, then gets out of the way for good.
private struct HintLabel: View {
    @State private var visible = true

    var body: some View {
        Group {
            if visible {
                Text("three-finger tap for settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: 0.6)) { visible = false }
        }
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            TextField(label, text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body.monospaced())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
