import ControlMyMacKit
import Foundation

/// Chooses the stream's resolution and bitrate.
///
/// In auto mode it walks the shared ladder: down quickly when the link
/// is struggling, back up slowly and only after a sustained clean spell.
/// Asymmetric on purpose — dropping late means a visibly broken stream,
/// while climbing early means oscillating between two levels, which
/// looks worse than simply staying low.
final class QualityController {

    private let lock = NSLock()
    private var _mode: QualityMode = .auto
    private var index = QualityLevel.defaultIndex

    private var dropsThisWindow = 0
    private var cleanSeconds = 0

    /// Congestion signal. Backpressure drops are the honest one: they
    /// mean frames were ready and the socket wasn't.
    private let dropsToStepDown = 4
    private let cleanSecondsToStepUp = 20
    private let evaluationInterval = 2

    /// `levelChanged` is false when only the mode moved (auto <-> manual
    /// at the same rung). Callers must not rebuild the encoder in that
    /// case: a needless reconfigure changes the parameter sets and can
    /// wedge a client's display layer for no benefit at all.
    var onChange: ((QualityLevel, QualityChangeReason, Bool) -> Void)?

    var mode: QualityMode {
        lock.lock(); defer { lock.unlock() }
        return _mode
    }

    var current: QualityLevel {
        lock.lock(); defer { lock.unlock() }
        return QualityLevel.ladder[index]
    }

    // MARK: - Control

    func setManual(width: Int, bitrate: Int) {
        lock.lock()
        let previousIndex = index
        let previousMode = _mode
        let newIndex = QualityLevel.ladder.firstIndex { $0.width == width }
            ?? QualityLevel.ladder.firstIndex { $0.width == QualityLevel.nearest(width: width).width }
            ?? QualityLevel.defaultIndex

        let levelChanged = newIndex != previousIndex
        let modeChanged = previousMode != .manual

        // Decide first, mutate second. Writing `_mode` before the guard
        // meant a no-op request still flipped the mode, which made the
        // next setAuto look like a real transition and rebuild the
        // encoder for nothing.
        guard levelChanged || modeChanged else {
            lock.unlock()
            return
        }

        _mode = .manual
        index = newIndex
        cleanSeconds = 0
        dropsThisWindow = 0
        let level = QualityLevel.ladder[index]
        lock.unlock()
        Log.info("quality: manual -> \(level.width)p @ \(level.bitrate / 1_000_000) Mbps\(levelChanged ? "" : " (mode only)")")
        onChange?(level, .manual, levelChanged)
    }

    func setAuto() {
        lock.lock()
        let previousMode = _mode
        _mode = .auto
        cleanSeconds = 0
        dropsThisWindow = 0
        let level = QualityLevel.ladder[index]
        lock.unlock()

        guard previousMode != .auto else { return }
        Log.info("quality: auto (currently \(level.width)p)")
        // Mode only — the rung is unchanged, so nothing to reconfigure.
        onChange?(level, .manual, false)
    }

    func recordDrops(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        dropsThisWindow += count
        lock.unlock()
    }

    /// Called on a timer; returns the new level if it changed.
    func evaluate() {
        lock.lock()

        guard _mode == .auto else {
            dropsThisWindow = 0
            lock.unlock()
            return
        }

        var change: (QualityLevel, QualityChangeReason)?

        if dropsThisWindow >= dropsToStepDown, index < QualityLevel.ladder.count - 1 {
            index += 1
            cleanSeconds = 0
            change = (QualityLevel.ladder[index], .autoReduced)
        } else if dropsThisWindow == 0 {
            cleanSeconds += evaluationInterval
            if cleanSeconds >= cleanSecondsToStepUp, index > 0 {
                index -= 1
                cleanSeconds = 0
                change = (QualityLevel.ladder[index], .autoRestored)
            }
        } else {
            // Some drops, but not enough to step down: hold, and don't
            // let this count as a clean interval either.
            cleanSeconds = 0
        }

        dropsThisWindow = 0
        lock.unlock()

        if let (level, reason) = change {
            Log.info("quality: \(reason == .autoReduced ? "reduced" : "restored") -> \(level.width)p @ \(level.bitrate / 1_000_000) Mbps")
            onChange?(level, reason, true)
        }
    }
}
