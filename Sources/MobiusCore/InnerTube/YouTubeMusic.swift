import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An artist page from YouTube Music. Auto-generated "Artist - Topic" channels have no videos on
/// YouTube itself; their songs, albums and singles only show up here (same channel id).
public struct MusicArtist: Sendable, Hashable {
    public var name: String
    /// Wide header artwork.
    public var thumbnail: String?
    public var description: String?
    /// e.g. "23.5M monthly audience".
    public var audience: String?
    public var topSongs: [MusicTrack]
    /// The full "Top songs" list, as a YouTube playlist id.
    public var topSongsPlaylistId: String?
    /// Albums, Singles & EPs, Videos, Featured on, Playlists, Fans might also like…
    public var shelves: [MusicShelf]
}

public struct MusicTrack: Sendable, Hashable, Identifiable {
    public var videoId: String
    public var title: String
    public var artists: String?
    public var album: String?
    /// e.g. "298M plays".
    public var plays: String?
    public var thumbnail: String?
    public var id: String { videoId }
}

public struct MusicShelf: Sendable, Hashable, Identifiable {
    public var title: String
    public var items: [MusicItem]
    public var id: String { title }
}

public struct MusicItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Albums are plain YouTube playlists ("OLAK5uy_…").
        case album(playlistId: String)
        case playlist(String)
        case video(String)
        case artist(channelId: String)
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var thumbnail: String?

    public var id: String {
        switch kind {
        case .album(let id), .playlist(let id), .video(let id), .artist(let id): id
        }
    }

    /// Square artwork (albums, playlists, artists) rather than a 16:9 video thumbnail.
    public var isSquare: Bool {
        if case .video = kind { return false }
        return true
    }
}

public enum YouTubeMusic {
    static let clientVersion = "1.20251015.03.00"

    /// The YouTube Music artist page for `channelId`, or nil when it isn't an artist.
    public static func artist(channelId: String, session: URLSession = .shared) async throws -> MusicArtist? {
        let json = try await post("browse", ["browseId": channelId], session: session)
        return parseArtist(JNode(json))
    }

    static func post(_ endpoint: String, _ body: [String: Any], session: URLSession) async throws -> [String: Any] {
        var payload = body
        payload["context"] = ["client": [
            "clientName": "WEB_REMIX",
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": Locale.current.region?.identifier ?? "US",
        ]]
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeInnerTube.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        let data = try await PipedAPI.performRequest(request, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.malformedResponse
        }
        return json
    }

    // MARK: Parsing

    static func parseArtist(_ root: JNode) -> MusicArtist? {
        let header = root["header", "musicImmersiveHeaderRenderer"].exists
            ? root["header", "musicImmersiveHeaderRenderer"]
            : root["header", "musicVisualHeaderRenderer"]
        guard let name = header["title"].text, !name.isEmpty else { return nil }

        var artist = MusicArtist(
            name: name,
            thumbnail: InnerTubeText.bestImage(header["thumbnail", "musicThumbnailRenderer", "thumbnail"])
                ?? InnerTubeText.bestImage(header["foregroundThumbnail", "musicThumbnailRenderer", "thumbnail"]),
            description: header["description"].text,
            audience: header["monthlyListenerCount"].text,
            topSongs: [], topSongsPlaylistId: nil, shelves: []
        )

        let tab = root["contents", "singleColumnBrowseResultsRenderer", "tabs"].array.first
        for section in tab?["tabRenderer", "content", "sectionListRenderer", "contents"].array ?? [] {
            if section["musicShelfRenderer"].exists {
                let shelf = section["musicShelfRenderer"]
                artist.topSongs = shelf["contents"].array.compactMap { track($0["musicResponsiveListItemRenderer"]) }
                let browseId = shelf["bottomEndpoint", "browseEndpoint", "browseId"].string
                    ?? shelf["title"].first("browseEndpoint")["browseId"].string
                artist.topSongsPlaylistId = browseId.map(playlistId(fromBrowseId:))
            } else if section["musicCarouselShelfRenderer"].exists {
                let shelf = section["musicCarouselShelfRenderer"]
                let title = shelf["header", "musicCarouselShelfBasicHeaderRenderer", "title"].text ?? ""
                let items = shelf["contents"].array.compactMap { item($0["musicTwoRowItemRenderer"]) }
                if !title.isEmpty, !items.isEmpty { artist.shelves.append(MusicShelf(title: title, items: items)) }
            } else if section["musicDescriptionShelfRenderer"].exists, artist.description == nil {
                artist.description = section["musicDescriptionShelfRenderer", "description"].text
            }
        }
        guard !artist.topSongs.isEmpty || !artist.shelves.isEmpty else { return nil }
        return artist
    }

    /// A "Top songs" row: title, artists, plays, album in the flex columns.
    static func track(_ node: JNode) -> MusicTrack? {
        guard node.exists else { return nil }
        let columns = node["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer", "text"] }
        guard let videoId = node["playlistItemData", "videoId"].string ?? node.first("watchEndpoint")["videoId"].string,
              let title = columns.first?.text else { return nil }
        func column(_ index: Int) -> String? {
            index < columns.count ? columns[index].text?.nilIfBlank : nil
        }
        return MusicTrack(
            videoId: videoId, title: title, artists: column(1), album: column(3), plays: column(2),
            thumbnail: InnerTubeText.bestImage(node["thumbnail", "musicThumbnailRenderer", "thumbnail"])
        )
    }

    /// A carousel tile: album, single, playlist, video or related artist.
    static func item(_ node: JNode) -> MusicItem? {
        guard node.exists, let title = node["title"].text else { return nil }
        let nav = node["navigationEndpoint"]
        let kind: MusicItem.Kind
        if let videoId = nav["watchEndpoint", "videoId"].string {
            kind = .video(videoId)
        } else if let browseId = nav["browseEndpoint", "browseId"].string {
            switch nav["browseEndpoint"].first("pageType").string ?? "" {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
                kind = .artist(channelId: browseId)
            case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
                // Album pages ("MPREb_…") are Music-only; the play button names its YouTube playlist.
                guard let id = node.first("watchPlaylistEndpoint")["playlistId"].string else { return nil }
                kind = .album(playlistId: id)
            case "MUSIC_PAGE_TYPE_PLAYLIST":
                kind = .playlist(playlistId(fromBrowseId: browseId))
            default:
                return nil
            }
        } else {
            return nil
        }
        return MusicItem(
            kind: kind, title: title, subtitle: node["subtitle"].text?.nilIfBlank,
            thumbnail: InnerTubeText.bestImage(node["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail"])
        )
    }

    /// Playlist browse ids carry a "VL" prefix.
    static func playlistId(fromBrowseId id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
