import Foundation

public extension String {
    /// Extracts a YouTube video id from "/watch?v=ID", full YouTube/Piped urls,
    /// "youtu.be/ID", "/shorts/ID", "/embed/ID", "/live/ID" or a bare id.
    var videoIdFromURL: String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Self.queryValue(named: "v", in: s) { return v }
        for marker in ["youtu.be/", "/shorts/", "/embed/", "/live/", "/v/"] {
            if let r = s.range(of: marker) {
                return Self.firstSegment(String(s[r.upperBound...]))
            }
        }
        return Self.lastPathSegment(s)
    }

    /// Extracts a channel id from "/channel/ID", full urls, or a bare id.
    /// Handle ("/@name"), "/c/name" and "/user/name" urls return the name part.
    var channelIdFromURL: String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["/channel/", "/c/", "/user/"] {
            if let r = s.range(of: marker) {
                return Self.firstSegment(String(s[r.upperBound...]))
            }
        }
        if let r = s.range(of: "/@") {
            return "@" + Self.firstSegment(String(s[r.upperBound...]))
        }
        return Self.lastPathSegment(s)
    }

    /// Extracts a playlist id from "/playlist?list=ID", any url with `list=` or a bare id.
    var playlistIdFromURL: String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = Self.queryValue(named: "list", in: s) { return list }
        return Self.lastPathSegment(s)
    }
}

extension String {
    /// Returns the value of a query parameter, tolerating relative urls like "/watch?v=ID".
    fileprivate static func queryValue(named name: String, in s: String) -> String? {
        guard let q = s.firstIndex(of: "?") else { return nil }
        var query = s[s.index(after: q)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == name[...] else { continue }
            let value = String(parts[1])
            let decoded = value.removingPercentEncoding ?? value
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    /// Text up to the first "/", "?", "&" or "#".
    fileprivate static func firstSegment(_ s: String) -> String {
        String(s.prefix { !"/?&#".contains($0) })
    }

    /// The last non-empty path component, ignoring any query/fragment.
    fileprivate static func lastPathSegment(_ s: String) -> String {
        var path = s[...]
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<q] }
        let comps = path.split(separator: "/")
        return comps.last.map(String.init) ?? String(path)
    }
}
