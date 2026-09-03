import ControlMyMacKit
import Foundation

/// Headless serving, for scripts and regression tests.
///
/// The wiring lives in `AgentEngine`, shared with the Mac app — this is
/// only the command-line shell around it: start, tick, log, stop.
func runServe(_ options: Options) async -> Int32 {
    let engine = AgentEngine()

    if !InputInjector.isTrusted {
        InputInjector.requestTrust()
    }

    var config = AgentEngine.Configuration()
    config.port = options.port
    config.fps = options.fps
    config.codec = options.codec
    config.startLevel = QualityLevel.nearest(width: options.maxWidth)
    config.autoQuality = options.autoQuality

    do {
        try await engine.start(config)
    } catch {
        Log.error("could not start: \(error.localizedDescription)")
        if case .failed(let why) = engine.state { Log.error(why) }
        if !ScreenRecordingPermission.isGranted { Log.error(ScreenRecordingPermission.settingsHint) }
        return 2
    }

    let stopped = AsyncStopSignal()
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler { Log.info("interrupted"); stopped.signal() }
    sigintSource.resume()

    let deadline = options.duration > 0
        ? Date().addingTimeInterval(options.duration)
        : Date.distantFuture

    var ticks = 0
    var lastSent = 0
    while !stopped.isSet && Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if stopped.isSet { break }

        engine.tick()

        ticks += 1
        if ticks % 5 == 0 {
            let shot = engine.snapshot()
            if !shot.clients.isEmpty || shot.framesSent != lastSent {
                let mib = Double(shot.bytesSent) / 1_048_576
                Log.info("clients \(shot.clients.count) | sent \(shot.framesSent) frames (\(String(format: "%.1f", mib)) MiB) | \(shot.qualityWidth)p | dropped \(shot.framesDropped)")
            }
            lastSent = shot.framesSent
        }
    }

    sigintSource.cancel()
    let final = engine.snapshot()
    await engine.stop()
    Log.info("posted \(final.inputEvents) input events")
    Log.info("sent \(final.framesSent) frames, \(String(format: "%.2f", Double(final.bytesSent) / 1_048_576)) MiB, dropped \(final.framesDropped) to backpressure")
    return 0
}

/// Tiny thread-safe flag; the signal handler and the loop touch it from
/// different queues.
final class AsyncStopSignal {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func signal() {
        lock.lock(); value = true; lock.unlock()
    }
}
