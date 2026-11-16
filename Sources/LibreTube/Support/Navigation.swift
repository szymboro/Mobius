import SwiftUI
import LibreTubeCore

/// Value-based navigation destinations shared by every tab's `NavigationStack`.
enum Route: Hashable {
    case video(String)
    case channel(String)
    case playlist(String)
    case localPlaylist(UUID)
    case history

    /// Maps a search / channel-tab result to its destination.
    init?(_ item: ContentItem) {
        let url = optional(item.url) ?? ""
        guard !url.isEmpty else { return nil }
        switch optional(item.type) ?? "stream" {
        case "channel": self = .channel(url.channelIdFromURL)
        case "playlist": self = .playlist(url.playlistIdFromURL)
        default: self = .video(url.videoIdFromURL)
        }
    }
}

private struct RouteDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .video:
                // Never pushed: RootView's path bindings hand videos to `NowPlaying`.
                EmptyView()
            case .channel(let id): ChannelView(channelId: id)
            case .playlist(let id): PlaylistView(playlistId: id)
            case .localPlaylist(let id): LocalPlaylistView(playlistId: id)
            case .history: HistoryView()
            }
        }
    }
}

extension View {
    func routeDestinations() -> some View {
        modifier(RouteDestinations())
    }
}
