import SwiftUI
import MobiusCore

extension View {
    /// Long-press menu for a video: add to a local playlist, share.
    func videoContextMenu(_ video: VideoInfo) -> some View {
        modifier(VideoContextMenu(video: video))
    }
}

private struct VideoContextMenu: ViewModifier {
    let video: VideoInfo
    @State private var showingPlaylistPicker = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    showingPlaylistPicker = true
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                if let url = video.shareURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                AddToPlaylistSheet(video: video)
            }
    }
}

/// Lets the user pick (or create) a local playlist to add a video to.
struct AddToPlaylistSheet: View {
    let video: VideoInfo
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Name", text: $newPlaylistName)
                            .onSubmit(createAndAdd)
                        Button("Create", action: createAndAdd)
                            .disabled(trimmedName.isEmpty)
                    }
                }
                Section("Playlists") {
                    if library.localPlaylists.isEmpty {
                        Text("No playlists yet").foregroundStyle(.secondary)
                    }
                    ForEach(library.localPlaylists) { playlist in
                        let contains = playlist.videos.contains { VideoInfo($0).videoId == video.videoId }
                        Button {
                            add(to: playlist.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(optional(playlist.name) ?? "")
                                    Text("\(playlist.videos.count) videos")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if contains {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(contains)
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmedName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createAndAdd() {
        guard !trimmedName.isEmpty else { return }
        let playlist = library.createPlaylist(name: trimmedName)
        add(to: playlist.id)
    }

    private func add(to playlistId: UUID) {
        if let item = video.streamItem {
            library.add(item, toPlaylist: playlistId)
        }
        dismiss()
    }
}

/// Subscribe / unsubscribe toggle bound to `LibraryStore`.
struct SubscribeButton: View {
    let channelId: String
    let name: String
    let avatar: String?
    var verified = false
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        let subscribed = library.isSubscribed(channelId: channelId)
        Button {
            if subscribed {
                library.unsubscribe(channelId: channelId)
            } else if let subscription = ModelFactory.subscription(
                channelId: channelId, name: name, avatar: avatar, verified: verified
            ) {
                library.subscribe(subscription)
            }
        } label: {
            Text(subscribed ? "Subscribed" : "Subscribe")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(subscribed ? Color.secondary : Color.brandAccent)
        .disabled(channelId.isEmpty)
    }
}
