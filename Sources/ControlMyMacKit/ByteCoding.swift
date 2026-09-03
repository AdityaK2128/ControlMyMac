import Foundation

/// Minimal big-endian byte writer.
public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8)   { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32)  { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func i64(_ v: Int64)  { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func bytes(_ v: Data) { data.append(v) }

    public mutating func string(_ v: String) {
        let utf8 = Data(v.utf8.prefix(255))
        u8(UInt8(utf8.count))
        data.append(utf8)
    }
}

/// Minimal big-endian byte reader. Every read is bounds-checked; a
/// malformed peer produces a thrown error, never a crash.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard remaining >= n else { throw WireError.truncated }
        let slice = data[offset ..< offset + n]
        offset += n
        return slice
    }

    public mutating func u8() throws -> UInt8 {
        try take(1).first ?? { throw WireError.truncated }()
    }

    public mutating func u16() throws -> UInt16 {
        let d = try take(2)
        return d.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    public mutating func u32() throws -> UInt32 {
        let d = try take(4)
        return d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    public mutating func i32() throws -> Int32 {
        let d = try take(4)
        return d.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }
    }

    public mutating func i64() throws -> Int64 {
        let d = try take(8)
        return d.withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(as: Int64.self)) }
    }

    public mutating func bytes(_ n: Int) throws -> Data {
        Data(try take(n))
    }

    public mutating func rest() -> Data {
        let slice = data[offset ..< data.endIndex]
        offset = data.endIndex
        return Data(slice)
    }

    public mutating func string() throws -> String {
        let n = Int(try u8())
        return String(decoding: try take(n), as: UTF8.self)
    }
}
