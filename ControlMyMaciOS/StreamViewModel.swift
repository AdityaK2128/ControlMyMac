import Combine
import CoreMedia
import Foundation
import UIKit

@MainActor
final class StreamViewModel: ObservableObject {

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var port: String {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }

    @Published private(set) var state: VideoStreamClient.State = .idle
    @Published private(set) var stats = VideoStreamClient.Stats()
    @Published private(set) var streamDescription = ""
    @Published private(set) var lastError: String?
    @Published var keyboardActive = false
    @Published var modifiers: KeyModifiers = []
    @Published var dragLock = false

    /// Encoded stream dimensions, learned from `videoFormat`. Pointer
    /// deltas are sent in this space.
    private var streamSize = CGSize.zero
    /// Size of the trackpad surface, from the SwiftUI layout.
    var viewSize = CGSize.zero

    /// How far the cursor travels per unit of finger travel, on top of
    /// the raw stream/view ratio. Tunable from settings — the right
    /// value is a matter of taste and hand size, not something to
    /// hard-code.
    @Published var sensitivity: CGFloat {
        didSet { UserDefaults.standard.set(Double(sensitivity), forKey: "sensitivity") }
    }
    @Published var scrollSensitivity: CGFloat {
        didSet { UserDefaults.standard.set(Double(scrollSensitivity), forKey: "scrollSensitivity") }
    }
    @Published var maxAcceleration: CGFloat {
        didSet { UserDefaults.standard.set(Double(maxAcceleration), forKey: "maxAcceleration") }
    }
    /// Which way a two-finger drag scrolls. Whether this feels right
    /// depends on the Mac's own "natural scrolling" setting, so it has
    /// to be a preference rather than a constant.
    @Published var invertScroll: Bool {
        didSet { UserDefaults.standard.set(invertScroll, forKey: "invertScroll") }
    }
    @Published var showSettings = false

    /// The floating keyboard button. Optional, because on a small screen
    /// any permanent control is in the way some of the time.
    @Published var showKeyboardButton: Bool {
        didSet { UserDefaults.standard.set(showKeyboardButton, forKey: "showKeyboardButton") }
    }
    /// Normalised 0...1 so it survives rotation and resizing.
    @Published var keyboardButtonPosition: CGPoint {
        didSet {
            UserDefaults.standard.set(Double(keyboardButtonPosition.x), forKey: "keyboardButtonX")
            UserDefaults.standard.set(Double(keyboardButtonPosition.y), forKey: "keyboardButtonY")
        }
    }

    /// nil means Auto; otherwise the pinned ladder rung.
    @Published var selectedQuality: QualityLevel? {
        didSet {
            guard oldValue != selectedQuality else { return }
            client?.setQuality(auto: selectedQuality == nil, level: selectedQuality)
            UserDefaults.standard.set(selectedQuality?.width ?? 0, forKey: "qualityWidth")
        }
    }
    @Published private(set) var activeQuality: String = "—"
    /// Transient message when the agent drops quality on its own — the
    /// user should know the picture got worse because of the link, not
    /// because something broke.
    @Published private(set) var bandwidthNotice: String?
    private var noticeTask: Task<Void, Never>?

    /// Sub-point movement would otherwise be rounded away entirely, so
    /// slow precise dragging would move the cursor not at all. Carrying
    /// the remainder forward is what makes fine targeting possible.
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    let renderer = VideoRenderer()

    private var client: VideoStreamClient?
    private var ticker: Timer?

    /// Set by launching with `-autoconnect YES`. UserDefaults picks up
    /// `-key value` launch arguments for free, which is how the app gets
    /// driven from `simctl` where there is no way to tap a button.
    let shouldAutoConnect: Bool

