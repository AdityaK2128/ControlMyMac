import Foundation
import Network

/// An `NWConnection` that speaks length-prefixed `Message`s.
///
/// Shared by the agent and every client, so the framing only has one
/// implementation to get wrong.
public final class MessageConnection {

    public typealias MessageHandler = (Message) -> Void
    public typealias ErrorHandler = (Error) -> Void

    public let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    private let lock = NSLock()
    private var _pendingSends = 0
    /// Set before we cancel, so the ECANCELED that follows is reported
    /// as a clean close rather than an error.
    private var isCancelling = false
    private var didClose = false

    public var onMessage: MessageHandler?
    public var onError: ErrorHandler?
    public var onReady: (() -> Void)?
    public var onClosed: (() -> Void)?

    /// Sends handed to the kernel but not yet reported complete. The
    /// video sink watches this to decide when to drop frames instead of
    /// letting the send queue — and therefore latency — grow without
    /// bound on a slow link.
    public var pendingSends: Int {
        lock.lock(); defer { lock.unlock() }
        return _pendingSends
    }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLoop()
            case .failed(let error):
                self.report(error)
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        lock.lock(); isCancelling = true; lock.unlock()
        connection.cancel()
    }

    /// Cancellation races with in-flight reads and writes, each of which
    /// reports ECANCELED. Those aren't failures worth surfacing.
    private func report(_ error: Error) {
        lock.lock()
        let cancelling = isCancelling
        lock.unlock()
        if cancelling, let nwError = error as? NWError,
           case .posix(let code) = nwError, code == .ECANCELED {
            close()
            return
        }

        onError?(error)

        // A send to a dead socket fails but does not move the connection
        // to .cancelled or end the receive loop, so nothing else would
        // ever notice. Without this the server keeps pumping frames at a
        // closed socket — one error per frame, forever, with the corpse
        // still counted as a live client.
        if Self.isFatal(error) {
            cancel()
        }
    }

    private static func isFatal(_ error: Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        switch nwError {
        case .posix(let code):
            return code == .ENOTCONN || code == .EPIPE || code == .ECONNRESET
                || code == .ECONNABORTED || code == .EHOSTUNREACH || code == .ENETDOWN
        default:
            return false
        }
    }

    /// Both the cancelled state and an is-complete read can land; the
    /// caller should only hear about it once.
    private func close() {
        lock.lock()
        let already = didClose
        didClose = true
        lock.unlock()
        if !already { onClosed?() }
    }

    public func send(_ message: Message, completion: (() -> Void)? = nil) {
        let data = message.encoded()
        lock.lock(); _pendingSends += 1; lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self._pendingSends -= 1; self.lock.unlock()
            if let error { self.report(error) }
            completion?()
        })
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.report(error)
                return
            }
            if isComplete {
                self.close()
                return
            }
            self.receiveLoop()
        }
    }

    /// Pops every complete frame sitting in the buffer. TCP gives us a
    /// byte stream, so one receive can hold a fragment, several whole
    /// messages, or both.
    private func drain() {
        while buffer.count >= 4 {
            // Index relative to startIndex: Data slices keep their
            // origin, so hardcoding 0 here would be a latent bug.
            let start = buffer.startIndex
            let length = Int(buffer[start ..< start + 4].withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            })

            guard length >= 0, length <= Wire.maxMessageBytes else {
                onError?(WireError.oversized(length))
                connection.cancel()
                return
            }
            guard buffer.count >= 4 + length else { return }   // wait for more

            let bodyStart = start + 4
            let body = Data(buffer[bodyStart ..< bodyStart + length])
            buffer.removeSubrange(start ..< bodyStart + length)

            do {
                onMessage?(try Message.decode(body: body))
            } catch {
                onError?(error)
            }
        }
    }
}

// MARK: - Parameters

public extension NWParameters {
    /// TCP tuned for this app: Nagle off everywhere, because both the
    /// small control messages and the bursty video frames lose more to
    /// batching delay than they gain in efficiency.
    static func controlMyMac(serviceClass: NWParameters.ServiceClass) -> NWParameters {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        params.serviceClass = serviceClass
        return params
    }
}
