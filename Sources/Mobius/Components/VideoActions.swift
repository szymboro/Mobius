import SwiftUI
import MobiusCore

extension View {
    /// Long-press menu for a video: queue, add to a local playlist, share.
    func videoContextMenu(_ video: VideoInfo) -> some View {
        modifier(VideoContextMenu(video: video))
    }
}

private struct VideoContextMenu: ViewModifier {
    let video: VideoInfo
    @State private var showingPlaylistPicker = false
    @ObservedObject private var nowPlaying = NowPlaying.shared

    func body(content: Content) -> some View {
        content
            .contextMenu {
                queueActions
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

    /// "Add to Queue" always; "Play Next" (top of the queue) once the queue has something in it.
    /// With nothing playing, adding starts the video in the mini player.
    @ViewBuilder
    private var queueActions: some View {
        let isCurrent = nowPlaying.model.map { $0.videoId == video.videoId && !$0.isClosed } ?? false
        if !isCurrent {
            if nowPlaying.isQueued(video.videoId) {
                if nowPlaying.queue.first?.videoId != video.videoId {
                    Button {
                        nowPlaying.enqueue(video, next: true)
                    } label: {
                        Label("Move to Top of Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button(role: .destructive) {
                    nowPlaying.removeFromQueue(video.videoId)
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            } else {
                if !nowPlaying.queue.isEmpty {
                    Button {
                        nowPlaying.enqueue(video, next: true)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button {
                    nowPlaying.enqueue(video)
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
            Divider()
        }
    }
}

/// The play queue: tap to play now, swipe right to remove, drag to reorder.
struct QueueSheet: View {
    @ObservedObject private var nowPlaying = NowPlaying.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if nowPlaying.queue.isEmpty {
                    ContentUnavailableView(
                        "Queue Is Empty",
                        systemImage: "list.bullet",
                        description: Text("Touch and hold a video and choose Add to Queue.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(nowPlaying.queue) { video in
                                Button {
                                    nowPlaying.open(videoId: video.videoId)
                                    dismiss()
                                } label: {
                                    QueueRow(video: video)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { nowPlaying.removeFromQueue(video.videoId) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                            .onMove { nowPlaying.moveQueue(fromOffsets: $0, toOffset: $1) }
                        } footer: {
                            Text("Swipe right to remove. Touch and hold to reorder.")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !nowPlaying.queue.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) {
                            withAnimation { nowPlaying.clearQueue() }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A smaller `VideoRow` without its context menu (queue rows have their own actions).
private struct QueueRow: View {
    let video: VideoInfo
    @ObservedObject private var deArrow = DeArrow.shared

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(video: video)
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let uploader = video.uploaderName, !uploader.isEmpty {
                    Text(uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
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
