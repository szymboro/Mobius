import Foundation
import MobiusCore

/// UI-side, source-agnostic description of a video. Built from `StreamItem`,
/// `ContentItem` (search / channel results) and `WatchHistoryEntry` so the
/// same row views can render all of them.
struct VideoInfo: Hashable, Identifiable {
    var videoId: String
    var title: String
    var thumbnail: String?
    var uploaderName: String?
    var uploaderUrl: String?
    var uploaderAvatar: String?
    var uploaderVerified: Bool
    var duration: Int?
    var views: Int?
    var uploadedMillis: Int?
    var uploadedText: String?
    var isShort: Bool
    /// The original Core item, kept so it can be stored in local playlists unchanged.
    var source: StreamItem?

    var id: String { videoId }

    var channelId: String? {
        guard let url = uploaderUrl, !url.isEmpty else { return nil }
        let id = url.channelIdFromURL
        return id.isEmpty ? nil : id
    }

    /// `duration`, or the length looked up later for sources without one (see `VideoDurations`).
    @MainActor var knownDuration: Int? { duration ?? VideoDurations.shared.duration(for: videoId) }

    /// Live items carry a non-positive duration (-1); RSS items have none at all and aren't live.
    var isLive: Bool { !isShort && (duration.map { $0 <= 0 } ?? false) }

    var metadataLine: String {
        [TextFormatting.views(views), TextFormatting.relativeTime(millis: uploadedMillis, fallback: uploadedText)]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var shareURL: URL? { URL(string: "https://youtu.be/\(videoId)") }
}

extension VideoInfo {
    init(_ item: StreamItem) {
        self.init(
            videoId: (optional(item.url) ?? "").videoIdFromURL,
            title: optional(item.title) ?? "",
            thumbnail: optional(item.thumbnail),
            uploaderName: optional(item.uploaderName),
            uploaderUrl: optional(item.uploaderUrl),
            uploaderAvatar: optional(item.uploaderAvatar),
            uploaderVerified: optional(item.uploaderVerified) ?? false,
            duration: intValue(item.duration),
            views: intValue(item.views),
            uploadedMillis: intValue(item.uploaded),
            uploadedText: optional(item.uploadedDate),
            isShort: optional(item.isShort) ?? false,
            source: item
        )
    }

    /// Only `type == "stream"` content items describe videos.
    init?(_ item: ContentItem) {
        guard (optional(item.type) ?? "stream") == "stream" else { return nil }
        self.init(
            videoId: (optional(item.url) ?? "").videoIdFromURL,
            title: optional(item.title) ?? "",
            thumbnail: optional(item.thumbnail),
            uploaderName: optional(item.uploaderName),
            uploaderUrl: optional(item.uploaderUrl),
            uploaderAvatar: optional(item.uploaderAvatar),
            uploaderVerified: optional(item.uploaderVerified) ?? false,
            duration: intValue(item.duration),
            views: intValue(item.views),
            uploadedMillis: intValue(item.uploaded),
            uploadedText: nil,
            isShort: optional(item.isShort) ?? false,
            source: nil
        )
    }

    init(_ entry: WatchHistoryEntry) {
        self.init(
            videoId: optional(entry.videoId) ?? "",
            title: optional(entry.title) ?? "",
            thumbnail: optional(entry.thumbnail),
            uploaderName: optional(entry.uploader),
            uploaderUrl: optional(entry.uploaderUrl),
            uploaderAvatar: nil,
            uploaderVerified: false,
            duration: intValue(entry.duration),
            views: nil,
            uploadedMillis: nil,
            uploadedText: nil,
            isShort: false,
            source: nil
        )
    }

    init(videoId: String, streams: Streams) {
        self.init(
            videoId: videoId,
            title: optional(streams.title) ?? "",
            thumbnail: optional(streams.thumbnailUrl),
            uploaderName: optional(streams.uploader),
            uploaderUrl: optional(streams.uploaderUrl),
            uploaderAvatar: optional(streams.uploaderAvatar),
            uploaderVerified: optional(streams.uploaderVerified) ?? false,
            duration: intValue(streams.duration),
            views: intValue(streams.views),
            uploadedMillis: intValue(streams.uploaded),
            uploadedText: nil,
            isShort: false,
            source: nil
        )
    }

    /// A `StreamItem` suitable for storing in a local playlist.
    var streamItem: StreamItem? {
        source ?? ModelFactory.streamItem(from: self)
    }
}

/// Builds Core model values from the UI.
///
/// The contract does not specify public initialisers for Core models, but it
/// does guarantee they are `Codable` with the Kotlin/Piped JSON field names.
/// Decoding from a JSON object therefore works whatever Swift types Core
/// picked for each field (Int vs Int64, optional vs not).
enum ModelFactory {
    static func streamItem(from video: VideoInfo) -> StreamItem? {
        decode([
            "url": "/watch?v=\(video.videoId)",
            "type": "stream",
            "title": video.title,
            "thumbnail": video.thumbnail ?? "",
            "uploaderName": video.uploaderName ?? "",
            "uploaderUrl": video.uploaderUrl ?? "",
            "uploaderAvatar": video.uploaderAvatar,
            "uploadedDate": video.uploadedText,
            "duration": video.duration ?? 0,
            "views": video.views ?? 0,
            "uploaderVerified": video.uploaderVerified,
            "uploaded": video.uploadedMillis ?? 0,
            "isShort": video.isShort,
        ])
    }

    static func subscription(channelId: String, name: String, avatar: String?, verified: Bool) -> ChannelSubscription? {
        decode([
            "url": "/channel/\(channelId)",
            "name": name,
            "avatar": avatar ?? "",
            "verified": verified,
        ])
    }

    static func historyEntry(for video: VideoInfo, position: Double) -> WatchHistoryEntry? {
        decode([
            "id": video.videoId,
            "videoId": video.videoId,
            "title": video.title,
            "uploader": video.uploaderName ?? "",
            "uploaderUrl": video.uploaderUrl ?? "",
            "thumbnail": video.thumbnail ?? "",
            "duration": video.duration ?? 0,
            // Default `JSONDecoder` date strategy: seconds since the reference date.
            "watchedAt": Date().timeIntervalSinceReferenceDate,
            "position": position,
        ])
    }

    private static func decode<T: Decodable>(_ object: [String: Any?]) -> T? {
        let json = object.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Shorts filter

@MainActor
extension VideoInfo {
    /// The title to show: DeArrow's replacement when that's on and one exists.
    var displayTitle: String { DeArrow.shared.title(for: videoId) ?? title }

    /// Counts as a Short under the current settings (marked as one, or short enough).
    var countsAsShort: Bool { AppSettings.shared.isShort(isShort: isShort, duration: knownDuration) }
}

@MainActor
extension Array where Element == VideoInfo {
    /// Drops Shorts when Settings › Shorts hides them on this screen.
    func hidingShorts(in place: ShortsPlace) -> [VideoInfo] {
        AppSettings.shared.hidesShorts(in: place) ? filter { !$0.countsAsShort } : self
    }
}

@MainActor
extension Array where Element == ContentItem {
    /// Drops Shorts (videos only; channels and playlists stay) when hidden on this screen.
    func hidingShorts(in place: ShortsPlace) -> [ContentItem] {
        let settings = AppSettings.shared
        guard settings.hidesShorts(in: place) else { return self }
        return filter { item in
            !(item.isStream && settings.isShort(isShort: item.isShort == true, duration: item.duration))
        }
    }
}
