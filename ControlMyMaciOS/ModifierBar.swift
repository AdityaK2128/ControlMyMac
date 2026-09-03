import SwiftUI

/// The keys a phone keyboard doesn't have.
struct ModifierBar: View {
    @Binding var modifiers: KeyModifiers
    let onSpecialKey: (UInt16) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                key("esc") { onSpecialKey(VirtualKey.escape) }
                key("tab") { onSpecialKey(VirtualKey.tab) }
                modifier("⌃", .control)
                modifier("⌥", .option)
                modifier("⇧", .shift)
                modifier("⌘", .command)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 32)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                key("↑") { onSpecialKey(VirtualKey.up) }
                key("↓") { onSpecialKey(VirtualKey.down) }
                key("←") { onSpecialKey(VirtualKey.left) }
                key("→") { onSpecialKey(VirtualKey.right) }
                key("⌦") { onSpecialKey(VirtualKey.forwardDelete) }
                key("home") { onSpecialKey(VirtualKey.home) }
                key("end") { onSpecialKey(VirtualKey.end) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 34, minHeight: 32)
        }
        .buttonStyle(.bordered)
    }

    /// One-shot: arming a modifier applies it to the next key and then
    /// clears, so you can never strand the Mac with ⌘ stuck down.
    private func modifier(_ label: String, _ flag: KeyModifiers) -> some View {
        let isOn = modifiers.contains(flag)
        return Button {
            if isOn { modifiers.remove(flag) } else { modifiers.insert(flag) }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .frame(minWidth: 34, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
    }
}
