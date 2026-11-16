import Foundation

/// Helpers that make JSON decoding tolerant of missing / mistyped fields,
/// mirroring the Kotlin defaults of the original LibreTube models.

/// Wraps a value whose decoding may fail; used to skip bad array elements.
struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Decodes a JSON array, skipping elements that fail to decode.
struct LossyArray<T: Decodable>: Decodable {
    let elements: [T]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [T] = []
        while !container.isAtEnd {
            if let element = try? container.decode(LossyElement<T>.self) {
                if let value = element.value { result.append(value) }
            } else if (try? container.decode(AnyDecodable.self)) == nil {
                // Could not advance past this element; stop to avoid looping forever.
                break
            }
        }
        elements = result
    }
}

/// Consumes any JSON value.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer {
    func string(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func string(_ key: Key, default value: String) -> String {
        string(key) ?? value
    }

    func int(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite,
           d >= Double(Int.min), d <= Double(Int.max) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            if let i = Int(s) { return i }
            if let d = Double(s), d.isFinite { return Int(d) }
        }
        return nil
    }

    func int(_ key: Key, default value: Int) -> Int {
        int(key) ?? value
    }

    func double(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func double(_ key: Key, default value: Double) -> Double {
        double(key) ?? value
    }

    func bool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func bool(_ key: Key, default value: Bool) -> Bool {
        bool(key) ?? value
    }

    func array<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        (try? decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements ?? []
    }

    func object<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

/// Decodes a top-level value leniently.
enum LenientJSON {
    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        try JSONDecoder().decode(LossyArray<T>.self, from: data).elements
    }
}
