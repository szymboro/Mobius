import Foundation

/// A locally stored channel subscription. Mirrors `api/obj/Subscription.kt`.
public struct Subscription: Codable, Hashable, Identifiable, Sendable {
    /// Channel url, usually "/channel/ID".
    public var url: String
    public var name: String
    public var avatar: String?
    public var verified: Bool

    public var id: String { channelId }
    public var channelId: String { url.channelIdFromURL }

    /// Accepts optional values for convenience; `url` may be a full url, "/channel/ID" or a bare id.
    public init(url: String, name: String? = nil, avatar: String? = nil, verified: Bool? = false) {
        self.url = url.hasPrefix("UC") && !url.contains("/") ? "/channel/\(url)" : url
        self.name = name ?? ""
        self.avatar = avatar
        self.verified = verified ?? false
    }

    public init(channelId: String, name: String? = nil, avatar: String? = nil, verified: Bool? = false) {
        self.init(url: "/channel/\(channelId)", name: name, avatar: avatar, verified: verified)
    }

    enum CodingKeys: String, CodingKey { case url, name, avatar, verified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url, default: "")
        name = c.string(.name, default: "")
        avatar = c.string(.avatar)
        verified = c.bool(.verified, default: false)
    }
}

/// A locally stored watch history entry.
public struct WatchHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var videoId: String
    public var title: String
    public var uploader: String
    public var uploaderUrl: String?
    public var thumbnail: String?
    /// Video duration in seconds (0 if unknown).
    public var duration: Int
    public var watchedAt: Date
    /// Playback position in seconds.
    public var position: Double

    public var id: String { videoId }

    /// Fraction watched in 0...1 (0 when duration unknown).
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / Double(duration), 0), 1)
    }

    public init(
        videoId: String,
        title: String? = nil,
        uploader: String? = nil,
        uploaderUrl: String? = nil,
        thumbnail: String? = nil,
        duration: Int? = nil,
        watchedAt: Date = Date(),
        position: Double = 0
    ) {
        self.videoId = videoId
        self.title = title ?? ""
        self.uploader = uploader ?? ""
        self.uploaderUrl = uploaderUrl
        self.thumbnail = thumbnail
        self.duration = duration ?? 0
        self.watchedAt = watchedAt
        self.position = position
    }

    public init(item: StreamItem, watchedAt: Date = Date(), position: Double = 0) {
        self.init(
            videoId: item.videoId, title: item.title, uploader: item.uploaderName,
            uploaderUrl: item.uploaderUrl, thumbnail: item.thumbnail, duration: item.duration,
            watchedAt: watchedAt, position: position
        )
    }

    public init(videoId: String, streams: Streams, watchedAt: Date = Date(), position: Double = 0) {
        self.init(
            videoId: videoId, title: streams.title, uploader: streams.uploader,
            uploaderUrl: streams.uploaderUrl, thumbnail: streams.thumbnailUrl,
            duration: streams.duration, watchedAt: watchedAt, position: position
        )
    }

    /// Converts back to a list item (for playback / display in lists).
    public func toStreamItem() -> StreamItem {
        StreamItem(
            url: "/watch?v=\(videoId)", type: StreamItem.typeStream, title: title,
            thumbnail: thumbnail, uploaderName: uploader, uploaderUrl: uploaderUrl,
            duration: duration
        )
    }

    enum CodingKeys: String, CodingKey {
        case videoId, title, uploader, uploaderUrl, thumbnail, duration, watchedAt, position
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = c.string(.videoId, default: "")
        title = c.string(.title, default: "")
        uploader = c.string(.uploader, default: "")
        uploaderUrl = c.string(.uploaderUrl)
        thumbnail = c.string(.thumbnail)
        duration = c.int(.duration, default: 0)
        watchedAt = c.object(.watchedAt, as: Date.self) ?? Date(timeIntervalSince1970: 0)
        position = c.double(.position, default: 0)
    }
}

/// A playlist stored on the device.
public struct LocalPlaylist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var videos: [StreamItem]

    public var thumbnailUrl: String? { videos.first?.thumbnail }

    public init(id: UUID = UUID(), name: String, videos: [StreamItem] = []) {
        self.id = id
        self.name = name
        self.videos = videos
    }

    enum CodingKeys: String, CodingKey { case id, name, videos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.object(.id, as: UUID.self) ?? UUID()
        name = c.string(.name, default: "")
        videos = c.array(.videos)
    }
}
