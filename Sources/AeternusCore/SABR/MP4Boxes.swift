import Foundation

/// Tiny ISO-BMFF helpers: top-level box listing and `sidx` parsing.
enum MP4Boxes {
    struct Box {
        let type: String
        let range: Range<Int>
    }

    /// Top-level boxes of `data` (stops at the first malformed header).
    static func topLevel(_ data: Data) -> [Box] {
        let b = [UInt8](data)
        var boxes: [Box] = []
        var pos = 0
        while pos + 8 <= b.count {
            var size = Int(be32(b, pos))
            let type = String(bytes: b[pos + 4..<pos + 8], encoding: .ascii) ?? "????"
            if size == 1, pos + 16 <= b.count {
                size = Int(be64(b, pos + 8))
            } else if size == 0 {
                size = b.count - pos
            }
            guard size >= 8, pos + size <= b.count else { break }
            boxes.append(Box(type: type, range: pos..<pos + size))
            pos += size
        }
        return boxes
    }

    /// Subsegment durations (seconds) from the first `sidx` box in `data`.
    static func sidxDurations(_ data: Data) -> [Double]? {
        guard let box = topLevel(data).first(where: { $0.type == "sidx" }) else { return nil }
        let b = [UInt8](data[box.range])
        guard b.count >= 32 else { return nil }
        let version = b[8]
        var p = 12 + 4 // full box header + reference_ID
        let timescale = Double(be32(b, p))
        p += 4
        p += version == 0 ? 8 : 16 // earliest_presentation_time + first_offset
        p += 2 // reserved
        guard p + 2 <= b.count, timescale > 0 else { return nil }
        let count = Int(be16(b, p))
        p += 2
        guard p + count * 12 <= b.count else { return nil }
        return (0..<count).map { i in Double(be32(b, p + i * 12 + 4)) / timescale }
    }

    private static func be16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }
    private static func be32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
    private static func be64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(be32(b, p)) << 32 | UInt64(be32(b, p + 4)) }
}
