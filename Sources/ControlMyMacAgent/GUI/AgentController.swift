import AppKit
import ControlMyMacKit
import Foundation
import SwiftUI

/// The main-actor face of `AgentEngine`.
///
/// The engine is deliberately not an ObservableObject: it runs on its
/// own queues and the capture path must never touch the main thread.
/// This polls it instead, at a rate a person can read.
@MainActor
final class AgentController: ObservableObject {

    static let shared = AgentController()

    private let engine = AgentEngine()
    private let prefs = Preferences.shared

    @Published private(set) var snapshot = AgentEngine.Snapshot()
    @Published private(set) var fps: Double = 0
    @Published private(set) var megabitsPerSecond: Double = 0
    @Published private(set) var logLines: [String] = []
    @Published private(set) var tailscale = TailscaleStatus()
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published var lastError: String?
    /// True once permissions have been granted in this session but the
    /// process still holds the old (denied) answer. Only a relaunch
    /// clears it — macOS decides TCC at task start.
    @Published private(set) var needsRelaunch = false

    private var timer: Timer?
    private var tickPhase = 0
    private var lastFrames = 0
    private var lastEncoded = 0
    private var lastBytes = 0
    private var lastSampleAt = Date()
    private var lastTailscaleProbe = Date.distantPast
    private var screenRecordingAtLaunch = false

    private init() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
        accessibilityGranted = InputInjector.isTrusted
        screenRecordingAtLaunch = screenRecordingGranted
        logLines = Log.recent()

        Log.observe { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        scheduleNextBeat()
        refreshTailscale()
    }

    // MARK: - Polling cadence
    //
    // The engine costs nothing while idle — 0.0% CPU with no viewer
    // connected. Polling it once a second regardless is the app's own
    // overhead, and paying that all day so an unwatched window can
    // redraw an unchanged number is exactly the waste this mode exists
    // to remove.

