import SwiftUI
import LibreTubeCore

/// Remote content for the Home sections. Library-backed sections (Continue Watching,
/// Playlists) read `LibraryStore` directly and need no loading.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var featured: [VideoInfo] = []
    @Published private(set) var featuredPhase: LoadPhase = .loading
    @Published private(set) var liveNow: [VideoInfo] = []
    @Published private(set) var liveNowPhase: LoadPhase = .loading

    func load(sections: [HomeSection], channelIds: [String]) async {
        async let featured: Void = sections.contains(.featured) ? loadFeatured(channelIds: channelIds) : ()
        async let live: Void = sections.contains(.liveNow) ? loadLiveNow() : ()
        _ = await (featured, live)
    }

    private func loadFeatured(channelIds: [String]) async {
        guard !channelIds.isEmpty else {
            featured = []
            featuredPhase = .loaded
            return
        }
        if featured.isEmpty { featuredPhase = .loading }
        do {
            let items = try await AppSettings.shared.subscriptionFeed(channelIds: channelIds)
            featured = items.map { VideoInfo($0) }
                .filter { !$0.isShort }
                .uniqued()
                .sorted { ($0.uploadedMillis ?? 0) > ($1.uploadedMillis ?? 0) }
            featuredPhase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            featuredPhase = .failed(error.localizedDescription)
        }
    }

    private func loadLiveNow() async {
        if liveNow.isEmpty { liveNowPhase = .loading }
        let settings = AppSettings.shared
        do {
            liveNow = try await settings.api.trending(region: settings.region).map { VideoInfo($0) }.uniqued()
            liveNowPhase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            liveNowPhase = .failed(error.localizedDescription)
        }
    }
}

