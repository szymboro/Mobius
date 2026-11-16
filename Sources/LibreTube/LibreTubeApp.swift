import AVFoundation
import LibreTubeCore
import SwiftUI

@main
struct LibreTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Keep audio playing with the silent switch on, in the background and in PiP.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // SABR playback needs BotGuard PO tokens (WKWebView) and YouTube's player JS (JavaScriptCore).
        YouTubeExtractor.poTokenProvider = BotGuardPoTokenProvider()
        YouTubeExtractor.playerScriptRunner = JSCPlayerScriptRunner()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

extension Color {
    /// LibreTube's accent, from the brand gradient (#FF6B8B → #FFB088).
    static let brandAccent = Color(red: 1.0, green: 0x5C / 255, blue: 0x7A / 255)
}

struct RootView: View {
    fileprivate enum RootTab: Hashable {
        case home, subscriptions, library, search, settings
    }

    @State private var selection: RootTab = .home
    /// One navigation path per tab, so `.video` pushes can be intercepted (see `path(for:)`).
    @State private var paths: [RootTab: [Route]] = [:]
    @ObservedObject private var nowPlaying = NowPlaying.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            tabs
            ExpandedPlayerHost()
        }
        .tint(.brandAccent)
        .onChange(of: scenePhase) { _, phase in
            nowPlaying.scenePhaseChanged(phase)
        }
        .onChange(of: nowPlaying.pendingRoute) { _, route in
            guard let route else { return }
            nowPlaying.pendingRoute = nil
            push(route)
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26, *) {
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: RootTab.home) {
                    stack(.home) { HomeView() }
                }
                Tab("Subscriptions", systemImage: "play.square.stack", value: RootTab.subscriptions) {
                    stack(.subscriptions) { SubscriptionsView() }
                }
                Tab("Library", systemImage: "books.vertical", value: RootTab.library) {
                    stack(.library) { LibraryView() }
                }
                Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                    stack(.settings) { SettingsView() }
                }
                Tab("Search", systemImage: "magnifyingglass", value: RootTab.search, role: .search) {
                    stack(.search) { SearchView() }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(MiniPlayerAccessory(isEnabled: nowPlaying.model != nil && !nowPlaying.isExpanded))
        } else {
            TabView(selection: $selection) {
                stack(.home) { HomeView() }
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(RootTab.home)

                stack(.subscriptions) { SubscriptionsView() }
                    .tabItem { Label("Subscriptions", systemImage: "play.square.stack") }
                    .tag(RootTab.subscriptions)

                stack(.library) { LibraryView() }
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(RootTab.library)

                stack(.search) { SearchView() }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(RootTab.search)

                stack(.settings) { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(RootTab.settings)
            }
        }
    }

    /// A tab's NavigationStack with the mini player inset above the tab bar (unless the iOS 26.1+
    /// tab view bottom accessory shows it). Only the selected tab hosts the bar's video layer.
    private func stack<Content: View>(_ tab: RootTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path(for: tab)) {
            content().routeDestinations()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection == tab, !MiniPlayerAccessory.isAvailable {
                MiniPlayerBar()
            }
        }
    }

    /// Videos never go on a stack: a newly appended `.video` route is handed to `NowPlaying` and
    /// dropped, so every existing `NavigationLink(value: Route.video(...))` opens the player.
    private func path(for tab: RootTab) -> Binding<[Route]> {
        Binding(
            get: { paths[tab] ?? [] },
            set: { newPath in
                let old = paths[tab] ?? []
                let kept = zip(old, newPath).prefix { $0 == $1 }.count
                var videoId: String?
                var filtered = Array(newPath.prefix(kept))
                for route in newPath.dropFirst(kept) {
                    if case .video(let id) = route {
                        videoId = id
                    } else {
                        filtered.append(route)
                    }
                }
                paths[tab] = filtered
                if let videoId {
                    NowPlaying.shared.open(videoId: videoId)
                }
            }
        )
    }

    /// Pushes a route requested from the expanded player onto the selected tab.
    private func push(_ route: Route) {
        var tab = selection
        if tab == .settings {
            tab = .home
            selection = .home
        }
        paths[tab, default: []].append(route)
    }
}

/// iOS 26.1+: the mini player as the native glass tab view bottom accessory. (26.0 has no
/// `isEnabled:` variant, and an always-on accessory would show an empty capsule, so it falls back
/// to the safe-area inset like iOS 17.)
private struct MiniPlayerAccessory: ViewModifier {
    let isEnabled: Bool

    static var isAvailable: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                MiniPlayerBar(style: .accessory)
            }
        } else {
            content
        }
    }
}
