import Foundation

/// Wire format shared by the Mac agent and every client.
///
/// Every message is length-prefixed so the framing survives TCP's
/// stream semantics:
///
///     u32  byteLength   (of everything after this field)
///     u8   messageType
///     ...  payload
///
/// All multi-byte integers are big-endian.
public enum Wire {
    public static let protocolVersion: UInt16 = 1
    public static let defaultPort: UInt16 = 47_800
    /// Refuse absurd lengths rather than allocating whatever a peer claims.
    public static let maxMessageBytes = 16 * 1024 * 1024
}

public enum MessageType: UInt8 {
    case hello           = 0x01   // client -> server, first on every connection
    case serverInfo      = 0x02   // server -> client
    case videoFormat     = 0x10   // server -> client, parameter sets
    case videoFrame      = 0x11   // server -> client
    case requestKeyframe = 0x20   // client -> server
    case clientStats     = 0x21   // client -> server
    case pointerMove     = 0x30   // client -> server
    case pointerButton   = 0x31   // client -> server
    case scroll          = 0x32   // client -> server
    case keyEvent        = 0x33   // client -> server
    case textInput       = 0x34   // client -> server
    case setQuality      = 0x40   // client -> server
    case qualityChanged  = 0x41   // server -> client
}

public enum QualityMode: UInt8 {
    /// The agent picks, and steps down when the link can't keep up.
    case auto   = 0
    case manual = 1
}

/// Why the stream quality changed — so the client can stay quiet about
/// a change the user just asked for, and speak up about one the network
/// forced.
public enum QualityChangeReason: UInt8 {
    case initial      = 0
    case manual       = 1
    case autoReduced  = 2
    case autoRestored = 3
}

/// The quality ladder, shared so the picker and the controller can never
/// disagree about what the rungs are.
public struct QualityLevel: Equatable, Hashable, Sendable {
    public let width: Int
    public let bitrate: Int

    public init(width: Int, bitrate: Int) {
        self.width = width
        self.bitrate = bitrate
    }

    public var label: String { "\(width)p wide" }

    /// Ordered widest first. Bitrates are chosen for screen content,
    /// which is mostly static and compresses far better than camera
    /// video at the same resolution.
    public static let ladder: [QualityLevel] = [
        QualityLevel(width: 1920, bitrate: 12_000_000),
        QualityLevel(width: 1600, bitrate: 10_000_000),
        QualityLevel(width: 1440, bitrate: 8_000_000),
        QualityLevel(width: 1280, bitrate: 6_000_000),
        QualityLevel(width: 1024, bitrate: 4_000_000),
        QualityLevel(width: 854,  bitrate: 2_500_000),
        QualityLevel(width: 640,  bitrate: 1_500_000),
    ]

    public static let defaultIndex = 3   // 1280

    public static func nearest(width: Int) -> QualityLevel {
        ladder.min(by: { abs($0.width - width) < abs($1.width - width) }) ?? ladder[defaultIndex]
    }
}

/// Platform-neutral on the wire; mapped to `CGEventFlags` on the Mac.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1 << 0)
    public static let control  = KeyModifiers(rawValue: 1 << 1)
    public static let option   = KeyModifiers(rawValue: 1 << 2)
    public static let command  = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

/// macOS virtual key codes for the keys that have no character to type.
///
/// These are the stable `kVK_*` values. Ordinary text does not go
/// through here at all — see `textInput`, which sidesteps keycodes
/// entirely and therefore works with any keyboard layout.
public enum VirtualKey {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16       = 48
    public static let space: UInt16     = 49
    public static let delete: UInt16    = 51    // backspace
    public static let escape: UInt16    = 53
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16      = 115
    public static let pageUp: UInt16    = 116
    public static let end: UInt16       = 119
    public static let pageDown: UInt16  = 121
    public static let left: UInt16      = 123
    public static let right: UInt16     = 124
    public static let down: UInt16      = 125
    public static let up: UInt16        = 126

    /// US-layout character to keycode, for modifier shortcuts only
    /// (Cmd-C and friends). Plain typing never needs this.
    private static let byCharacter: [Character: UInt16] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
        "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
        "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    public static func code(for character: Character) -> UInt16? {
        byCharacter[Character(character.lowercased())]
    }
}

public enum PointerMoveMode: UInt8 {
    /// Trackpad feel: a delta, not a destination. The default, because
    /// absolute mapping puts your fingertip over the thing you're aiming
    /// at and 1pt of phone covers ~9px of a Retina desktop.
    case relative = 0
    case absolute = 1
}

public enum MouseButton: UInt8 {
    case left   = 0
    case right  = 1
    case middle = 2
}

/// A client opens two connections to the same port and declares which is
/// which. They are kept separate on purpose: multiplexed onto one TCP
/// stream, head-of-line blocking would stall input behind video on every
/// hiccup.
public enum ChannelKind: UInt8 {
    case video   = 0
    case control = 1
}

public enum VideoCodec: UInt8 {
    case h264 = 0
    case hevc = 1
}

// MARK: - Messages

public struct HelloMessage {
    public var channel: ChannelKind
    public var version: UInt16
    public var clientName: String

    public init(channel: ChannelKind, version: UInt16 = Wire.protocolVersion, clientName: String) {
        self.channel = channel
        self.version = version
        self.clientName = clientName
    }
}