/// LibreTube-style home: horizontal carousels for Featured (subscriptions), Continue Watching,
/// Live Now and Playlists. Sections are chosen in Settings › Content › Home Sections.
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var durations = VideoDurations.shared
    @ObservedObject private var library = LibraryStore.shared

    private var channelIds: [String] { library.subscriptions.map(\.channelId) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(settings.homeSections) { section in
                    sectionView(section)
                }
                if settings.homeSections.isEmpty {
                    ContentUnavailableView(
                        "Nothing on Home", systemImage: "house",
                        description: Text("Turn on sections in Settings › Content › Home Sections.")
                    )
                    .padding(.top, 80)
                }
            }
            .padding(.vertical)
        }
        .refreshable { await reload() }
        .navigationTitle("Home")
        // Reload when the sections, instance, region or subscriptions change.
        .task(id: reloadKey) { await reload() }
    }

    private var reloadKey: String {
        [settings.homeSections.map(\.rawValue).joined(separator: ","), settings.instanceURL.absoluteString,
         settings.region, channelIds.joined(separator: ",")].joined(separator: "|")
    }

    private func reload() async {
        await model.load(sections: settings.homeSections, channelIds: channelIds)
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: HomeSection) -> some View {
        switch section {
        case .featured: featuredSection
        case .continueWatching: continueWatchingSection
        case .liveNow: liveNowSection
        case .playlists: playlistsSection
        }
    }

    @ViewBuilder
    private var featuredSection: some View {
        HomeSectionView(title: HomeSection.featured.title, seeAll: library.subscriptions.isEmpty ? nil : .subscriptionFeed) {
            if library.subscriptions.isEmpty {
                SectionMessage(
                    systemImage: "person.2",
                    text: "Subscribe to channels, or import your subscriptions from NewPipe in Settings › Import."
                )
            } else {
                RemoteCarousel(phase: model.featuredPhase, videos: Array(model.featured.hidingShorts(in: .home).prefix(20)),
                               emptyText: "No recent videos from your subscriptions.") { await reload() }
            }
        }
    }

    @ViewBuilder
    private var continueWatchingSection: some View {
        let entries = library.history
            .filter { $0.position > 5 && ($0.duration <= 0 || $0.position < Double($0.duration) - 10) }
            .prefix(15)
        if !entries.isEmpty {
            HomeSectionView(title: HomeSection.continueWatching.title, seeAll: .history) {
                Carousel {
                    ForEach(Array(entries), id: \.videoId) { entry in
                        let video = VideoInfo(entry)
                        NavigationLink(value: Route.video(video.videoId)) {
                            CarouselVideoCard(video: video, progress: entry.duration > 0 ? entry.position / Double(entry.duration) : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var liveNowSection: some View {
        HomeSectionView(title: HomeSection.liveNow.title, seeAll: model.liveNow.isEmpty ? nil : .liveNow) {
            RemoteCarousel(phase: model.liveNowPhase, videos: Array(model.liveNow.prefix(15)),
                           emptyText: "No live streams right now.") { await reload() }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        if !library.localPlaylists.isEmpty {
            HomeSectionView(title: HomeSection.playlists.title, seeAll: .localPlaylists) {
                Carousel {
                    ForEach(library.localPlaylists) { playlist in
                        NavigationLink(value: Route.localPlaylist(playlist.id)) {
                            CarouselPlaylistCard(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

/// Section title with an optional "See All" link, followed by its content.
private struct HomeSectionView<Content: View>: View {
    let title: String
    let seeAll: Route?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.bold))
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("See All").font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(.horizontal)
            content()
        }
    }
}

private struct Carousel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
                .padding(.horizontal)
        }
        .scrollClipDisabled()
    }
}

/// A carousel of remote videos with loading / error / empty states.
private struct RemoteCarousel: View {
    let phase: LoadPhase
    let videos: [VideoInfo]
    let emptyText: String
    let retry: @MainActor @Sendable () async -> Void

    var body: some View {
        switch phase {
        case .loading where videos.isEmpty:
            Carousel {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(width: CarouselVideoCard.width, height: CarouselVideoCard.width * 9 / 16)
                }
            }
        case .failed(let message) where videos.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { Task { await retry() } }.font(.subheadline)
            }
            .padding(.horizontal)
        default:
            if videos.isEmpty {
                SectionMessage(systemImage: "tray", text: emptyText)
            } else {
                Carousel {
                    ForEach(videos) { video in
                        NavigationLink(value: Route.video(video.videoId)) {
                            CarouselVideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct SectionMessage: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }
}

private struct CarouselVideoCard: View {
    static let width: CGFloat = 250
    let video: VideoInfo
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoThumbnail(video: video, progress: progress)
            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text([video.uploaderName, video.metadataLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .videoContextMenu(video)
    }
}

private struct CarouselPlaylistCard: View {
    let playlist: LocalPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: playlist.videos.first.flatMap { optional($0.thumbnail) }) }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Label("\(playlist.videos.count)", systemImage: "list.bullet")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(6)
                }
            Text(playlist.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
    }
}

// MARK: - "See All" destinations

/// Full vertical list for a Home section.
struct VideoListView: View {
    enum Source { case subscriptions, liveNow }

    let title: String
    let source: Source
    @StateObject private var model = HomeViewModel()
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var durations = VideoDurations.shared

    var body: some View {
        let phase = source == .subscriptions ? model.featuredPhase : model.liveNowPhase
        let videos = source == .subscriptions ? model.featured.hidingShorts(in: .home) : model.liveNow
        PhaseView(phase: phase, retry: { await load() }) {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(videos) { video in
                        NavigationLink(value: Route.video(video.videoId)) {
                            VideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .refreshable { await load() }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        await model.load(sections: [source == .subscriptions ? .featured : .liveNow],
                         channelIds: library.subscriptions.map(\.channelId))
    }
}

/// All local playlists.
struct LocalPlaylistsView: View {
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        List(library.localPlaylists) { playlist in
            NavigationLink(value: Route.localPlaylist(playlist.id)) {
                PlaylistRow(
                    name: playlist.name,
                    thumbnail: playlist.videos.first.flatMap { optional($0.thumbnail) },
                    videoCount: playlist.videos.count
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
    }
}
