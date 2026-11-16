import SwiftUI
import MobiusCore

@MainActor
final class ChannelViewModel: ObservableObject {
    let channelId: String
    @Published private(set) var channel: Channel?
    @Published private(set) var videos: [VideoInfo] = []
    @Published private(set) var nextpage: String?
    @Published private(set) var phase: LoadPhase = .loading
    /// YouTube Music artist page, for "Artist - Topic" channels and others without videos.
    @Published private(set) var artist: MusicArtist?
    /// Playlists tab: nil until first requested.
    @Published private(set) var playlistsPhase: LoadPhase?
    @Published private(set) var playlists: [PlaylistSummary] = []
    @Published private(set) var playlistsContinuation: String?
    private var isLoadingMore = false

    init(channelId: String) {
        self.channelId = channelId
    }

    func load() async {
        if channel == nil, artist == nil { phase = .loading }
        do {
            let channel = try await fetchChannel()
            self.channel = channel
            videos = (optional(channel.relatedStreams) ?? []).map { VideoInfo($0) }.uniqued()
            nextpage = optional(channel.nextpage)
            if videos.isEmpty || (optional(channel.name) ?? "").hasSuffix(" - Topic") {
                artist = try? await YouTubeMusic.artist(channelId: optional(channel.id) ?? channelId)
            }
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            // Topic channels can fail as YouTube channels yet still be YouTube Music artists.
            if let artist = try? await YouTubeMusic.artist(channelId: channelId) {
                self.artist = artist
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func loadPlaylists() async {
        guard playlistsPhase == nil || playlistsPhase?.isFailed == true else { return }
        playlistsPhase = .loading
        do {
            let page = try await YouTubeInnerTube.channelPlaylists(id: optional(channel?.id) ?? channelId)
            playlists = page.items
            playlistsContinuation = page.continuation
            playlistsPhase = .loaded
        } catch {
            guard !isCancellation(error) else {
                playlistsPhase = nil
                return
            }
            playlistsPhase = .failed(error.localizedDescription)
        }
    }

    func loadMorePlaylists() async {
        guard let token = playlistsContinuation else { return }
        playlistsContinuation = nil
        do {
            let page = try await YouTubeInnerTube.channelPlaylistsNextPage(token: token)
            let known = Set(playlists.map(\.id))
            playlists += page.items.filter { !known.contains($0.id) }
            playlistsContinuation = page.continuation
        } catch {
            playlistsContinuation = token // retried when the sentinel reappears
        }
    }

    func loadMore() async {
        guard let page = nextpage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // Continuation tokens only work with the backend that issued them.
            let next = usesInnerTube
                ? try await YouTubeInnerTube.channelNextPage(id: channel?.id ?? channelId, nextpage: page)
                : try await AppSettings.shared.api.channelNextPage(id: channelId, nextpage: page)
            videos.appendUnique((optional(next.relatedStreams) ?? []).map { VideoInfo($0) })
            nextpage = optional(next.nextpage)
        } catch {
            // Keep the token; the sentinel retries when it reappears.
        }
    }

    /// Whether `channel` (and so `nextpage`) came from YouTube's InnerTube API rather than Piped.
    private var usesInnerTube = false

    /// On-device source: InnerTube first, Piped as fallback. Piped source: Piped first, InnerTube
    /// when Piped fails or returns no videos (decayed instances answer with an empty channel).
    private func fetchChannel() async throws -> Channel {
        let api = AppSettings.shared.api
        if AppSettings.shared.streamSource == .onDevice {
            do {
                let channel = try await YouTubeInnerTube.channel(id: channelId)
                usesInnerTube = true
                return channel
            } catch {
                if isCancellation(error) { throw error }
                let channel = try await api.channel(id: channelId)
                usesInnerTube = false
                return channel
            }
        }
        do {
            let channel = try await api.channel(id: channelId)
            if channel.relatedStreams.isEmpty,
               let fallback = try? await YouTubeInnerTube.channel(id: channelId), !fallback.relatedStreams.isEmpty {
                usesInnerTube = true
                return fallback
            }
            usesInnerTube = false
            return channel
        } catch {
            if isCancellation(error) { throw error }
            guard let fallback = try? await YouTubeInnerTube.channel(id: channelId) else { throw error }
            usesInnerTube = true
            return fallback
        }
    }
}

struct ChannelView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case videos = "Videos"
        case playlists = "Playlists"
        var id: Self { self }
    }

