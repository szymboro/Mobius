import Foundation

/// Minimal protobuf (proto2) wire-format writer: just enough to build `VideoPlaybackAbrRequest`.
struct ProtoWriter {
    private(set) var data = Data()

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        rawVarint(UInt64(field) << 3 | wireType)
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        rawVarint(value)
    }

    /// int32/int64 (negative values are sign-extended to 10 bytes, as protobuf requires).
    mutating func int(_ field: Int, _ value: Int) {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func float(_ field: Int, _ value: Float) {
        tag(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytes(field, nested.data)
    }
}

/// Minimal protobuf wire-format reader. Decodes one message level into field → values.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var pos = 0
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard pos < bytes.count, shift < 64 else { throw SabrStreamError.protocolError("truncated varint") }
                let b = bytes[pos]
                pos += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while pos < bytes.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                guard pos + 8 <= bytes.count else { throw SabrStreamError.protocolError("truncated fixed64") }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
                pos += 8
                value = .fixed64(v)
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, pos + length <= bytes.count else { throw SabrStreamError.protocolError("truncated bytes") }
                value = .bytes(Data(bytes[pos..<pos + length]))
                pos += length
            case 5:
                guard pos + 4 <= bytes.count else { throw SabrStreamError.protocolError("truncated fixed32") }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
                pos += 4
                value = .fixed32(v)
            default:
                throw SabrStreamError.protocolError("unsupported wire type \(key & 7)")
            }
            fields[field, default: []].append(value)
        }
    }

    func has(_ field: Int) -> Bool { fields[field] != nil }

    func uint(_ field: Int) -> UInt64? {
        guard case .varint(let v)? = fields[field]?.last else { return nil }
        return v
    }

    func int(_ field: Int) -> Int? {
        uint(field).map { Int(Int64(bitPattern: $0)) }
    }

    func bool(_ field: Int) -> Bool { (uint(field) ?? 0) != 0 }

    func bytes(_ field: Int) -> Data? {
        guard case .bytes(let d)? = fields[field]?.last else { return nil }
        return d
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    func message(_ field: Int) -> ProtoMessage? {
        bytes(field).flatMap { try? ProtoMessage($0) }
    }

    /// Repeated int32, accepting both packed and unpacked encodings.
    func repeatedInts(_ field: Int) -> [Int] {
        var result: [Int] = []
        for value in fields[field] ?? [] {
            switch value {
            case .varint(let v):
                result.append(Int(Int64(bitPattern: v)))
            case .bytes(let d):
                var pos = 0
                let b = [UInt8](d)
                while pos < b.count {
                    var v: UInt64 = 0, shift: UInt64 = 0
                    while pos < b.count {
                        let byte = b[pos]
                        pos += 1
                        v |= UInt64(byte & 0x7F) << shift
                        shift += 7
                        if byte & 0x80 == 0 { break }
                    }
                    result.append(Int(Int64(bitPattern: v)))
                }
            default:
                break
            }
        }
        return result
    }
}
