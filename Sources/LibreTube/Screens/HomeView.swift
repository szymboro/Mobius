import SwiftUI
import LibreTubeCore

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var videos: [VideoInfo] = []
    @Published private(set) var phase: LoadPhase = .loading

    func load(content: HomeContent, channelIds: [String]) async {
        if videos.isEmpty { phase = .loading }
        let settings = AppSettings.shared
        do {
            let items: [StreamItem]
            switch content {
            case .trending:
                items = try await settings.api.trending(region: settings.region)
            case .subscriptions:
                items = try await settings.subscriptionFeed(channelIds: channelIds)
            }
            var videos = items.map { VideoInfo($0) }.uniqued()
            if content == .subscriptions {
                videos.sort { ($0.uploadedMillis ?? 0) > ($1.uploadedMillis ?? 0) }
            }
            self.videos = videos
            phase = .loaded
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Trending videos, or the latest videos from all subscriptions (Settings › Content › Home).
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = LibraryStore.shared

    private var channelIds: [String] { library.subscriptions.map(\.channelId) }

    var body: some View {
        PhaseView(phase: model.phase, retry: { await reload() }) {
            if model.videos.isEmpty {
                emptyState
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
                .refreshable { await reload() }
            }
        }
        .navigationTitle(settings.homeContent.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Home", selection: $settings.homeContent) {
                        ForEach(HomeContent.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        // Reload whenever what Home shows, the instance, region or subscriptions change.
        .task(id: reloadKey) { await reload() }
    }

    private var reloadKey: String {
        switch settings.homeContent {
        case .trending: "trending|\(settings.instanceURL.absoluteString)|\(settings.region)"
        case .subscriptions: "subs|\(settings.instanceURL.absoluteString)|\(channelIds.joined(separator: ","))"
        }
    }

    private func reload() async {
        await model.load(content: settings.homeContent, channelIds: channelIds)
    }

    @ViewBuilder private var emptyState: some View {
        switch settings.homeContent {
        case .trending:
            ContentUnavailableView("No Trending Videos", systemImage: "flame")
        case .subscriptions:
            ContentUnavailableView(
                "No Subscriptions",
                systemImage: "person.2",
                description: Text("Subscribe to channels, or import your subscriptions from NewPipe in Settings › Import.")
            )
        }
    }
}
