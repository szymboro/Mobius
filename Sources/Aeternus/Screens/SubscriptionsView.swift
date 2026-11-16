import SwiftUI
import AeternusCore

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var videos: [VideoInfo] = []
    @Published private(set) var phase: LoadPhase = .loading

    func load(channelIds: [String]) async {
        guard !channelIds.isEmpty else {
            videos = []
            phase = .loaded
            return
        }
        if videos.isEmpty { phase = .loading }
        do {
            let items = try await AppSettings.shared.subscriptionFeed(channelIds: channelIds)
            videos = items.map { VideoInfo($0) }
                .uniqued()
                .sorted { ($0.uploadedMillis ?? 0) > ($1.uploadedMillis ?? 0) }
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Feed of videos from subscribed channels, plus the list of channels.
struct SubscriptionsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case feed = "Feed"
        case channels = "Channels"
        var id: Self { self }
    }

    @StateObject private var model = FeedViewModel()
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var durations = VideoDurations.shared
    @State private var mode: Mode = .feed

    private var channelIds: [String] {
        library.subscriptions
            .map { (optional($0.url) ?? "").channelIdFromURL }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Group {
            if library.subscriptions.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "person.2",
                    description: Text("Subscribe to channels to see their latest videos here.")
                )
            } else {
                switch mode {
                case .feed: feed
                case .channels: channels
                }
            }
        }
        // Swap Feed/Channels instantly: animating between a ScrollView and a List made the bar
        // and content jump around.
        .animation(nil, value: mode)
        // The picker lives in a bar pinned above the content rather than in the navigation bar:
        // as a toolbar item, iOS rebuilt (and morphed) it whenever the content below switched
        // between the feed's ScrollView and the channels List.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !library.subscriptions.isEmpty {
                GlassSegmentedControl(options: Mode.allCases, selection: $mode, title: \.rawValue)
                    .padding(.vertical, 6)
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.fillMissingChannelInfo() }
        .task(id: "\(settings.instanceURL.absoluteString)|\(channelIds.joined(separator: ","))") {
            await model.load(channelIds: channelIds)
        }
    }

    private var feed: some View {
        let ids = channelIds
        let videos = model.videos.hidingShorts(in: .subscriptions)
        return PhaseView(phase: model.phase, retry: { [model] in await model.load(channelIds: ids) }) {
            if videos.isEmpty {
                ContentUnavailableView("No Videos", systemImage: "play.slash")
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(videos) { video in
                            NavigationLink(value: Route.video(video.videoId)) {
                                VideoCard(video: withAvatar(video))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .refreshable { await model.load(channelIds: ids) }
            }
        }
    }

    /// Avatars looked up after the feed loaded (see `fillMissingChannelInfo`) still show up.
    private func withAvatar(_ video: VideoInfo) -> VideoInfo {
        guard video.uploaderAvatar?.isEmpty ?? true, let id = video.channelId,
              let avatar = library.subscriptions.first(where: { $0.channelId == id })?.avatar else { return video }
        var video = video
        video.uploaderAvatar = avatar
        return video
    }

    private var channels: some View {
        List {
            // Identity by channel: avatars filled in later must update rows, not replace them.
            ForEach(library.subscriptions, id: \.channelId) { subscription in
                let channelId = (optional(subscription.url) ?? "").channelIdFromURL
                NavigationLink(value: Route.channel(channelId)) {
                    ChannelRow(
                        name: optional(subscription.name) ?? "",
                        avatar: optional(subscription.avatar),
                        verified: optional(subscription.verified) ?? false
                    )
                }
                .swipeActions {
                    Button("Unsubscribe", role: .destructive) {
                        library.unsubscribe(channelId: channelId)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}
