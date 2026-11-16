import SwiftUI
import LibreTubeCore

@MainActor
final class PlaylistViewModel: ObservableObject {
    let playlistId: String
    @Published private(set) var playlist: Playlist?
    @Published private(set) var videos: [VideoInfo] = []
    @Published private(set) var nextpage: String?
    @Published private(set) var phase: LoadPhase = .loading
    @Published private(set) var isSaving = false
    private var isLoadingMore = false

    init(playlistId: String) {
        self.playlistId = playlistId
    }

    func load() async {
        if playlist == nil { phase = .loading }
        do {
            let playlist = try await AppSettings.shared.api.playlist(id: playlistId)
            self.playlist = playlist
            videos = (optional(playlist.relatedStreams) ?? []).map { VideoInfo($0) }.uniqued()
            nextpage = optional(playlist.nextpage)
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let page = nextpage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await AppSettings.shared.api.playlistNextPage(id: playlistId, nextpage: page)
            videos.appendUnique((optional(next.relatedStreams) ?? []).map { VideoInfo($0) })
            nextpage = optional(next.nextpage)
        } catch {
            // Keep the token; the sentinel retries when it reappears.
        }
    }

    /// Copies the playlist (fetching all remaining pages) into a new local playlist.
    func saveToLibrary() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var pagesLeft = 50
        while nextpage != nil, pagesLeft > 0 {
            let before = nextpage
            await loadMore()
            if nextpage == before { break } // request failed
            pagesLeft -= 1
        }
        let library = LibraryStore.shared
        let local = library.createPlaylist(name: optional(playlist?.name) ?? "Playlist")
        for video in videos {
            if let item = video.streamItem {
                library.add(item, toPlaylist: local.id)
            }
        }
    }
}

struct PlaylistView: View {
    @StateObject private var model: PlaylistViewModel
    @State private var savedMessage = false

    init(playlistId: String) {
        _model = StateObject(wrappedValue: PlaylistViewModel(playlistId: playlistId))
    }

    var body: some View {
        PhaseView(phase: model.phase, retry: { [model] in await model.load() }) {
            if let playlist = model.playlist {
                List {
                    header(playlist)
                        .listRowSeparator(.hidden)
                    channelLink(playlist)
                    ForEach(model.videos) { video in
                        NavigationLink(value: Route.video(video.videoId)) {
                            VideoRow(video: video)
                        }
                    }
                    LoadMoreView(token: model.nextpage) { [model] in await model.loadMore() }
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { await model.load() }
            }
        }
        .navigationTitle(model.playlist.flatMap { optional($0.name) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.playlist != nil {
                Button {
                    Task {
                        await model.saveToLibrary()
                        savedMessage = true
                    }
                } label: {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Label("Save to Library", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(model.isSaving)
            }
        }
        .alert("Saved to Library", isPresented: $savedMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The playlist was copied to your local playlists.")
        }
        .task {
            if model.playlist == nil { await model.load() }
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: optional(playlist.thumbnailUrl)) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(optional(playlist.name) ?? "")
                .font(.title3.bold())
            let details = [
                optional(playlist.uploader),
                intValue(playlist.videos).map { "\($0) videos" },
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func channelLink(_ playlist: Playlist) -> some View {
        if let uploaderUrl = optional(playlist.uploaderUrl), !uploaderUrl.isEmpty {
            NavigationLink(value: Route.channel(uploaderUrl.channelIdFromURL)) {
                ChannelRow(
                    name: optional(playlist.uploader) ?? "Channel",
                    avatar: nil
                )
            }
        }
    }
}
