import Foundation

public extension Message {

    /// Encode to a complete length-prefixed wire frame.
    func encoded() -> Data {
        var body = ByteWriter()

        switch self {
        case .hello(let m):
            body.u8(MessageType.hello.rawValue)
            body.u8(m.channel.rawValue)
            body.u16(m.version)
            body.string(m.clientName)

        case .serverInfo(let m):
            body.u8(MessageType.serverInfo.rawValue)
            body.u16(m.version)
            body.u16(m.displayWidth)
            body.u16(m.displayHeight)
            body.u16(m.nativeWidth)
            body.u16(m.nativeHeight)

        case .videoFormat(let m):
            body.u8(MessageType.videoFormat.rawValue)
            body.u8(m.codec.rawValue)
            body.u16(m.width)
            body.u16(m.height)
            body.u8(m.nalLengthSize)
            body.u8(UInt8(m.parameterSets.count))
            for set in m.parameterSets {
                body.u16(UInt16(set.count))
                body.bytes(set)
            }

        case .videoFrame(let m):
            body.u8(MessageType.videoFrame.rawValue)
            body.i64(m.ptsMicros)
            body.i64(m.sentAtMicros)
            body.u8(m.isKeyframe ? 1 : 0)
            body.bytes(m.payload)

        case .requestKeyframe:
            body.u8(MessageType.requestKeyframe.rawValue)

        case .clientStats(let m):
            body.u8(MessageType.clientStats.rawValue)
            body.u32(m.framesDecoded)
            body.u32(m.framesDropped)
            body.u16(m.transitMillis)

        case .pointerMove(let m):
            body.u8(MessageType.pointerMove.rawValue)
            body.u8(m.mode.rawValue)
            body.i32(m.x)
            body.i32(m.y)

        case .pointerButton(let m):
            body.u8(MessageType.pointerButton.rawValue)
            body.u8(m.button.rawValue)
            body.u8(m.isDown ? 1 : 0)
            body.u8(m.clickCount)

        case .scroll(let m):
            body.u8(MessageType.scroll.rawValue)
            body.i32(m.deltaX)
            body.i32(m.deltaY)

        case .keyEvent(let m):
            body.u8(MessageType.keyEvent.rawValue)
            body.u16(m.keyCode)
            body.u8(m.isDown ? 1 : 0)
            body.u32(m.modifiers.rawValue)

        case .textInput(let m):
            body.u8(MessageType.textInput.rawValue)
            body.bytes(Data(m.text.utf8))

        case .setQuality(let m):
            body.u8(MessageType.setQuality.rawValue)
            body.u8(m.mode.rawValue)
            body.u16(m.width)
            body.u32(m.bitrate)

        case .qualityChanged(let m):
            body.u8(MessageType.qualityChanged.rawValue)
            body.u16(m.width)
            body.u16(m.height)
            body.u32(m.bitrate)
            body.u8(m.mode.rawValue)
            body.u8(m.reason.rawValue)
        }

        var out = ByteWriter()
        out.u32(UInt32(body.data.count))
        out.bytes(body.data)
        return out.data
    }

    /// Decode one message body (the bytes after the u32 length prefix).
    static func decode(body: Data) throws -> Message {
        var r = ByteReader(body)
        let rawType = try r.u8()
        guard let type = MessageType(rawValue: rawType) else {
            throw WireError.unknownMessageType(rawType)
        }

        switch type {
        case .hello:
            guard let channel = ChannelKind(rawValue: try r.u8()) else {
                throw WireError.badValue("channel kind")
            }
            return .hello(HelloMessage(channel: channel,
                                       version: try r.u16(),
                                       clientName: try r.string()))

        case .serverInfo:
            return .serverInfo(ServerInfoMessage(version: try r.u16(),
                                                 displayWidth: try r.u16(),
                                                 displayHeight: try r.u16(),
                                                 nativeWidth: try r.u16(),
                                                 nativeHeight: try r.u16()))

        case .videoFormat:
            guard let codec = VideoCodec(rawValue: try r.u8()) else {
                throw WireError.badValue("codec")
            }
            let width = try r.u16()
            let height = try r.u16()
            let nalLengthSize = try r.u8()
            let count = Int(try r.u8())
            var sets: [Data] = []
            sets.reserveCapacity(count)
            for _ in 0..<count {
                let n = Int(try r.u16())
                sets.append(try r.bytes(n))
            }
            return .videoFormat(VideoFormatMessage(codec: codec, width: width, height: height,
                                                   nalLengthSize: nalLengthSize,
                                                   parameterSets: sets))

        case .videoFrame:
            let pts = try r.i64()
            let sentAt = try r.i64()
            let isKeyframe = try r.u8() == 1
            return .videoFrame(VideoFrameMessage(ptsMicros: pts, sentAtMicros: sentAt,
                                                 isKeyframe: isKeyframe, payload: r.rest()))

        case .requestKeyframe:
            return .requestKeyframe

        case .clientStats:
            return .clientStats(ClientStatsMessage(framesDecoded: try r.u32(),
                                                   framesDropped: try r.u32(),
                                                   transitMillis: try r.u16()))

        case .pointerMove:
            guard let mode = PointerMoveMode(rawValue: try r.u8()) else {
                throw WireError.badValue("pointer move mode")
            }
            return .pointerMove(PointerMoveMessage(mode: mode, x: try r.i32(), y: try r.i32()))

        case .pointerButton:
            guard let button = MouseButton(rawValue: try r.u8()) else {
                throw WireError.badValue("mouse button")
            }
            return .pointerButton(PointerButtonMessage(button: button,
                                                       isDown: try r.u8() == 1,
                                                       clickCount: try r.u8()))

        case .scroll:
            return .scroll(ScrollMessage(deltaX: try r.i32(), deltaY: try r.i32()))

        case .keyEvent:
            return .keyEvent(KeyEventMessage(keyCode: try r.u16(),
                                             isDown: try r.u8() == 1,
                                             modifiers: KeyModifiers(rawValue: try r.u32())))

        case .textInput:
            return .textInput(TextInputMessage(text: String(decoding: r.rest(), as: UTF8.self)))

        case .setQuality:
            guard let mode = QualityMode(rawValue: try r.u8()) else {
                throw WireError.badValue("quality mode")
            }
            return .setQuality(SetQualityMessage(mode: mode, width: try r.u16(), bitrate: try r.u32()))

        case .qualityChanged:
            let width = try r.u16()
            let height = try r.u16()
            let bitrate = try r.u32()
            guard let mode = QualityMode(rawValue: try r.u8()),
                  let reason = QualityChangeReason(rawValue: try r.u8()) else {
                throw WireError.badValue("quality change")
            }
            return .qualityChanged(QualityChangedMessage(width: width, height: height,
                                                         bitrate: bitrate, mode: mode,
                                                         reason: reason))
        }
    }
}
