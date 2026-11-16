import LibreTubeCore
import SwiftUI

/// The player screen's content: video surface, details, related videos and comments. Shown inside
/// `ExpandedPlayer`; the model (and playback) is owned by `NowPlaying`, not by this view.
struct PlayerView: View {
    @ObservedObject var model: PlayerViewModel
    /// Drag-down-to-minimize offset shared with `ExpandedPlayer`.
    var dragOffset: Binding<CGFloat>?
    @State private var tab: PlayerViewModel.Tab = .related
    @State private var descriptionExpanded = false
    @State private var showingAddToPlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            PhaseView(phase: model.phase, retry: { [model] in await model.load() }) {
                if let streams = model.streams, let video = model.video {
                    details(streams: streams, video: video)
                }
            }
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            if let video = model.video {
                AddToPlaylistSheet(video: video)
            }
        }
    }

    // MARK: Player

    private var playerArea: some View {
        ZStack {
            Color.black
            if let player = model.player {
                PlayerController(player: player, model: model)
            } else if let error = model.playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            } else if model.phase == .loading {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .simultaneousGesture(dragOffset.map { MinimizeDrag.gesture(offset: $0) })
        .overlay(alignment: .topLeading) {
            if let notice = model.skipNotice {
                Text(notice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.skipNotice)
    }

    // MARK: Details

    private func details(streams: Streams, video: VideoInfo) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                titleSection(streams: streams, video: video)
                actions(video: video)
                uploaderSection(streams: streams, video: video)
                descriptionSection(streams: streams)
                chaptersSection(streams: streams)

                Picker("Section", selection: $tab) {
                    ForEach(PlayerViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .related: relatedSection
                case .comments: CommentsSection(model: model)
                }
            }
            .padding()
        }
    }

    private func titleSection(streams: Streams, video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(video.title)
                .font(.title3.bold())
                .textSelection(.enabled)
            HStack(spacing: 12) {
                if let views = video.views {
                    Label(Formatters.compactCount(views), systemImage: "eye")
                }
                if let likes = intValue(streams.likes), likes > 0 {
                    Label(Formatters.compactCount(likes), systemImage: "hand.thumbsup")
                }
                if let uploaded = TextFormatting.relativeTime(millis: video.uploadedMillis, fallback: nil) {
                    Label(uploaded, systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func actions(video: VideoInfo) -> some View {
        HStack(spacing: 12) {
            Button {
                showingAddToPlaylist = true
            } label: {
                Label("Save", systemImage: "text.badge.plus")
            }
            if let url = video.shareURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            QualityMenu(model: model)
        }
        .buttonStyle(.bordered)
        .font(.subheadline)
    }

    private func uploaderSection(streams: Streams, video: VideoInfo) -> some View {
        HStack(spacing: 12) {
            if let channelId = video.channelId {
                // The player isn't in a tab's NavigationStack: minimize and push on the selected tab.
                Button {
                    NowPlaying.shared.show(.channel(channelId))
                } label: {
                    uploaderLabel(streams: streams, video: video)
                }
                .buttonStyle(.plain)
            } else {
                uploaderLabel(streams: streams, video: video)
            }
            Spacer(minLength: 0)
            SubscribeButton(
                channelId: video.channelId ?? "",
                name: video.uploaderName ?? "",
                avatar: video.uploaderAvatar,
                verified: video.uploaderVerified
            )
        }
    }

    private func uploaderLabel(streams: Streams, video: VideoInfo) -> some View {
        HStack(spacing: 10) {
            Avatar(url: video.uploaderAvatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(video.uploaderName ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if video.uploaderVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subscribers = intValue(streams.uploaderSubscriberCount), subscribers > 0 {
                    Text("\(Formatters.compactCount(subscribers)) subscribers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func descriptionSection(streams: Streams) -> some View {
        let description = TextFormatting.plainText(fromHTML: optional(streams.description) ?? "")
        if !description.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(description)
                    .font(.footnote)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .textSelection(.enabled)
                Button(descriptionExpanded ? "Show less" : "Show more") {
                    withAnimation { descriptionExpanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func chaptersSection(streams: Streams) -> some View {
        let chapters = optional(streams.chapters) ?? []
        if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chapters").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(chapters) { chapter in
                            let start = intValue(chapter.start) ?? 0
                            Button {
                                model.seek(to: Double(start))
                                model.player?.play()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Color.clear
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .overlay { RemoteImage(url: optional(chapter.image)) }
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(optional(chapter.title) ?? "")
                                        .font(.caption.weight(.medium))
                                        .lineLimit(2)
                                    Text(Formatters.duration(start))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if model.related.isEmpty {
            Text("No related videos.")
                .foregroundStyle(.secondary)
        }
        ForEach(model.related) { video in
            // Replaces the current video in place (NowPlaying tears the old one down).
            Button {
                NowPlaying.shared.open(videoId: video.videoId)
            } label: {
                VideoRow(video: video)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Comments are loaded lazily, the first time this section appears.
private struct CommentsSection: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        Group {
            switch model.commentsPhase {
            case .loading, nil:
                ProgressView().frame(maxWidth: .infinity).padding()
            case .failed(let message):
                ErrorView(message: message, retry: { [model] in await model.reloadComments() })
                    .frame(minHeight: 240)
            case .loaded:
                if model.commentsDisabled {
                    ContentUnavailableView("Comments Are Turned Off", systemImage: "text.bubble")
                } else if model.comments.isEmpty {
                    ContentUnavailableView("No Comments", systemImage: "text.bubble")
                } else {
                    ForEach(model.comments) { comment in
                        CommentRow(comment: comment)
                        Divider()
                    }
                    LoadMoreView(token: model.commentsNextPage) { [model] in await model.loadMoreComments() }
                }
            }
        }
        .task { await model.loadComments() }
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: optional(comment.thumbnail), size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(optional(comment.author) ?? "")
                        .font(.caption.weight(.semibold))
                    if optional(comment.verified) ?? false {
                        Image(systemName: "checkmark.seal.fill").imageScale(.small)
                    }
                    if optional(comment.pinned) ?? false {
                        Image(systemName: "pin.fill").imageScale(.small)
                    }
                    Text(optional(comment.commentedTime) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(TextFormatting.plainText(fromHTML: optional(comment.commentText) ?? ""))
                    .font(.subheadline)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    if let likes = intValue(comment.likeCount), likes > 0 {
                        Label(Formatters.compactCount(likes), systemImage: "hand.thumbsup")
                    }
                    if optional(comment.hearted) ?? false {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                    }
                    if let replies = intValue(comment.replyCount), replies > 0 {
                        Text("\(replies) replies")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shows `PlaybackLog` so playback problems can be copied and reported.
struct PlaybackLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = PlaybackLog.shared.text
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Nothing logged yet." : text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { proxy.scrollTo("end") }
            }
            .navigationTitle("Playback Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { text = PlaybackLog.shared.text } label: { Image(systemName: "arrow.clockwise") }
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
            }
        }
    }
}