    private var hasVisibleWindow: Bool {
        NSApp?.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) } ?? false
    }

    private var beatInterval: TimeInterval {
        if isRunning && !snapshot.clients.isEmpty { return 1 }   // numbers worth watching
        if hasVisibleWindow { return 2 }                         // someone is looking
        return 5                                                 // nobody is
    }

    /// Tailscale is a subprocess spawn, so it gets a far slower beat
    /// than the in-process snapshot.
    private var tailscaleInterval: TimeInterval {
        hasVisibleWindow ? 15 : 120
    }

    private func scheduleNextBeat() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: beatInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beat()
                self?.scheduleNextBeat()
            }
        }
    }

    /// Called when the window appears, so opening it never shows a
    /// number that is several seconds stale.
    func windowBecameVisible() {
        beat()
        refreshTailscale()
        scheduleNextBeat()
    }

    // MARK: - Derived state

    var isRunning: Bool { snapshot.state.isRunning }

    var statusTitle: String {
        switch snapshot.state {
        case .running:  return snapshot.clients.isEmpty ? "Ready" : "Streaming"
        case .starting: return "Starting…"
        case .stopped:  return "Stopped"
        case .failed:   return "Failed"
        }
    }

    var statusDetail: String {
        switch snapshot.state {
        case .running where snapshot.clients.isEmpty:
            return "Waiting on port \(snapshot.port). Nothing is captured or encoded until your iPhone connects."
        case .running:
            let n = snapshot.clients.count
            return "\(n) \(n == 1 ? "device" : "devices") connected"
        case .starting: return "Bringing up capture and the listener."
        case .stopped:  return "Your Mac is not reachable from the iPhone."
        case .failed(let why): return why
        }
    }

    var statusColor: Color {
        switch snapshot.state {
        case .running:  return snapshot.clients.isEmpty ? .orange : .green
        case .starting: return .orange
        case .stopped:  return .secondary
        case .failed:   return .red
        }
    }

    var uptime: String {
        guard let started = snapshot.startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(started))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    var resolution: String {
        guard snapshot.outputWidth > 0 else { return "—" }
        return "\(snapshot.outputWidth)×\(snapshot.outputHeight)"
    }

    /// Everything that has to be true before the iPhone can connect.
    var isReadyToServe: Bool {
        screenRecordingGranted && !needsRelaunch
    }

    // MARK: - Control

    func start() {
        lastError = nil
        var config = AgentEngine.Configuration()
        config.port = UInt16(clamping: prefs.port)
        config.fps = prefs.fps
        config.codec = prefs.codec
        config.startLevel = prefs.startLevel
        config.autoQuality = prefs.autoQuality
        config.allowInput = prefs.allowInput
        config.keepAwake = prefs.keepAwake

        Task {
            do {
                try await engine.start(config)
            } catch {
                if case .failed(let why) = engine.state {
                    lastError = why
                } else {
                    lastError = error.localizedDescription
                }
            }
            beat()
        }
    }

    func stop() {
        Task {
            await engine.stop()
            beat()
        }
    }

    func toggle() { isRunning ? stop() : start() }

    /// Stop and start in one go, so a setting that only applies at
    /// startup can be picked up without the user doing it in two steps.
    func restart() {
        Task {
            await engine.stop()
            beat()
            start()
        }
    }

    /// Applies a preference that can change without a restart. The ones
    /// that can't (port, fps, codec) are marked as such in the UI.
    func applyLiveSettings() {
        engine.setInputAllowed(prefs.allowInput)
        engine.setQuality(auto: prefs.autoQuality, level: prefs.startLevel)
    }

    // MARK: - Polling

    private func beat() {
        let shot = engine.snapshot()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleAt)

        if elapsed > 0.2 {
            // Frame rate comes from the encoder: with nobody connected
            // the server sends nothing, and a dashboard reading 0 fps
            // while capture is running fine looks like a fault.
            let encodedDelta = max(0, shot.framesEncoded - lastEncoded)
            let byteDelta = max(0, shot.bytesSent - lastBytes)
            fps = Double(encodedDelta) / elapsed
            megabitsPerSecond = Double(byteDelta) * 8 / elapsed / 1_000_000
            lastEncoded = shot.framesEncoded
            lastFrames = shot.framesSent
            lastBytes = shot.bytesSent
            lastSampleAt = now
        }

        snapshot = shot
        screenRecordingGranted = ScreenRecordingPermission.isGranted
        accessibilityGranted = shot.accessibilityGranted

        // A TCC grant applies at task start. Getting one while running
        // changes the preflight answer but not what ScreenCaptureKit
        // will actually hand us, so the app has to say "relaunch".
        if screenRecordingGranted && !screenRecordingAtLaunch {
            needsRelaunch = true
        }

        // The quality controller's clean-second count assumes it is fed
        // every 2s. While streaming the beat is 1s, so every other one;
        // while idle the beat is slower, but there are no clients then
        // and `tick` has nothing to evaluate anyway.
        tickPhase += 1
        if tickPhase % 2 == 0 { engine.tick() }

        if Date().timeIntervalSince(lastTailscaleProbe) >= tailscaleInterval {
            refreshTailscale()
        }
    }

    func refreshTailscale() {
        lastTailscaleProbe = Date()
        // Shelling out blocks for as long as the daemon takes to answer,
        // which is not something to do on the main thread.
        Task.detached(priority: .utility) { [weak self] in
            let status = TailscaleStatus.probe()
            await self?.apply(tailscale: status)
        }
    }

    private func apply(tailscale status: TailscaleStatus) {
        tailscale = status
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    // MARK: - Actions the UI offers

    func requestScreenRecording() {
        ScreenRecordingPermission.request()
        openSettings("com.apple.preference.security?Privacy_ScreenCapture")
    }

    func requestAccessibility() {
        InputInjector.requestTrust()
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Relaunch so a fresh TCC decision is made at task start.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        Task {
            await engine.stop()
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            NSApp.terminate(nil)
        }
    }

    func quit() {
        Task {
            await engine.stop()
            Log.drain()
            NSApp.terminate(nil)
        }
    }
}
