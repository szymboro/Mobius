import Foundation
#if canImport(Combine)
import Combine
#endif

/// User preferences, persisted to `UserDefaults`.
@MainActor
public final class Settings: ObservableObject {
    public static let shared = Settings()

    public static let defaultSponsorBlockCategories: Set<String> = ["sponsor"]
    /// All SponsorBlock categories, in display order.
    public static let allSponsorBlockCategories: [String] = [
        "sponsor", "selfpromo", "interaction", "intro", "outro", "preview",
        "music_offtopic", "filler",
    ]
    public static let qualityOptions: [String] = ["auto", "2160p", "1440p", "1080p", "720p", "480p", "360p", "240p", "144p"]

    private enum Key {
        static let instanceURL = "instanceURL"
        static let region = "region"
        static let sponsorBlockEnabled = "sponsorBlockEnabled"
        static let sponsorBlockCategories = "sponsorBlockCategories"
        static let preferredQuality = "preferredQuality"
        static let streamSource = "streamSource"
        static let homeSections = "homeSections"
    }

    private let defaults: UserDefaults

    @Published public var instanceURL: URL {
        didSet {
            defaults.set(instanceURL.absoluteString, forKey: Key.instanceURL)
            if oldValue != instanceURL {
                api = PipedAPI(baseURL: instanceURL)
            }
        }
    }

    @Published public var region: String {
        didSet { defaults.set(region, forKey: Key.region) }
    }

    @Published public var sponsorBlockEnabled: Bool {
        didSet { defaults.set(sponsorBlockEnabled, forKey: Key.sponsorBlockEnabled) }
    }

    @Published public var sponsorBlockCategories: Set<String> {
        didSet { defaults.set(sponsorBlockCategories.sorted(), forKey: Key.sponsorBlockCategories) }
    }

    @Published public var preferredQuality: String {
        didSet { defaults.set(preferredQuality, forKey: Key.preferredQuality) }
    }

    /// Where video streams come from. Lists, search, channels and comments always use Piped.
    @Published public var streamSource: StreamSource {
        didSet { defaults.set(streamSource.rawValue, forKey: Key.streamSource) }
    }

    /// Resolves playable streams for a video from the selected `streamSource`.
    public func streams(videoId: String) async throws -> Streams {
        switch streamSource {
        case .onDevice: try await YouTubeExtractor.streams(videoId: videoId)
        case .piped: try await api.streams(videoId: videoId)
        }
    }

    /// Sections shown on the Home tab, in order (like LibreTube Android's home).
    @Published public var homeSections: [HomeSection] {
        didSet { defaults.set(homeSections.map(\.rawValue), forKey: Key.homeSections) }
    }

    public func isHomeSectionEnabled(_ section: HomeSection) -> Bool { homeSections.contains(section) }

    public func setHomeSection(_ section: HomeSection, enabled: Bool) {
        if enabled {
            guard !homeSections.contains(section) else { return }
            // Keep the canonical order.
            homeSections = HomeSection.allCases.filter { $0 == section || homeSections.contains($0) }
        } else {
            homeSections.removeAll { $0 == section }
        }
    }

    /// Latest videos from the given channels. Piped's feed endpoint and YouTube's per-channel RSS
    /// feeds are fetched together and merged: unauthenticated Piped feeds are often stale for
    /// channels nobody on the instance follows, while RSS is always current but lacks durations.
    /// Missing avatars are filled in from the stored subscriptions.
    public func subscriptionFeed(channelIds: [String]) async throws -> [StreamItem] {
        guard !channelIds.isEmpty else { return [] }
        let api = self.api
        async let pipedResult: Result<[StreamItem], Error> = {
            do { return .success(try await api.feed(channelIds: channelIds)) } catch { return .failure(error) }
        }()
        async let rssItems = YouTubeRSS.feed(channelIds: channelIds)
        let (piped, rss) = await (pipedResult, rssItems)
        try Task.checkCancellation()

        var merged: [String: StreamItem] = [:]
        for item in rss where !item.videoId.isEmpty { merged[item.videoId] = item }
        if case .success(let items) = piped {
            for var item in items where !item.videoId.isEmpty {
                if let fresh = merged[item.videoId] {
                    // RSS has the exact publish time and view count; Piped has duration and avatar.
                    if fresh.uploaded > 0 { item.uploaded = fresh.uploaded }
                    if let views = fresh.views, views > (item.views ?? 0) { item.views = views }
                    item.isShort = item.isShort || fresh.isShort
                }
                merged[item.videoId] = item
            }
        } else if case .failure(let error) = piped, merged.isEmpty {
            throw error
        }

        let subscriptions = Dictionary(
            LibraryStore.shared.subscriptions.map { ($0.channelId, $0) }, uniquingKeysWith: { a, _ in a }
        )
        return merged.values.map { item in
            var item = item
            if let channelId = item.uploaderChannelId, let sub = subscriptions[channelId] {
                if item.uploaderAvatar?.isEmpty ?? true { item.uploaderAvatar = sub.avatar }
                if item.uploaderVerified == nil { item.uploaderVerified = sub.verified }
            }
            return item
        }
        .sorted { $0.uploaded > $1.uploaded }
    }

    /// API client for the current instance; rebuilt whenever `instanceURL` changes.
    public private(set) var api: PipedAPI

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let url = defaults.string(forKey: Key.instanceURL).flatMap(URL.init(string:)) ?? PipedAPI.defaultInstanceURL
        instanceURL = url
        region = defaults.string(forKey: Key.region) ?? "US"
        sponsorBlockEnabled = defaults.object(forKey: Key.sponsorBlockEnabled) as? Bool ?? true
        if let stored = defaults.stringArray(forKey: Key.sponsorBlockCategories) {
            sponsorBlockCategories = Set(stored)
        } else {
            sponsorBlockCategories = Settings.defaultSponsorBlockCategories
        }
        preferredQuality = defaults.string(forKey: Key.preferredQuality) ?? "auto"
        streamSource = defaults.string(forKey: Key.streamSource).flatMap(StreamSource.init(rawValue:)) ?? .onDevice
        homeSections = defaults.stringArray(forKey: Key.homeSections)?.compactMap(HomeSection.init(rawValue:))
            ?? HomeSection.allCases
        api = PipedAPI(baseURL: url)
    }

    /// Categories to request from SponsorBlock, or empty when disabled.
    public var activeSponsorBlockCategories: [String] {
        sponsorBlockEnabled ? sponsorBlockCategories.sorted() : []
    }

    /// Restores all defaults.
    public func reset() {
        instanceURL = PipedAPI.defaultInstanceURL
        region = "US"
        sponsorBlockEnabled = true
        sponsorBlockCategories = Settings.defaultSponsorBlockCategories
        preferredQuality = "auto"
        streamSource = .onDevice
        homeSections = HomeSection.allCases
    }
}

public enum HomeSection: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Latest videos from subscribed channels.
    case featured
    /// Partly watched videos from history.
    case continueWatching
    /// YouTube's former Trending list; YouTube now only offers live streams there.
    case liveNow
    /// Local playlists.
    case playlists

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .featured: "Featured"
        case .continueWatching: "Continue Watching"
        case .liveNow: "Live Now"
        case .playlists: "Playlists"
        }
    }
}
