import Foundation

/// Data read from an export file of another app.
public struct ImportResult: Sendable {
    public var format: String
    public var subscriptions: [Subscription] = []
    public var playlists: [LocalPlaylist] = []
    public var history: [WatchHistoryEntry] = []

    public var isEmpty: Bool { subscriptions.isEmpty && playlists.isEmpty && history.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !subscriptions.isEmpty { parts.append("\(subscriptions.count) subscriptions") }
        if !playlists.isEmpty { parts.append("\(playlists.count) playlists") }
        if !history.isEmpty { parts.append("\(history.count) history entries") }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: ", ")
    }
}

public enum ImportError: Error, Sendable, LocalizedError {
    case unrecognized

    public var errorDescription: String? {
        "Unrecognised file. Supported: NewPipe subscriptions (.json), LibreTube/Piped backup (.json), FreeTube subscriptions (.db), YouTube Takeout subscriptions (.csv), or a list of channel/video URLs (.txt)."
    }
}

/// Reads the same formats as LibreTube's Android `ImportHelper`, auto-detecting which one a file is.
public enum Importer {
    public static func parse(_ data: Data, filename: String) throws -> ImportResult {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let result = newPipe(json) ?? libreTubeBackup(json), !result.isEmpty { return result }
        }
        let text = String(decoding: data, as: UTF8.self)
        if let result = freeTube(text), !result.isEmpty { return result }
        if let result = takeoutCSV(text), !result.isEmpty { return result }
        let result = urlList(text, filename: filename)
        if !result.isEmpty { return result }
        throw ImportError.unrecognized
    }

    // MARK: NewPipe — Settings › Backup and restore › Export subscriptions

    /// `{"app_version": "...", "subscriptions": [{"service_id": 0, "url": ".../channel/UC…", "name": "…"}]}`
    static func newPipe(_ json: [String: Any]) -> ImportResult? {
        guard json["app_version"] != nil || json["app_version_int"] != nil,
              let subs = json["subscriptions"] as? [[String: Any]] else { return nil }
        var result = ImportResult(format: "NewPipe")
        result.subscriptions = subs.compactMap { sub in
            // service_id 0 is YouTube; other services (SoundCloud, PeerTube…) can't be used here.
            guard (sub["service_id"] as? Int ?? 0) == 0, let url = sub["url"] as? String else { return nil }
            return subscription(fromURL: url, name: sub["name"] as? String)
        }
        return result
    }

    // MARK: LibreTube / Piped backup

    static func libreTubeBackup(_ json: [String: Any]) -> ImportResult? {
        let keys = ["subscriptions", "localSubscriptions", "watchHistory", "localPlaylists", "playlists"]
        guard keys.contains(where: { json[$0] != nil }) else { return nil }
        var result = ImportResult(format: (json["format"] as? String) ?? "LibreTube")

        let subs = (json["subscriptions"] ?? json["localSubscriptions"]) as? [Any] ?? []
        result.subscriptions = subs.compactMap { item in
            if let url = item as? String { return subscription(fromURL: url, name: nil) } // Piped: plain URLs
            guard let sub = item as? [String: Any] else { return nil }
            let name = sub["name"] as? String
            if let id = sub["channelId"] as? String, !id.isEmpty {
                return Subscription(channelId: id, name: name, avatar: sub["avatar"] as? String,
                                    verified: sub["verified"] as? Bool ?? false)
            }
            return (sub["url"] as? String).flatMap { subscription(fromURL: $0, name: name) }
        }

        var positions: [String: Double] = [:]
        for item in json["watchPositions"] as? [[String: Any]] ?? [] {
            if let id = item["videoId"] as? String, let ms = number(item["position"]) {
                positions[id] = ms / 1000
            }
        }
        let now = Date()
        result.history = (json["watchHistory"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let id = item["videoId"] as? String, !id.isEmpty else { return nil }
            // Mobius backups carry the watch time (ms); otherwise keep the file's order, newest first.
            let watchedAt = number(item["watchedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? now.addingTimeInterval(-Double(index))
            return WatchHistoryEntry(
                videoId: id, title: item["title"] as? String, uploader: item["uploader"] as? String,
                uploaderUrl: item["uploaderUrl"] as? String, thumbnail: item["thumbnailUrl"] as? String,
                duration: number(item["duration"]).map { Int($0) }, watchedAt: watchedAt,
                position: positions[id] ?? 0
            )
        }

        // LibreTube's own format: [{"playlist": {...}, "videos": [...]}]
        for item in json["localPlaylists"] as? [[String: Any]] ?? [] {
            let info = item["playlist"] as? [String: Any] ?? [:]
            let videos = (item["videos"] as? [[String: Any]] ?? []).compactMap { video -> StreamItem? in
                guard let id = video["videoId"] as? String, !id.isEmpty else { return nil }
                return StreamItem(
                    url: "/watch?v=\(id)", title: video["title"] as? String,
                    thumbnail: video["thumbnailUrl"] as? String, uploaderName: video["uploader"] as? String,
                    uploaderUrl: video["uploaderUrl"] as? String, uploaderAvatar: video["uploaderAvatar"] as? String,
                    uploadedDate: video["uploadDate"] as? String, duration: number(video["duration"]).map { Int($0) }
                )
            }
            result.playlists.append(LocalPlaylist(name: info["name"] as? String ?? "Imported", videos: videos))
        }
        // Piped format: [{"name": "...", "videos": ["https://youtube.com/watch?v=…"]}]
        if (json["localPlaylists"] as? [Any] ?? []).isEmpty {
            for item in json["playlists"] as? [[String: Any]] ?? [] {
                let videos = (item["videos"] as? [String] ?? []).compactMap(videoId(from:)).map(streamItem)
                result.playlists.append(LocalPlaylist(name: item["name"] as? String ?? "Imported", videos: videos))
            }
        }
        return result
    }

    // MARK: FreeTube — profiles.db (one JSON object per line)

    static func freeTube(_ text: String) -> ImportResult? {
        var result = ImportResult(format: "FreeTube")
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let subs = object["subscriptions"] as? [[String: Any]] else { continue }
            for sub in subs {
                guard let id = sub["id"] as? String, seen.insert(id).inserted else { continue }
                result.subscriptions.append(Subscription(channelId: id, name: sub["name"] as? String,
                                                         avatar: sub["thumbnail"] as? String))
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: Google Takeout — subscriptions.csv ("Channel Id,Channel Url,Channel Title")

    static func takeoutCSV(_ text: String) -> ImportResult? {
        var result = ImportResult(format: "YouTube Takeout")
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard let id = columns.first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  id.count == 24, id.hasPrefix("UC") else { continue }
            let title = columns.count > 2 ? String(columns[2]).trimmingCharacters(in: .whitespaces) : nil
            result.subscriptions.append(Subscription(channelId: id, name: title))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: Plain list of URLs or IDs

    static func urlList(_ text: String, filename: String) -> ImportResult {
        var result = ImportResult(format: "URL list")
        var videos: [StreamItem] = []
        let tokens = text.split { $0.isNewline || $0 == "," || $0 == " " || $0 == "\t" }.map(String.init)
        for token in tokens {
            if token.contains("/channel/") || (token.count == 24 && token.hasPrefix("UC")) {
                if let sub = subscription(fromURL: token, name: nil) { result.subscriptions.append(sub) }
            } else if let id = videoId(from: token) {
                videos.append(streamItem(id))
            }
        }
        if !videos.isEmpty {
            let name = (filename as NSString).deletingPathExtension
            result.playlists = [LocalPlaylist(name: name.isEmpty ? "Imported" : name, videos: videos)]
        }
        return result
    }

    // MARK: Helpers

    static func subscription(fromURL url: String, name: String?) -> Subscription? {
        let id = url.channelIdFromURL
        guard id.count == 24, id.hasPrefix("UC") else { return nil }
        return Subscription(channelId: id, name: name)
    }

    static func videoId(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let host = components.host {
            if host.hasSuffix("youtu.be") { return String(components.path.dropFirst()).nilIfEmpty }
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            if let range = components.path.range(of: "/shorts/") { return String(components.path[range.upperBound...]).nilIfEmpty }
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return trimmed.count == 11 && trimmed.unicodeScalars.allSatisfy(allowed.contains) ? trimmed : nil
    }

    static func streamItem(_ id: String) -> StreamItem {
        StreamItem(url: "/watch?v=\(id)", thumbnail: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