    init() {
        let defaults = UserDefaults.standard
        self.host = defaults.string(forKey: "host") ?? ""
        self.port = defaults.string(forKey: "port") ?? String(Wire.defaultPort)
        self.shouldAutoConnect = defaults.bool(forKey: "autoconnect")

        let storedSensitivity = defaults.double(forKey: "sensitivity")
        self.sensitivity = storedSensitivity > 0 ? CGFloat(storedSensitivity) : 1.6
        let storedScroll = defaults.double(forKey: "scrollSensitivity")
        self.scrollSensitivity = storedScroll > 0 ? CGFloat(storedScroll) : 2.0
        let storedAcceleration = defaults.double(forKey: "maxAcceleration")
        self.maxAcceleration = storedAcceleration > 0 ? CGFloat(storedAcceleration) : 2.2
        self.invertScroll = defaults.bool(forKey: "invertScroll")

        self.showKeyboardButton = defaults.object(forKey: "showKeyboardButton") as? Bool ?? true
        let storedX = defaults.object(forKey: "keyboardButtonX") as? Double
        let storedY = defaults.object(forKey: "keyboardButtonY") as? Double
        // Default sits low and right, clear of the status area and of
        // where a thumb naturally rests while dragging the pointer.
        self.keyboardButtonPosition = CGPoint(x: storedX ?? 0.88, y: storedY ?? 0.82)

        let storedWidth = defaults.integer(forKey: "qualityWidth")
        self.selectedQuality = storedWidth > 0
            ? QualityLevel.ladder.first { $0.width == storedWidth }
            : nil
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var streamSizeDescription: String {
        streamSize.width > 0
            ? "\(Int(streamSize.width)) x \(Int(streamSize.height))"
            : "—"
    }

    var throughputDescription: String {
        guard stats.framesReceived > 0 else { return "—" }
        return String(format: "%.2f MiB", Double(stats.bytesReceived) / 1_048_576)
    }

    var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    func connect() {
        guard client == nil else { return }
        guard let portNumber = UInt16(port) else {
            lastError = "Port must be a number between 1 and 65535."
            return
        }
        lastError = nil
        renderer.reset()

        let client = VideoStreamClient(host: host,
                                       port: portNumber,
                                       clientName: UIDevice.current.name)

        // Frames are enqueued straight from the network queue. Hopping
        // to main 30+ times a second would put the display layer behind
        // whatever else the main thread is doing, for no benefit — the
        // layer is safe to feed off-main.
        client.onFrame = { [renderer] sampleBuffer, _ in
            renderer.enqueue(sampleBuffer)
        }

        client.onFormat = { [weak self, renderer] _, message in
            // Flush before anything with the new format reaches the
            // layer, not after — by then it is already wedged.
            renderer.prepareForFormatChange()
            Task { @MainActor in
                self?.streamDescription = "\(message.codec == .hevc ? "HEVC" : "H.264") \(message.width)x\(message.height)"
                self?.streamSize = CGSize(width: Int(message.width), height: Int(message.height))
            }
        }

        client.onQualityChanged = { [weak self] quality in
            Task { @MainActor in
                self?.applyQualityChange(quality)
            }
        }

        client.onState = { [weak self] state in
            Task { @MainActor in
                self?.state = state
                if case .failed(let why) = state { self?.lastError = why }
            }
        }

        renderer.onNeedsKeyframe = { [weak client] in
            client?.requestKeyframe()
        }

        self.client = client
        client.connect()

        // The agent starts on its own default; tell it what this client
        // actually wants once the control channel is up.
        Task { [weak self, weak client] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, let client else { return }
            client.setQuality(auto: self.selectedQuality == nil, level: self.selectedQuality)
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func disconnect() {
        ticker?.invalidate()
        ticker = nil
        client?.disconnect()
        client = nil
        renderer.reset()
        state = .idle
        streamDescription = ""
        keyboardActive = false
        modifiers = []
        dragLock = false
        activeQuality = "—"
        bandwidthNotice = nil
        noticeTask?.cancel()
    }

    // MARK: - Input

    private var pointerScale: CGFloat {
        guard streamSize.width > 0, viewSize.width > 0 else { return 1 }
        return streamSize.width / viewSize.width * sensitivity
    }

    func pointerMove(_ delta: CGPoint) {
        let scale = pointerScale
        let x = delta.x * scale + moveRemainder.x
        let y = delta.y * scale + moveRemainder.y
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        moveRemainder = CGPoint(x: x - wholeX, y: y - wholeY)

        guard wholeX != 0 || wholeY != 0 else { return }
        client?.sendPointerMove(dx: Int32(wholeX), dy: Int32(wholeY))
    }

    func scroll(_ delta: CGPoint) {
        let direction: CGFloat = invertScroll ? -1 : 1
        let x = delta.x * scrollSensitivity * direction + scrollRemainder.x
        let y = delta.y * scrollSensitivity * direction + scrollRemainder.y
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: x - wholeX, y: y - wholeY)

        guard wholeX != 0 || wholeY != 0 else { return }
        client?.sendScroll(dx: Int32(wholeX), dy: Int32(wholeY))
    }

    func click(_ button: MouseButton, clickCount: UInt8) {
        client?.sendClick(button, clickCount: clickCount)
    }

    func button(_ button: MouseButton, isDown: Bool) {
        client?.sendPointerButton(button, isDown: isDown)
    }

    // MARK: - Quality

    private func applyQualityChange(_ quality: QualityChangedMessage) {
        activeQuality = "\(quality.width) x \(quality.height) · \(String(format: "%.1f", Double(quality.bitrate) / 1_000_000)) Mbps"

        // Only speak up when the network forced the change. Announcing a
        // change the user just made themselves is noise.
        switch quality.reason {
        case .autoReduced:
            showNotice("Bandwidth low — dropped to \(quality.width)p")
        case .autoRestored:
            showNotice("Link recovered — back to \(quality.width)p")
        case .manual, .initial:
            break
        }
    }

    private func showNotice(_ text: String) {
        bandwidthNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.bandwidthNotice = nil }
        }
    }

    /// If the link is struggling while pinned to a fixed resolution, the
    /// user's own setting is the problem — so offer the fix rather than
    /// silently overriding a deliberate choice.
    var shouldSuggestAuto: Bool {
        selectedQuality != nil && bandwidthNotice != nil
    }

    func switchToAuto() {
        selectedQuality = nil
    }

    // MARK: - Keyboard

    func toggleKeyboard() {
        keyboardActive.toggle()
    }

    func typeText(_ text: String) {
        // Return arrives as a newline character, but pasting "\n" into a
        // remote app is not the same thing as pressing Return.
        if text == "\n" || text == "\r" {
            specialKey(VirtualKey.returnKey)
            return
        }

        // With a modifier armed this is a shortcut, not text — and a
        // shortcut needs a real keycode, since ⌘C is not "type a C".
        if !modifiers.isEmpty, let character = text.first,
           let code = VirtualKey.code(for: character) {
            client?.sendKey(code, modifiers: modifiers)
            modifiers = []
            return
        }

        client?.sendText(text)
    }

    func deleteBackward() {
        specialKey(VirtualKey.delete)
    }

    func specialKey(_ code: UInt16) {
        client?.sendKey(code, modifiers: modifiers)
        modifiers = []
    }

    private func tick() {
        guard let client else { return }
        stats = client.stats
        client.sendStats(decoded: renderer.framesEnqueued,
                         dropped: renderer.framesDropped)
    }
}
