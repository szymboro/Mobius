import Foundation

/// A search result / channel tab item. `type` is "stream", "channel" or "playlist".
/// Mirrors `api/obj/ContentItem.kt`.
public struct ContentItem: Codable, Hashable, Identifiable, Sendable {
    public var url: String
    public var type: String
    public var thumbnail: String
    // Video only attributes
    public var title: String?
    public var uploaderUrl: String?
    public var uploaderAvatar: String?
    /// Seconds, -1 if unknown.
    public var duration: Int
    public var views: Int
    public var isShort: Bool?
    public var uploaderVerified: Bool?
    public var uploaderName: String?
    /// Epoch milliseconds.
    public var uploaded: Int
    public var shortDescription: String?
    // Channel and Playlist attributes
    public var name: String?
    public var description: String?
    public var subscribers: Int
    public var videos: Int
    public var verified: Bool?

    public var id: String { url }

    public var isStream: Bool { type == StreamItem.typeStream }
    public var isChannel: Bool { type == StreamItem.typeChannel }
    public var isPlaylist: Bool { type == StreamItem.typePlaylist }

    /// Best display title regardless of type.
    public var displayTitle: String { title ?? name ?? "" }

    public var videoId: String { url.videoIdFromURL }
    public var channelId: String { url.channelIdFromURL }
    public var playlistId: String { url.playlistIdFromURL }

    public init(
        url: String,
        type: String,
        thumbnail: String = "",
        title: String? = nil,
        uploaderUrl: String? = nil,
        uploaderAvatar: String? = nil,
        duration: Int = -1,
        views: Int = -1,
        isShort: Bool? = nil,
        uploaderVerified: Bool? = nil,
        uploaderName: String? = nil,
        uploaded: Int = 0,
        shortDescription: String? = nil,
        name: String? = nil,
        description: String? = nil,
        subscribers: Int = -1,
        videos: Int = -1,
        verified: Bool? = nil
    ) {
        self.url = url
        self.type = type
        self.thumbnail = thumbnail
        self.title = title
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.duration = duration
        self.views = views
        self.isShort = isShort
        self.uploaderVerified = uploaderVerified
        self.uploaderName = uploaderName
        self.uploaded = uploaded
        self.shortDescription = shortDescription
        self.name = name
        self.description = description
        self.subscribers = subscribers
        self.videos = videos
        self.verified = verified
    }

    enum CodingKeys: String, CodingKey {
        case url, type, thumbnail, title, uploaderUrl, uploaderAvatar, duration, views, isShort,
             uploaderVerified, uploaderName, uploaded, shortDescription, name, description,
             subscribers, videos, verified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url, default: "")
        type = c.string(.type, default: StreamItem.typeStream)
        thumbnail = c.string(.thumbnail, default: "")
        title = c.string(.title)
        uploaderUrl = c.string(.uploaderUrl)
        uploaderAvatar = c.string(.uploaderAvatar)
        duration = c.int(.duration, default: -1)
        views = c.int(.views, default: -1)
        isShort = c.bool(.isShort)
        uploaderVerified = c.bool(.uploaderVerified)
        uploaderName = c.string(.uploaderName)
        uploaded = c.int(.uploaded, default: 0)
        shortDescription = c.string(.shortDescription)
        name = c.string(.name)
        description = c.string(.description)
        subscribers = c.int(.subscribers, default: -1)
        videos = c.int(.videos, default: -1)
        verified = c.bool(.verified)
    }

    public func toStreamItem() -> StreamItem {
        StreamItem(
            url: url,
            type: StreamItem.typeStream,
            title: title,
            thumbnail: thumbnail,
            uploaderName: uploaderName,
            uploaderUrl: uploaderUrl,
            uploaderAvatar: uploaderAvatar,
            duration: duration,
            views: views,
            uploaderVerified: uploaderVerified,
            uploaded: uploaded,
            shortDescription: shortDescription,
            isShort: isShort == true
        )
    }
}

/// Mirrors `api/obj/SearchResult.kt`.
public struct SearchResult: Codable, Hashable, Identifiable, Sendable {
    public var items: [ContentItem]
    public var nextpage: String?
    public var suggestion: String?
    public var corrected: Bool

    public var id: String { nextpage ?? "first" }

    public init(items: [ContentItem] = [], nextpage: String? = nil, suggestion: String? = nil, corrected: Bool = false) {
        self.items = items
        self.nextpage = nextpage
        self.suggestion = suggestion
        self.corrected = corrected
    }

    enum CodingKeys: String, CodingKey { case items, nextpage, suggestion, corrected }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.array(.items)
        nextpage = c.string(.nextpage)
        suggestion = c.string(.suggestion)
        corrected = c.bool(.corrected, default: false)
    }
}
