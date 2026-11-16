import Foundation

/// Writes the local library in formats `Importer` (and other apps) read back.
public enum Exporter {
    /// NewPipe's subscription export, which NewPipe, LibreTube, FreeTube, Piped and Mobius import.
    public static func newPipeSubscriptions(_ subscriptions: [Subscription]) throws -> Data {
        let json: [String: Any] = [
            "app_version": "0.27.0",
            "app_version_int": 1000,
            "subscriptions": subscriptions.filter { !$0.channelId.isEmpty }.map { sub in
                [
                    "service_id": 0,
                    "url": "https://www.youtube.com/channel/\(sub.channelId)",
                    "name": sub.name,
                ] as [String: Any]
            },
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Everything – subscriptions, playlists, history and resume positions – in LibreTube's backup
    /// format, so it restores in Mobius or LibreTube for Android.
    public static func backup(
        subscriptions: [Subscription], playlists: [LocalPlaylist], history: [WatchHistoryEntry]
    ) throws -> Data {
        let json: [String: Any] = [
            "format": "Mobius",
            "localSubscriptions": subscriptions.filter { !$0.channelId.isEmpty }.map { sub in
                compact([
                    "channelId": sub.channelId,
                    "url": "https://www.youtube.com/channel/\(sub.channelId)",
                    "name": sub.name,
                    "avatar": sub.avatar,
                    "verified": sub.verified,
                ])
            },
            "watchHistory": history.map { entry in
                compact([
                    "videoId": entry.videoId,
                    "title": entry.title,
                    "uploader": entry.uploader,
                    "uploaderUrl": entry.uploaderUrl,
                    "thumbnailUrl": entry.thumbnail,
                    "duration": entry.duration,
                    // Not in LibreTube's format; Importer uses it to keep the history order.
                    "watchedAt": Int(entry.watchedAt.timeIntervalSince1970 * 1000),
                ])
            },
            "watchPositions": history.filter { $0.position > 0 }.map { entry in
                ["videoId": entry.videoId, "position": Int(entry.position * 1000)] as [String: Any]
            },
            "localPlaylists": playlists.map { playlist in
                [
                    "playlist": compact(["name": playlist.name, "thumbnailUrl": playlist.thumbnailUrl]),
                    "videos": playlist.videos.filter { !$0.videoId.isEmpty }.map { video in
                        compact([
                            "videoId": video.videoId,
                            "title": video.title,
                            "thumbnailUrl": video.thumbnail,
                            "uploader": video.uploaderName,
                            "uploaderUrl": video.uploaderUrl,
                            "uploaderAvatar": video.uploaderAvatar,
                            "uploadDate": video.uploadedDate,
                            "duration": video.duration,
                        ])
                    },
                ] as [String: Any]
            },
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func compact(_ object: [String: Any?]) -> [String: Any] {
        object.compactMapValues { $0 }
    }
}
