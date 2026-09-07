import ControlMyMacKit
import Foundation

/// Asks the agent for a still and checks what comes back.
///
/// The point of the check is that the image is the *display's* size, not
/// the stream's: a screenshot assembled from the video would silently be
/// whatever rung the link happened to be on.
enum ScreenshotTest {

    static func run(host: String, port: UInt16, output: URL?) async -> Int32 {
        let client = VideoStreamClient(host: host, port: port, clientName: "screenshot-test")

        let lock = NSLock()
        var received: ScreenshotMessage?
        var streamWidth = 0

        client.onFormat = { _, message in
            lock.lock(); streamWidth = Int(message.width); lock.unlock()
        }
        client.onScreenshot = { shot in
            lock.lock(); received = shot; lock.unlock()
        }
        client.connect()

        // Let the stream come up, so the comparison against the encoded
        // width below is against a real number.
        for _ in 0..<50 {
            lock.lock(); let ready = streamWidth > 0; lock.unlock()
            if ready { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let requestedAt = Date()
        client.requestScreenshot(format: .heic)

        for _ in 0..<150 {
            lock.lock(); let done = received != nil; lock.unlock()
            if done { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let elapsed = Date().timeIntervalSince(requestedAt)
        client.disconnect()

        lock.lock()
        let shot = received
        let encodedWidth = streamWidth
        lock.unlock()

        guard let shot else {
            Log.error("no screenshot came back within 15s")
            return 1
        }
        guard shot.succeeded else {
            Log.error("agent reported: \(shot.message)")
            return 1
        }

        let megabytes = Double(shot.data.count) / 1_000_000
        Log.info("received \(shot.width)x\(shot.height) \(shot.format.fileExtension.uppercased()), \(String(format: "%.2f", megabytes)) MB in \(String(format: "%.2f", elapsed))s")
        Log.info("stream was \(encodedWidth)px wide at the time")

        guard !shot.data.isEmpty else {
            Log.error("payload is empty")
            return 1
        }
        // HEIC starts with a 4-byte length then 'ftyp'. Checking it here
        // means a truncated or mis-framed payload fails loudly rather
        // than landing in someone's photo library as a broken file.
        let magic = shot.data.subdata(in: 4..<min(8, shot.data.count))
        guard String(decoding: magic, as: UTF8.self) == "ftyp" else {
            Log.error("payload is not a valid HEIC container")
            return 1
        }
        guard Int(shot.width) > encodedWidth else {
            Log.error("screenshot is \(shot.width)px but the stream is \(encodedWidth)px — it was grabbed from the video, not the display")
            return 1
        }

        if let output {
            try? shot.data.write(to: output)
            Log.info("wrote \(output.path)")
        }

        Log.info("PASS: full-resolution still, larger than the stream, valid container")
        return 0
    }
}
