# LibreTube iOS — module contract

Two SwiftPM targets. `LibreTubeCore` (no UI imports; Foundation only) and
`LibreTube` (SwiftUI app, depends on Core). Swift 6 language mode, iOS 17+.
All Core types listed below are `public`, `Sendable`, and models are `Codable, Hashable, Identifiable`.
No third-party dependencies.

The iOS port talks ONLY to the Piped API (no NewPipeExtractor on iOS).
Reference Kotlin sources: app/src/main/java/com/github/libretube/api/ (obj/, MediaServiceRepository.kt, PipedMediaServiceRepository/RetrofitInstance).

## Core: models (mirror app/.../api/obj/*.kt field names for JSON)
- `StreamItem` (id = videoId derived from `url` "/watch?v=ID")
- `Streams` (+ `PipedStream`, `Subtitle`, `ChapterSegment`, `MetaInfo`)
- `ContentItem` (search/channel tab items; `type`: "stream"|"channel"|"playlist")
- `SearchResult` { items: [ContentItem], nextpage: String? }
- `Channel` { id, name, avatarUrl, bannerUrl, description, subscriberCount, verified, relatedStreams: [StreamItem], nextpage: String?, tabs: [ChannelTab] }
- `Playlist` { name, thumbnailUrl, uploader, uploaderUrl, videos, relatedStreams: [StreamItem], nextpage: String? }
- `CommentsPage` { comments: [Comment], nextpage: String?, disabled: Bool }
- `Segment` (SponsorBlock) { category, segment: [Double] }
- `PipedInstance` { name, apiUrl, locations, cdn, ... }
- `Subscription` (local) { url, name, avatar, verified }  — channelId derived from url
- `WatchHistoryEntry` (local) { videoId, title, uploader, uploaderUrl, thumbnail, duration, watchedAt: Date, position: Double }

## Core: services
```swift
public actor PipedAPI {
    public init(baseURL: URL, session: URLSession = .shared)
    public func trending(region: String) async throws -> [StreamItem]
    public func streams(videoId: String) async throws -> Streams
    public func search(query: String, filter: String) async throws -> SearchResult   // filter: "all","videos","channels","playlists"
    public func searchNextPage(query: String, filter: String, nextpage: String) async throws -> SearchResult
    public func suggestions(query: String) async throws -> [String]
    public func channel(id: String) async throws -> Channel
    public func channelNextPage(id: String, nextpage: String) async throws -> Channel
    public func playlist(id: String) async throws -> Playlist
    public func playlistNextPage(id: String, nextpage: String) async throws -> Playlist
    public func comments(videoId: String) async throws -> CommentsPage
    public func commentsNextPage(videoId: String, nextpage: String) async throws -> CommentsPage
    public func feed(channelIds: [String]) async throws -> [StreamItem]   // POST /feed/unauthenticated
    public func sponsorSegments(videoId: String, categories: [String]) async throws -> [Segment]
    public static func instances() async throws -> [PipedInstance]      // https://piped-instances.kavin.rocks/
}

public enum PipedError: Error, Sendable { case http(Int, String?), decoding(String), invalidURL }

// Local persistence: JSON files in Application Support.
@MainActor public final class LibraryStore: ObservableObject {
    public static let shared: LibraryStore
    @Published public private(set) var subscriptions: [Subscription]
    @Published public private(set) var history: [WatchHistoryEntry]
    @Published public private(set) var localPlaylists: [LocalPlaylist]   // LocalPlaylist { id: UUID, name, videos: [StreamItem] }
    public func isSubscribed(channelId: String) -> Bool
    public func subscribe(_ s: Subscription); public func unsubscribe(channelId: String)
    public func recordWatch(_ e: WatchHistoryEntry); public func clearHistory()
    public func createPlaylist(name: String) -> LocalPlaylist; public func deletePlaylist(id: UUID)
    public func add(_ item: StreamItem, toPlaylist id: UUID); public func remove(videoId: String, fromPlaylist id: UUID)
}

@MainActor public final class Settings: ObservableObject {
    public static let shared: Settings
    @Published public var instanceURL: URL        // default https://api.piped.private.coffee
    @Published public var region: String          // default "US"
    @Published public var sponsorBlockEnabled: Bool
    @Published public var sponsorBlockCategories: Set<String>
    @Published public var preferredQuality: String // "auto", "1080p", ...
    public var api: PipedAPI { get }               // rebuilt when instanceURL changes
}

public extension String { var videoIdFromURL: String { get }; var channelIdFromURL: String { get }; var playlistIdFromURL: String { get } }
public enum Formatters { static func duration(_ seconds: Int) -> String; static func compactCount(_ n: Int) -> String }
```
Settings/LibraryStore use Combine/Foundation only (ObservableObject is in Combine — import Combine is fine).