    @StateObject private var model: ChannelViewModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var descriptionExpanded = false
    @State private var pane: Pane = .videos

    init(channelId: String) {
        _model = StateObject(wrappedValue: ChannelViewModel(channelId: channelId))
    }

    var body: some View {
        PhaseView(phase: model.phase, retry: { [model] in await model.load() }) {
            if let artist = model.artist {
                ArtistPage(artist: artist, channelId: optional(model.channel?.id) ?? model.channelId,
                           avatar: model.channel.flatMap { optional($0.avatarUrl) })
                    .refreshable { await model.load() }
            } else if let channel = model.channel {
                List {
                    header(channel)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                    Picker("Section", selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    switch pane {
                    case .videos: videosSection
                    case .playlists: playlistsSection
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.load() }
            }
        }
        .navigationTitle(model.artist?.name ?? model.channel.flatMap { optional($0.name) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.channel == nil, model.artist == nil { await model.load() }
        }
        .onChange(of: pane) { _, pane in
            if pane == .playlists { Task { await model.loadPlaylists() } }
        }
    }

    @ViewBuilder
    private var videosSection: some View {
        if model.videos.isEmpty {
            Text("This channel has no videos.")
                .foregroundStyle(.secondary)
        }
        ForEach(model.videos.hidingShorts(in: .channels)) { video in
            NavigationLink(value: Route.video(video.videoId)) {
                VideoRow(video: video)
            }
        }
        LoadMoreView(token: model.nextpage) { [model] in await model.loadMore() }
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var playlistsSection: some View {
        switch model.playlistsPhase {
        case .loading, nil:
            ProgressView().frame(maxWidth: .infinity).padding()
                .listRowSeparator(.hidden)
        case .failed(let message):
            ErrorView(message: message, retry: { [model] in await model.loadPlaylists() })
                .frame(minHeight: 200)
                .listRowSeparator(.hidden)
        case .loaded:
            if model.playlists.isEmpty {
                Text("This channel has no public playlists.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.playlists) { playlist in
                NavigationLink(value: Route.playlist(playlist.id)) {
                    PlaylistRow(name: playlist.title, thumbnail: playlist.thumbnail, subtitle: playlist.videoCountText)
                }
            }
            LoadMoreView(token: model.playlistsContinuation) { [model] in await model.loadMorePlaylists() }
                .listRowSeparator(.hidden)
        }
    }

    private func header(_ channel: Channel) -> some View {
        let hasBanner = !(optional(channel.bannerUrl) ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            if hasBanner {
                Color.clear
                    .aspectRatio(4, contentMode: .fit)
                    .overlay { RemoteImage(url: optional(channel.bannerUrl)) }
                    .clipped()
            }
            HStack(alignment: hasBanner ? .bottom : .center, spacing: 12) {
                // With a banner, the avatar overlaps its bottom edge.
                Avatar(url: optional(channel.avatarUrl), size: 72)
                    .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 3) }
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .padding(.top, hasBanner ? -40 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(optional(channel.name) ?? "").font(.title3.bold()).lineLimit(2)
                        if optional(channel.verified) ?? false {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.secondary)
                        }
                    }
                    if let subscribers = intValue(channel.subscriberCount) {
                        Text("\(Formatters.compactCount(subscribers)) subscribers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                SubscribeButton(
                    channelId: model.channelId,
                    name: optional(channel.name) ?? "",
                    avatar: optional(channel.avatarUrl),
                    verified: optional(channel.verified) ?? false
                )
            }
            .padding(.horizontal)

            if let description = optional(channel.description), !description.isEmpty {
                Text(TextFormatting.plainText(fromHTML: description))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .padding(.horizontal)
                    .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
            }
        }
        .padding(.bottom, 8)
    }
}
