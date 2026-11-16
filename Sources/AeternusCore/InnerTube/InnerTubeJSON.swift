import Foundation

/// Read-only, forgiving view over a `JSONSerialization` tree. Every lookup on a missing or
/// mistyped node yields an empty node instead of failing, so a renderer YouTube drops or
/// renames only loses the fields that came from it.
struct JNode {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    static var empty: JNode { JNode(nil) }

    subscript(key: String) -> JNode { JNode((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> JNode {
        guard let array = raw as? [Any], array.indices.contains(index) else { return .empty }
        return JNode(array[index])
    }

    /// Follows a path of keys and indices: `node["a", 0, "b"]`.
    subscript(path: any JPathComponent...) -> JNode {
        var node = self
        for component in path {
            if let key = component as? String { node = node[key] }
            else if let index = component as? Int { node = node[index] }
        }
        return node
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var dict: [String: Any]? { raw as? [String: Any] }
    var array: [JNode] { (raw as? [Any])?.map(JNode.init) ?? [] }
    var keys: [String] { dict.map { Array($0.keys) } ?? [] }

    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, !(raw is Bool) { return n.stringValue }
        return nil
    }

    var int: Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double, d.isFinite { return Int(d) }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var bool: Bool? {
        if let b = raw as? Bool { return b }
        if let s = raw as? String { return s == "true" ? true : s == "false" ? false : nil }
        return nil
    }

    /// Text from any of YouTube's text shapes: plain string, `simpleText`, `runs`, or `content`.
    var text: String? {
        if let s = string { return s }
        if let s = self["simpleText"].string { return s }
        if let s = self["content"].string { return s }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        return runs.isEmpty ? nil : runs.joined()
    }

    /// First value stored under `key` anywhere below this node (depth-first, pre-order).
    func first(_ key: String, maxDepth: Int = 40) -> JNode {
        guard maxDepth > 0 else { return .empty }
        if let dict = raw as? [String: Any] {
            if let value = dict[key] { return JNode(value) }
            for value in dict.values {
                let found = JNode(value).first(key, maxDepth: maxDepth - 1)
                if found.exists { return found }
            }
        } else if let array = raw as? [Any] {
            for value in array {
                let found = JNode(value).first(key, maxDepth: maxDepth - 1)
                if found.exists { return found }
            }
        }
        return .empty
    }

    /// Every value stored under `key` below this node; does not descend into matches.
    func all(_ key: String, maxDepth: Int = 40) -> [JNode] {
        var result: [JNode] = []
        collect(key, maxDepth: maxDepth, into: &result)
        return result
    }

    private func collect(_ key: String, maxDepth: Int, into result: inout [JNode]) {
        guard maxDepth > 0 else { return }
        if let dict = raw as? [String: Any] {
            if let value = dict[key] { result.append(JNode(value)) }
            for (k, value) in dict where k != key {
                JNode(value).collect(key, maxDepth: maxDepth - 1, into: &result)
            }
        } else if let array = raw as? [Any] {
            for value in array { JNode(value).collect(key, maxDepth: maxDepth - 1, into: &result) }
        }
    }
}

protocol JPathComponent {}
extension String: JPathComponent {}
extension Int: JPathComponent {}

/// Parsing helpers for InnerTube's display strings and image lists.
enum InnerTubeText {
    /// Makes YouTube image URLs absolute: avatars are often protocol-relative (`//yt3.ggpht.com/...`).
    static func normalizeURL(_ url: String?) -> String? {
        guard var url = url?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        else if url.hasPrefix("http://") { url = "https://" + url.dropFirst("http://".count) }
        return url
    }

    /// Largest image from a `thumbnails` / `sources` list, or from a node that wraps one.
    static func bestImage(_ node: JNode) -> String? {
        var candidates = node["thumbnails"].array + node["sources"].array
        if candidates.isEmpty {
            candidates = node["image"]["sources"].array + node["thumbnail"]["thumbnails"].array
        }
        if candidates.isEmpty { candidates = node.array }
        let best = candidates
            .filter { $0["url"].string != nil }
            .max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        return normalizeURL(best?["url"].string)
    }

    /// "1:02:03" → 3723. Returns nil for "LIVE", "SHORTS", "" and similar.
    static func duration(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// "1,837,673,820 views" → 1837673820, "4.56M subscribers" → 4560000, "52 thousand views" → 52000,
    /// "No views" → 0. Returns nil when the text has no number.
    static func count(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("no ") { return 0 }
        let scanner = Array(lower)
        var start: Int?
        for (i, ch) in scanner.enumerated() where ch.isNumber { start = i; break }
        guard let start else { return nil }
        var numberText = ""
        var i = start
        while i < scanner.count, scanner[i].isNumber || scanner[i] == "," || scanner[i] == "." {
            numberText.append(scanner[i]); i += 1
        }
        let rest = String(scanner[i...]).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        if rest.hasPrefix("k") || rest.hasPrefix("thousand") { multiplier = 1e3 }
        else if rest.hasPrefix("m") && !rest.hasPrefix("mo") || rest.hasPrefix("million") { multiplier = 1e6 }
        else if rest.hasPrefix("b") || rest.hasPrefix("billion") { multiplier = 1e9 }
        else { multiplier = 1 }
        let cleaned = numberText.replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return Int((value * multiplier).rounded())
    }

    /// "Oct 24, 2009", "Premiered Oct 24, 2009", "Streamed live on Oct 24, 2009" → a date (UTC midnight).
    static func absoluteDate(_ text: String?) -> Date? {
        guard let text,
              let range = text.range(of: #"[A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}"#, options: .regularExpression)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let value = String(text[range]).replacingOccurrences(of: ".", with: "")
        for format in ["MMM d, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Plain text → the HTML-ish form Piped returns (and the UI strips), so `<`, `&` and newlines survive.
    static func html(_ text: String?) -> String? {
        guard let text else { return nil }
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func isViewsText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasSuffix("views") || lower.hasSuffix("view") || lower.contains("watching")
    }

    static func isDateText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasSuffix(" ago") || lower.hasPrefix("streamed") || lower.hasPrefix("premiere")
            || lower.hasPrefix("scheduled") || absoluteDate(text) != nil
    }
}
