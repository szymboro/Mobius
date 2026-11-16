import Foundation

/// UMP part ids used by SABR (see `app/src/main/proto/video_streaming/ump_part_id.proto`).
enum UMPPartType: Int {
    case mediaHeader = 20
    case media = 21
    case mediaEnd = 22
    case nextRequestPolicy = 35
    case formatInitializationMetadata = 42
    case sabrRedirect = 43
    case sabrError = 44
    case sabrSeek = 45
    case reloadPlayerResponse = 46
    case sabrContextUpdate = 57
    case streamProtectionStatus = 58
    case sabrContextSendingPolicy = 59
}

/// Reader for YouTube's UMP container (port of Android's `UmpParser.kt`).
/// https://github.com/gsuberland/UMP_Format/blob/main/UMP_Format.md
struct UMPReader {
    struct Part {
        let type: Int
        let data: Data
    }

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - position }

    /// UMP variable-sized integer: the number of leading 1 bits in the first byte (max 4) gives the extra byte count.
    mutating func readVarint() -> UInt64? {
        guard position < bytes.count else { return nil }
        let prefix = bytes[position]
        position += 1
        var size = 1
        while size < 5, prefix & (0x80 >> (size - 1)) != 0 { size += 1 }
        var result: UInt64 = 0
        var shift: UInt64 = 0
        if size != 5 {
            shift = UInt64(8 - size)
            result = UInt64(prefix) & ((1 << shift) - 1)
        }
        for _ in 1..<size {
            guard position < bytes.count else { return nil }
            result |= UInt64(bytes[position]) << shift
            position += 1
            shift += 8
        }
        return result
    }

    mutating func readPart() -> Part? {
        let start = position
        guard let type = readVarint(), let size = readVarint(), position + Int(size) <= bytes.count else {
            position = start
            return nil
        }
        let data = Data(bytes[position..<position + Int(size)])
        position += Int(size)
        return Part(type: Int(type), data: data)
    }

    /// Bytes after the current position.
    func rest() -> Data { Data(bytes[position...]) }
}
