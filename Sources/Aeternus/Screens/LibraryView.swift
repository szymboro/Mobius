import SwiftUI
import AeternusCore

/// Local playlists and watch history.
struct LibraryView: View {
    @ObservedObject private var library = LibraryStore.shared
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.history) {
                    Label("Watch History", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Recently Watched") {
                if library.history.isEmpty {
                    Text("Videos you watch will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recentHistory, id: \.self) { entry in
                    HistoryRow(entry: entry)
                }
            }

            Section("Playlists") {
                if library.localPlaylists.isEmpty {
                    Text("No playlists yet. Long-press a video to add it to a playlist.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.localPlaylists) { playlist in
                    NavigationLink(value: Route.localPlaylist(playlist.id)) {
                        PlaylistRow(
                            name: optional(playlist.name) ?? "",
                            thumbnail: playlist.videos.first.flatMap { VideoInfo($0).thumbnail },
                            videoCount: playlist.videos.count
                        )
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { library.localPlaylists[$0].id }
                    for id in ids { library.deletePlaylist(id: id) }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button {
                newPlaylistName = ""
                showingNewPlaylist = true
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
        }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { _ = library.createPlaylist(name: name) }
            }
        }
    }

    private var recentHistory: [WatchHistoryEntry] {
        Array(sortedHistory(library.history).prefix(5))
    }
}

func sortedHistory(_ history: [WatchHistoryEntry]) -> [WatchHistoryEntry] {
    history.sorted { $0.watchedAt > $1.watchedAt }
}

private struct HistoryRow: View {
    let entry: WatchHistoryEntry

    var body: some View {
        let video = VideoInfo(entry)
        NavigationLink(value: Route.video(video.videoId)) {
            VideoRow(video: video, progress: progress(for: video))
        }
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) {
                LibraryStore.shared.removeFromHistory(videoId: entry.videoId)
            }
        }
    }

    private func progress(for video: VideoInfo) -> Double? {
        guard let duration = video.duration, duration > 0 else { return nil }
        return entry.position / Double(duration)
    }
}

/// Full watch history with a clear action.
struct HistoryView: View {
    @ObservedObject private var library = LibraryStore.shared
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if library.history.isEmpty {
                ContentUnavailableView("No Watch History", systemImage: "clock")
            } else {
                List(sortedHistory(library.history), id: \.self) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Watch History")
        .toolbar {
            Button("Clear", role: .destructive) { confirmingClear = true }
                .disabled(library.history.isEmpty)
        }
        .confirmationDialog("Clear watch history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        }
    }
}

/// Contents of a local playlist.
struct LocalPlaylistView: View {
    let playlistId: UUID
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        if let playlist = library.localPlaylists.first(where: { $0.id == playlistId }) {
            Group {
                if playlist.videos.isEmpty {
                    ContentUnavailableView(
                        "Empty Playlist",
                        systemImage: "music.note.list",
                        description: Text("Long-press a video and choose \u{201C}Add to Playlist\u{201D}.")
                    )
                } else {
                    List {
                        ForEach(playlist.videos.map { VideoInfo($0) }) { video in
                            NavigationLink(value: Route.video(video.videoId)) {
                                VideoRow(video: video)
                            }
                        }
                        .onDelete { offsets in
                            let videoIds = offsets.map { VideoInfo(playlist.videos[$0]).videoId }
                            for videoId in videoIds {
                                library.remove(videoId: videoId, fromPlaylist: playlistId)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(optional(playlist.name) ?? "Playlist")
        } else {
            ContentUnavailableView("Playlist Not Found", systemImage: "questionmark.folder")
        }
    }
}
