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
        static let autoplay = "autoplay"
        static let audioOnly = "audioOnly"
        static let hideShorts = "hideShorts"
        static let shortsMaxDuration = "shortsMaxDuration"
        static let hideShortsIn = "hideShortsIn"
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

    /// Play the next related video when one ends.
    @Published public var autoplay: Bool {
        didSet { defaults.set(autoplay, forKey: Key.autoplay) }
    }

    /// Show the thumbnail instead of the video and stream the lowest video quality (e.g. music).
    @Published public var audioOnly: Bool {
        didSet { defaults.set(audioOnly, forKey: Key.audioOnly) }
    }

    /// Hide Shorts (in the places chosen in `hideShortsIn`).
    @Published public var hideShorts: Bool {
        didSet { defaults.set(hideShorts, forKey: Key.hideShorts) }
    }

    /// Videos up to this many seconds also count as Shorts; 0 = only videos YouTube marks as Shorts.
    @Published public var shortsMaxDuration: Int {
        didSet { defaults.set(shortsMaxDuration, forKey: Key.shortsMaxDuration) }
    }

    /// Where Shorts are hidden when `hideShorts` is on.
    @Published public var hideShortsIn: Set<ShortsPlace> {
        didSet { defaults.set(hideShortsIn.map(\.rawValue).sorted(), forKey: Key.hideShortsIn) }
    }

    /// Choices for `shortsMaxDuration`, in seconds.
    public static let shortsDurationOptions: [Int] = [0, 60, 90, 120, 180, 240, 300]

    /// Whether a video counts as a Short: marked as one, or (optionally) no longer than
    /// `shortsMaxDuration`. Live streams and items without a duration are never caught by length.
    public func isShort(isShort: Bool, duration: Int?) -> Bool {
        if isShort { return true }
        guard shortsMaxDuration > 0, let duration, duration > 0 else { return false }
        return duration <= shortsMaxDuration
    }

    /// Whether Shorts should be filtered out of the given screen.
    public func hidesShorts(in place: ShortsPlace) -> Bool {
        hideShorts && hideShortsIn.contains(place)
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

    /// Latest videos from the given channels (see `SubscriptionFeed` for the sources).
    /// Missing avatars are filled in from the stored subscriptions.
    public func subscriptionFeed(channelIds: [String]) async throws -> [StreamItem] {
        guard !channelIds.isEmpty else { return [] }
        let merged = try await SubscriptionFeed.load(channelIds: channelIds, api: api)

        let subscriptions = Dictionary(
            LibraryStore.shared.subscriptions.map { ($0.channelId, $0) }, uniquingKeysWith: { a, _ in a }
        )
        let durations = VideoDurations.shared
        durations.record(merged)
        let items = durations.applying(to: merged)
        // RSS has no lengths: look them up in the background; thumbnails update as they arrive.
        Task { await durations.fill(items) }
        return items.map { item in
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
        autoplay = defaults.object(forKey: Key.autoplay) as? Bool ?? true
        audioOnly = defaults.bool(forKey: Key.audioOnly)
        hideShorts = defaults.bool(forKey: Key.hideShorts)
        shortsMaxDuration = defaults.object(forKey: Key.shortsMaxDuration) as? Int ?? 0
        hideShortsIn = defaults.stringArray(forKey: Key.hideShortsIn)
            .map { Set($0.compactMap(ShortsPlace.init(rawValue:))) } ?? Set(ShortsPlace.allCases)
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
        autoplay = true
        audioOnly = false
        hideShorts = false
        shortsMaxDuration = 0
        hideShortsIn = Set(ShortsPlace.allCases)
    }
}

/// Screens Shorts can be hidden from.
public enum ShortsPlace: String, CaseIterable, Codable, Sendable, Identifiable {
    case home
    case subscriptions
    case search
    case channels
    case related

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .search: "Search"
        case .channels: "Channels"
        case .related: "Related Videos & Autoplay"
        }
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
