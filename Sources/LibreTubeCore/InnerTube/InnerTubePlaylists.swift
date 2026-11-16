import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A playlist tile from a channel's Playlists tab.
public struct PlaylistSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnail: String?
    /// e.g. "24 videos".
    public var videoCountText: String?
}

public struct PlaylistSummaryPage: Sendable {
    public var items: [PlaylistSummary]
    public var continuation: String?
}

extension YouTubeInnerTube {
    /// Channel "Playlists" tab.
    static let playlistsTabParams = "EglwbGF5bGlzdHPyBgQKAkIA"

    /// A playlist's first page (also albums "OLAK5uy_…" and YouTube Music mixes "RDCLAK…").
    public static func playlist(id: String, session: URLSession = .shared) async throws -> Playlist {
        let json = try await post("browse", ["browseId": "VL\(id)"], session: session)
        let root = JNode(json)
        let header = root["header", "playlistHeaderRenderer"]
        let pageHeader = root["header"].first("pageHeaderViewModel")
        let name = header["title"].text ?? pageHeader["title"].text
            ?? root["metadata", "playlistMetadataRenderer", "title"].string
        let ownerBrowseId = header["ownerText"].first("browseEndpoint")["browseId"].string
        let (items, continuation) = InnerTubeItems.collect(root["contents"])
        guard name != nil || !items.isEmpty else { throw ExtractorError.malformedResponse }
        return Playlist(
            name: name,
            description: header["descriptionText"].text,
            thumbnailUrl: InnerTubeText.bestImage(header.first("thumbnails")) ?? items.first?.thumbnail,
            nextpage: continuation,
            uploader: header["ownerText"].text,
            uploaderUrl: ownerBrowseId.map { "/channel/\($0)" },
            videos: InnerTubeText.count(header["numVideosText"].text) ?? items.count,
            relatedStreams: items
        )
    }

    public static func playlistNextPage(nextpage: String, session: URLSession = .shared) async throws -> Playlist {
        let json = try await post("browse", ["continuation": nextpage], session: session)
        let (items, continuation) = InnerTubeItems.collect(JNode(json))
        return Playlist(nextpage: continuation, relatedStreams: items)
    }

    /// The channel's own playlists (Playlists tab). Empty when the channel hides the tab.
    public static func channelPlaylists(id: String, session: URLSession = .shared) async throws -> PlaylistSummaryPage {
        let browseId = try await resolveChannelId(id, session: session)
        let json = try await post("browse", ["browseId": browseId, "params": playlistsTabParams], session: session)
        let root = JNode(json)
        // Without a Playlists tab YouTube answers with the Home tab; don't show its contents.
        let tabs = root["contents", "twoColumnBrowseResultsRenderer", "tabs"].array
        let selected = tabs.first { $0["tabRenderer", "selected"].bool == true }?["tabRenderer"]
        guard let selected, selected["title"].string == "Playlists"
                || (selected["endpoint", "browseEndpoint", "params"].string ?? "").hasPrefix("EglwbGF5bGlzdH")
        else { return PlaylistSummaryPage(items: [], continuation: nil) }
        return parsePlaylists(selected["content"])
    }

    public static func channelPlaylistsNextPage(token: String, session: URLSession = .shared) async throws -> PlaylistSummaryPage {
        let json = try await post("browse", ["continuation": token], session: session)
        return parsePlaylists(JNode(json))
    }

    static func parsePlaylists(_ node: JNode) -> PlaylistSummaryPage {
        var seen = Set<String>()
        var items: [PlaylistSummary] = []
        for lockup in node.all("lockupViewModel") {
            let type = lockup["contentType"].string ?? ""
            guard type == "LOCKUP_CONTENT_TYPE_PLAYLIST" || type == "LOCKUP_CONTENT_TYPE_SHOW" || type == "LOCKUP_CONTENT_TYPE_PODCAST",
                  let id = lockup["contentId"].string, seen.insert(id).inserted,
                  let title = lockup["metadata", "lockupMetadataViewModel", "title"].text else { continue }
            let image = lockup["contentImage"]
            let thumbnail = InnerTubeText.bestImage(image.first("primaryThumbnail").first("image"))
                ?? InnerTubeText.bestImage(image.first("image"))
            let count = image.all("thumbnailBadgeViewModel").compactMap { $0["text"].string }
                .first { $0.lowercased().contains("video") || $0.lowercased().contains("episode") }
            items.append(PlaylistSummary(id: id, title: title, thumbnail: thumbnail, videoCountText: count))
        }
        let continuation = node.all("continuationItemRenderer").lazy.compactMap(InnerTubeItems.token).first
        return PlaylistSummaryPage(items: items, continuation: continuation)
    }
}
