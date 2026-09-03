import SwiftUI

/// A single number with a label. Used in a grid on the dashboard, so it
/// fixes its own height — ragged cards read as broken layout.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A value the user is expected to retype on the phone, so it is
/// selectable, monospaced, and one click from the clipboard.
struct CopyableValue: View {
    let label: String
    let value: String
    var onCopy: (String) -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                onCopy(value)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Deliberately not nested inside `ChecklistRow`: a nested type would
/// drag the row's generic parameter into every mention of the status,
/// and callers would have to name a `Trailing` they don't have yet.
enum ChecklistStatus {
    case ok, warning, bad, unknown

    var symbol: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad:     return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .bad: return .red
        case .unknown: return .secondary
        }
    }
}

/// One line of the setup checklist.
struct ChecklistRow<Trailing: View>: View {
    let status: ChecklistStatus
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .font(.system(size: 16))
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 10)
    }
}

extension ChecklistRow where Trailing == EmptyView {
    init(status: ChecklistStatus, title: String, detail: String) {
        self.init(status: status, title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// Section wrapper: a titled card. Keeps the padding consistent so the
/// panes don't each invent their own.
struct Card<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content()
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

/// The dot next to the status text, pulsing only while a device is
/// actually connected.
///
/// The ring is a separate view that exists only while animating. That
/// is not a style choice: `repeatForever` is not cancelled by setting
/// its animated value back, so a dot that merely *stops being told to
/// pulse* keeps redrawing at display rate forever — about 20% of a CPU,
/// all day, on an app whose entire point is to cost nothing while idle.
/// Removing the view from the hierarchy is what actually stops it.
struct StatusDot: View {
    let color: Color
    var animated: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if animated {
                    PulseRing(color: color)
                }
            }
    }
}

private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.5), lineWidth: 6)
            .scaleEffect(expanded ? 1.8 : 1)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}