public struct ServerInfoMessage {
    public var version: UInt16
    public var displayWidth: UInt16
    public var displayHeight: UInt16
    public var nativeWidth: UInt16
    public var nativeHeight: UInt16

    public init(version: UInt16 = Wire.protocolVersion,
                displayWidth: UInt16, displayHeight: UInt16,
                nativeWidth: UInt16, nativeHeight: UInt16) {
        self.version = version
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
    }
}

/// Parameter sets travel out of band rather than inline in the stream.
/// Both ends are Apple, so the payload stays in AVCC (length-prefixed
/// NALU) form the whole way — no Annex-B conversion anywhere.
public struct VideoFormatMessage {
    public var codec: VideoCodec
    public var width: UInt16
    public var height: UInt16
    public var nalLengthSize: UInt8
    public var parameterSets: [Data]

    public init(codec: VideoCodec, width: UInt16, height: UInt16,
                nalLengthSize: UInt8, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.nalLengthSize = nalLengthSize
        self.parameterSets = parameterSets
    }
}

public struct VideoFrameMessage {
    public var ptsMicros: Int64
    /// Sender wall clock. Clocks aren't synced across machines, so the
    /// absolute delta is meaningless — but its *variance* is jitter,
    /// which is exactly what the adaptive controller needs.
    public var sentAtMicros: Int64
    public var isKeyframe: Bool
    public var payload: Data

    public init(ptsMicros: Int64, sentAtMicros: Int64, isKeyframe: Bool, payload: Data) {
        self.ptsMicros = ptsMicros
        self.sentAtMicros = sentAtMicros
        self.isKeyframe = isKeyframe
        self.payload = payload
    }
}

public struct ClientStatsMessage {
    public var framesDecoded: UInt32
    public var framesDropped: UInt32
    /// Offset-corrected arrival spread, *not* absolute latency — the
    /// two clocks are never synchronised, so only the variance means
    /// anything.
    public var transitMillis: UInt16

    public init(framesDecoded: UInt32, framesDropped: UInt32, transitMillis: UInt16) {
        self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped
        self.transitMillis = transitMillis
    }
}

/// Coordinates are in **stream pixel space** — the dimensions the client
/// was told in `videoFormat`. The server scales to display points, so
/// neither side has to know the other's scale factor.
public struct PointerMoveMessage {
    public var mode: PointerMoveMode
    public var x: Int32
    public var y: Int32

    public init(mode: PointerMoveMode, x: Int32, y: Int32) {
        self.mode = mode
        self.x = x
        self.y = y
    }
}

public struct PointerButtonMessage {
    public var button: MouseButton
    public var isDown: Bool
    /// 2 for a double-click; macOS needs this to synthesise one, a pair
    /// of single clicks will not do it.
    public var clickCount: UInt8

    public init(button: MouseButton, isDown: Bool, clickCount: UInt8 = 1) {
        self.button = button
        self.isDown = isDown
        self.clickCount = clickCount
    }
}

public struct ScrollMessage {
    public var deltaX: Int32
    public var deltaY: Int32

    public init(deltaX: Int32, deltaY: Int32) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct KeyEventMessage {
    public var keyCode: UInt16
    public var isDown: Bool
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, isDown: Bool, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.modifiers = modifiers
    }
}

/// Literal text, injected as a unicode string rather than as keystrokes.
///
/// This is why there is no keycode table for ordinary typing: it works
/// with any layout, any language, emoji, and dictation, none of which
/// map cleanly onto US-layout virtual keys.
public struct TextInputMessage {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct SetQualityMessage {
    public var mode: QualityMode
    public var width: UInt16
    public var bitrate: UInt32

    public init(mode: QualityMode, width: UInt16, bitrate: UInt32) {
        self.mode = mode
        self.width = width
        self.bitrate = bitrate
    }
}

public struct QualityChangedMessage {
    public var width: UInt16
    public var height: UInt16
    public var bitrate: UInt32
    public var mode: QualityMode
    public var reason: QualityChangeReason

    public init(width: UInt16, height: UInt16, bitrate: UInt32,
                mode: QualityMode, reason: QualityChangeReason) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.mode = mode
        self.reason = reason
    }
}

// MARK: - Decoded envelope

public enum Message {
    case hello(HelloMessage)
    case serverInfo(ServerInfoMessage)
    case videoFormat(VideoFormatMessage)
    case videoFrame(VideoFrameMessage)
    case requestKeyframe
    case clientStats(ClientStatsMessage)
    case pointerMove(PointerMoveMessage)
    case pointerButton(PointerButtonMessage)
    case scroll(ScrollMessage)
    case keyEvent(KeyEventMessage)
    case textInput(TextInputMessage)
    case setQuality(SetQualityMessage)
    case qualityChanged(QualityChangedMessage)
}

public enum WireError: LocalizedError {
    case truncated
    case unknownMessageType(UInt8)
    case badValue(String)
    case oversized(Int)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "Message ended early."
        case .unknownMessageType(let t): return String(format: "Unknown message type 0x%02X.", t)
        case .badValue(let what): return "Malformed \(what)."
        case .oversized(let n): return "Message claims \(n) bytes, over the cap."
        }
    }
}
