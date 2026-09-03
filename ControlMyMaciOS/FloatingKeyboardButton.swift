import SwiftUI

/// A draggable keyboard button that floats over the video.
///
/// Position is stored normalised (0...1) rather than in points, so it
/// survives rotation and any change in view size — a button parked in
/// the bottom-right corner stays in the bottom-right corner rather than
/// ending up off-screen or in the middle.
struct FloatingKeyboardButton: View {

    @Binding var normalizedPosition: CGPoint
    let containerSize: CGSize
    let isActive: Bool
    let onTap: () -> Void

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false

    private let diameter: CGFloat = 52
    /// Keeps the button fully on screen no matter where it's dropped.
    private var margin: CGFloat { diameter / 2 + 8 }

    var body: some View {
        Image(systemName: isActive ? "keyboard.chevron.compact.down.fill" : "keyboard")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .frame(width: diameter, height: diameter)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle().strokeBorder(.white.opacity(isDragging ? 0.35 : 0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: isDragging ? 12 : 5, y: 2)
            .scaleEffect(isDragging ? 1.12 : 1)
            .position(currentPoint)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isDragging)
            .onTapGesture { onTap() }
            // A minimum distance keeps a tap from registering as a drag;
            // at zero the drag gesture would swallow every tap.
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        dragTranslation = value.translation
                    }
                    .onEnded { _ in
                        normalizedPosition = normalize(currentPoint)
                        dragTranslation = .zero
                        isDragging = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
    }

    private var currentPoint: CGPoint {
        let base = denormalize(normalizedPosition)
        return clamp(CGPoint(x: base.x + dragTranslation.width,
                             y: base.y + dragTranslation.height))
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * containerSize.width,
                y: point.y * containerSize.height)
    }

    private func normalize(_ point: CGPoint) -> CGPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return normalizedPosition }
        return CGPoint(x: point.x / containerSize.width,
                       y: point.y / containerSize.height)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, margin), max(containerSize.width - margin, margin)),
            y: min(max(point.y, margin), max(containerSize.height - margin, margin)))
    }
}
