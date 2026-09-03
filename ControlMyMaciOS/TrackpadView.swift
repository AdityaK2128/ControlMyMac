import SwiftUI
import UIKit

/// Trackpad-style input surface laid over the video.
///
/// Deliberately relative, not absolute: mapping a fingertip straight to
/// a screen position means your finger covers the thing you're aiming
/// at, and one phone point spans roughly nine pixels of a Retina
/// desktop.
final class TrackpadUIView: UIView {

    var onMove: ((CGPoint) -> Void)?
    var onScroll: ((CGPoint) -> Void)?
    var onClick: ((MouseButton, UInt8) -> Void)?
    var onButton: ((MouseButton, Bool) -> Void)?
    var onDragEngaged: ((Bool) -> Void)?
    var onShowSettings: (() -> Void)?

    /// Upper bound on pointer acceleration, tunable from settings.
    var maxAcceleration: CGFloat = 2.2

    private var isDragging = false
    /// How far this touch has travelled. A hold only counts as a drag if
    /// the finger actually stayed put — otherwise slow, careful pointing
    /// engages a drag by accident, which is precisely when you least
    /// want one.
    private var travelSinceTouchDown: CGFloat = 0
    private let dragTravelLimit: CGFloat = 14

    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        setUpGestures()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private lazy var movePan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleMove))
        g.maximumNumberOfTouches = 1
        g.delegate = self
        return g
    }()

    private lazy var scrollPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        g.minimumNumberOfTouches = 2
        g.maximumNumberOfTouches = 2
        return g
    }()

    private lazy var tap: UITapGestureRecognizer = {
        UITapGestureRecognizer(target: self, action: #selector(handleTap))
    }()

    private lazy var twoFingerTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        g.numberOfTouchesRequired = 2
        return g
    }()

    /// Three fingers, because one and two are already a left and a right
    /// click. Nothing on screen has to be permanently reserved for it.
    private lazy var threeFingerTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        g.numberOfTouchesRequired = 3
        return g
    }()

    private lazy var longPress: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        g.minimumPressDuration = 0.5
        // Must stay small. Setting this large keeps the gesture alive
        // through movement, but it governs whether the gesture fires at
        // all — so a large value made every swipe engage a drag.
        g.allowableMovement = 12
        g.delegate = self
        return g
    }()

    private func setUpGestures() {
        // No `require(toFail:)` for double tap. That would make every
        // single click wait out the double-tap timeout — a visible
        // ~300ms lag on the most common action. Real mice report a click
        // count instead, so we do the same and time the taps ourselves.
        // A two-finger tap must lose to a three-finger tap, or opening
        // settings also fires a right click first.
        twoFingerTap.require(toFail: threeFingerTap)
        [movePan, scrollPan, tap, twoFingerTap, threeFingerTap, longPress]
            .forEach(addGestureRecognizer)
    }

    // MARK: - Handlers

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            travelSinceTouchDown = 0

        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)   // incremental, not cumulative
            travelSinceTouchDown += hypot(delta.x, delta.y)

            // Gentle acceleration. Steeper curves make the pointer feel
            // unpredictable, because gesture velocity is noisy enough
            // that the multiplier jumps around between frames.
            let velocity = gesture.velocity(in: self)
            let speed = hypot(velocity.x, velocity.y)
            let acceleration = min(maxAcceleration, max(1.0, speed / 1100))

            onMove?(CGPoint(x: delta.x * acceleration, y: delta.y * acceleration))

        case .ended, .cancelled:
            endDragIfNeeded()
            travelSinceTouchDown = 0

        default:
            break
        }
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        onScroll?(delta)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let now = Date().timeIntervalSince1970
        let point = gesture.location(in: self)

        // macOS builds a double-click from the click-count field, the
        // same way hardware does — so a second tap soon after the first,
        // in roughly the same place, reports count 2.
        let isDouble = (now - lastTapTime) < 0.4 && hypot(point.x - lastTapPoint.x,
                                                          point.y - lastTapPoint.y) < 40
        lastTapTime = now
        lastTapPoint = point
        onClick?(.left, isDouble ? 2 : 1)
    }

    @objc private func handleTwoFingerTap() { onClick?(.right, 1) }
    @objc private func handleThreeFingerTap() { onShowSettings?() }

    /// Press and hold *still*, then drag.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard travelSinceTouchDown <= dragTravelLimit else { return }
            beginDrag()
        case .ended, .cancelled, .failed:
            endDragIfNeeded()
        default:
            break
        }
    }

    // MARK: - Drag

    private func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        onButton?(.left, true)
        onDragEngaged?(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func endDragIfNeeded() {
        guard isDragging else { return }
        isDragging = false
        onButton?(.left, false)
        onDragEngaged?(false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Explicit latch from the UI, for drags too long or fiddly to hold.
    func setDragLock(_ locked: Bool) {
        if locked { beginDrag() } else { endDragIfNeeded() }
    }
}

extension TrackpadUIView: UIGestureRecognizerDelegate {
    /// The long press starts the drag and the pan carries it; they have
    /// to run at the same time or a press-and-drag never moves.
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gesture === longPress && other === movePan) ||
        (gesture === movePan && other === longPress)
    }
}

struct TrackpadView: UIViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onScroll: (CGPoint) -> Void
    let onClick: (MouseButton, UInt8) -> Void
    let onButton: (MouseButton, Bool) -> Void
    let onDragEngaged: (Bool) -> Void
    let onShowSettings: () -> Void
    var dragLock: Bool
    var maxAcceleration: CGFloat

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.onMove = onMove
        view.onScroll = onScroll
        view.onClick = onClick
        view.onButton = onButton
        view.onDragEngaged = onDragEngaged
        view.onShowSettings = onShowSettings
        view.maxAcceleration = maxAcceleration
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.maxAcceleration = maxAcceleration
        if context.coordinator.lastDragLock != dragLock {
            context.coordinator.lastDragLock = dragLock
            uiView.setDragLock(dragLock)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastDragLock = false
    }
}
