import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Subscription feed built from YouTube's public per-channel RSS feeds
/// (`/feeds/videos.xml?channel_id=`). Used when the Piped feed endpoint fails.
/// RSS has no durations; `VideoDurations` looks them up afterwards.
public enum YouTubeRSS {
    public static func feed(channelIds: [String], session: URLSession = .shared) async -> [StreamItem] {
        await withTaskGroup(of: [StreamItem].self) { group in
            var pending = channelIds.makeIterator()
            var running = 0
            // Keep at most 8 requests in flight.
            while running < 8, let id = pending.next() {
                group.addTask { await channel(id, session: session) }
                running += 1
            }
            var items: [StreamItem] = []
            while let batch = await group.next() {
                items.append(contentsOf: batch)
                if let id = pending.next() { group.addTask { await channel(id, session: session) } }
            }
            return items.sorted { $0.uploaded > $1.uploaded }
        }
    }

    static func channel(_ id: String, session: URLSession) async -> [StreamItem] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [StreamItem] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var items: [StreamItem] = []
        private var channelName: String?
        private var channelId: String?
        private var entry: [String: String]?
        private var text = ""
        private let iso = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "entry": entry = [:]
            case "media:thumbnail": entry?["thumbnail"] = attributes["url"]
            case "media:statistics": entry?["views"] = attributes["views"]
            case "link": if entry != nil { entry?["link"] = attributes["href"] }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry == nil {
                if name == "yt:channelId" { channelId = value }
                if name == "title", channelName == nil { channelName = value }
            } else if name == "entry", let e = entry, let videoId = e["yt:videoId"] {
                let date = e["published"].flatMap(iso.date(from:))
                items.append(StreamItem(
                    url: "/watch?v=\(videoId)", title: e["title"],
                    thumbnail: e["thumbnail"] ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                    uploaderName: e["name"] ?? channelName,
                    uploaderUrl: (e["yt:channelId"] ?? channelId).map { "/channel/\($0)" },
                    views: e["views"].flatMap { Int($0) },
                    uploaded: date.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
                    isShort: e["link"]?.contains("/shorts/") ?? false
                ))
                entry = nil
            } else if ["yt:videoId", "title", "published", "name", "yt:channelId"].contains(name) {
                entry?[name] = value
            }
            text = ""
        }
    }
}
