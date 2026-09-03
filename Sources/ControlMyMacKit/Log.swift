import Foundation

/// Writes to stderr *and* a log file.
///
/// The agent normally gets launched with `open -a`, because that routes
/// it through LaunchServices and gives it its own TCC identity instead
/// of inheriting Terminal's. The cost is that stdout goes nowhere, so
/// everything also lands in ~/Library/Logs/ControlMyMac/agent.log.
public enum Log {
    /// Set once at startup so the agent and the viewer don't fight
    /// over the same file.
    private static var logName = "controlmymac"

    public static func configure(name: String) {
        logName = name
    }

    public static var fileURL: URL {
        // ~/Library/Logs on macOS; the app sandbox's own Library on iOS,
        // where there is no home directory to speak of.
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        #endif
        let dir = base.appendingPathComponent("ControlMyMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(logName).log")
    }

    private static var _handle: FileHandle?
    private static var handleReady = false

    private static var handle: FileHandle? {
        if !handleReady {
            handleReady = true
            let url = fileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            _handle = try? FileHandle(forWritingTo: url)
            _ = try? _handle?.seekToEnd()
        }
        return _handle
    }

    private static let queue = DispatchQueue(label: "com.controlmymac.log")

    // MARK: - Live tail
    //
    // The Mac app shows what the agent is doing as it happens. Tailing
    // the file from the GUI would mean polling and re-parsing it, so the
    // lines are also kept here — bounded, because this is a window onto
    // the log, not a second copy of it.

    private static let ringLock = NSLock()
    private static var ring: [String] = []
    private static let ringLimit = 400
    private static var listener: ((String) -> Void)?

    /// Called for every line after it is written. Fires on the logging
    /// queue, so a UI observer has to hop to the main actor itself.
    public static func observe(_ handler: ((String) -> Void)?) {
        ringLock.lock()
        listener = handler
        ringLock.unlock()
    }

    /// The most recent lines, oldest first.
    public static func recent() -> [String] {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: String)  { emit("INFO ", message) }
    public static func warn(_ message: String)  { emit("WARN ", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            handle?.write(Data(line.utf8))

            ringLock.lock()
            ring.append(String(line.dropLast()))
            if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
            let notify = listener
            ringLock.unlock()
            notify?(String(line.dropLast()))
        }
    }

    /// Flush before exit — the queue is async and process exit will
    /// otherwise drop the last few lines.
    public static func drain() {
        queue.sync { }
        try? handle?.synchronize()
    }
}
