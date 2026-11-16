import Foundation

/// A video entry as returned by Piped lists (trending, feed, related streams, playlists...).
/// Mirrors `api/obj/StreamItem.kt`.
public struct StreamItem: Codable, Hashable, Identifiable, Sendable {
    public static let typeStream = "stream"
    public static let typeChannel = "channel"
    public static let typePlaylist = "playlist"

    public var url: String?
    public var type: String?
    public var title: String?
    public var thumbnail: String?
    public var uploaderName: String?
    public var uploaderUrl: String?
    public var uploaderAvatar: String?
    public var uploadedDate: String?
    /// Duration in seconds.
    public var duration: Int?
    public var views: Int?
    public var uploaderVerified: Bool?
    /// Upload time in epoch milliseconds (0 if unknown).
    public var uploaded: Int
    public var shortDescription: String?
    public var isShort: Bool

    /// The video id, derived from `url` ("/watch?v=ID").
    public var id: String { videoId }
    public var videoId: String { (url ?? "").videoIdFromURL }

    public var isLive: Bool { !isShort && (duration == nil || (duration ?? 0) <= 0) }
    public var isUpcoming: Bool { uploaded > Int(Date().timeIntervalSince1970 * 1000) }
    /// `uploaded` as a Date, nil when unknown.
    public var uploadedAt: Date? {
        uploaded > 0 ? Date(timeIntervalSince1970: TimeInterval(uploaded) / 1000) : nil
    }
    public var uploaderChannelId: String? { uploaderUrl?.channelIdFromURL }

    public init(
        url: String? = nil,
        type: String? = StreamItem.typeStream,
        title: String? = nil,
        thumbnail: String? = nil,
        uploaderName: String? = nil,
        uploaderUrl: String? = nil,
        uploaderAvatar: String? = nil,
        uploadedDate: String? = nil,
        duration: Int? = nil,
        views: Int? = nil,
        uploaderVerified: Bool? = nil,
        uploaded: Int = 0,
        shortDescription: String? = nil,
        isShort: Bool = false
    ) {
        self.url = url
        self.type = type
        self.title = title
        self.thumbnail = thumbnail
        self.uploaderName = uploaderName
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.uploadedDate = uploadedDate
        self.duration = duration
        self.views = views
        self.uploaderVerified = uploaderVerified
        self.uploaded = uploaded
        self.shortDescription = shortDescription
        self.isShort = isShort
    }

    enum CodingKeys: String, CodingKey {
        case url, type, title, thumbnail, uploaderName, uploaderUrl, uploaderAvatar,
             uploadedDate, duration, views, uploaderVerified, uploaded, shortDescription, isShort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url)
        type = c.string(.type)
        title = c.string(.title)
        thumbnail = c.string(.thumbnail)
        uploaderName = c.string(.uploaderName)
        uploaderUrl = c.string(.uploaderUrl)
        uploaderAvatar = c.string(.uploaderAvatar)
        uploadedDate = c.string(.uploadedDate)
        duration = c.int(.duration)
        views = c.int(.views)
        uploaderVerified = c.bool(.uploaderVerified)
        uploaded = c.int(.uploaded, default: 0)
        shortDescription = c.string(.shortDescription)
        isShort = c.bool(.isShort, default: false)
    }
}
