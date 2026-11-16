import SwiftUI
import LibreTubeCore

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
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .task(id: "\(settings.instanceURL.absoluteString)|\(channelIds.joined(separator: ","))") {
            await model.load(channelIds: channelIds)
        }
    }

    private var feed: some View {
        let ids = channelIds
        return PhaseView(phase: model.phase, retry: { [model] in await model.load(channelIds: ids) }) {
            if model.videos.isEmpty {
                ContentUnavailableView("No Videos", systemImage: "play.slash")
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(model.videos) { video in
                            NavigationLink(value: Route.video(video.videoId)) {
                                VideoCard(video: video)
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

    private var channels: some View {
        List {
            ForEach(library.subscriptions, id: \.self) { subscription in
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
