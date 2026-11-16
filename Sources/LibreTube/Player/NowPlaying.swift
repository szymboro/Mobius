import AVFoundation
import LibreTubeCore
import MediaPlayer
import SwiftUI
import UIKit

/// App-wide owner of the current video. The player (and its SABR server) lives as long as `model`,
/// independent of the expanded player or mini bar views, so minimizing never stops playback.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    @Published private(set) var model: PlayerViewModel?
    @Published var isExpanded = false
    /// A route requested from inside the expanded player (e.g. the uploader's channel). RootView
    /// pushes it onto the selected tab's path and clears it.
    @Published var pendingRoute: Route?

    /// Videos opened since launch, so autoplay doesn't loop between two related videos.
    private(set) var playedThisSession: Set<String> = []

    private let info = NowPlayingInfo()
    private var remoteCommandsRegistered = false

    private init() {}

    private func log(_ message: String) {
        PlaybackLog.shared.add(message, "nowplaying")
    }

    /// Plays `videoId` in the expanded player. Reuses the current model for the same video;
    /// otherwise the old one is torn down first so only one AVPlayer ever plays.
    /// `expand: false` (autoplay) keeps a minimized player minimized.
    func open(videoId: String, expand shouldExpand: Bool = true) {
        guard !videoId.isEmpty else { return }
        playedThisSession.insert(videoId)
        if let model, model.videoId == videoId, !model.isClosed {
            log("open \(videoId): already playing, expanding")
            expand()
            return
        }
        if let old = model {
            log("open \(videoId): replacing \(old.videoId)")
            old.close()
        } else {
            log("open \(videoId)")
        }
        registerRemoteCommandsIfNeeded()
        let new = PlayerViewModel(videoId: videoId)
        new.onEvent = { [weak self, weak new] event in
            guard let self, let new, self.model === new else { return }
            self.info.handle(event, for: new)
        }
        info.reset(for: new)
        if isExpanded || !shouldExpand {
            // Related video tapped in the expanded player, or autoplay: swap in place, no slide.
            model = new
        } else {
            withAnimation(Self.spring) {
                model = new
                isExpanded = true
            }
        }
        new.start()
    }

    /// Skips to the autoplay candidate (lock screen / headphone "next").
    @discardableResult
    func playNext() -> Bool {
        guard let next = model?.nextVideo else { return false }
        open(videoId: next.videoId, expand: false)
        return true
    }

    func minimize() {
        guard let model, isExpanded else { return }
        log("minimize \(model.videoId)")
        model.didMinimize()
        withAnimation(Self.spring) { isExpanded = false }
    }

    func expand() {
        guard let model else { return }
        if !isExpanded { log("expand \(model.videoId)") }
        withAnimation(Self.spring) { isExpanded = true }
    }

    /// Stops playback, records history and clears the system Now Playing info.
    func close() {
        guard let model else { return }
        log("close \(model.videoId)")
        model.close()
        info.clear()
        withAnimation(Self.spring) {
            self.model = nil
            isExpanded = false
        }
    }

    /// Minimizes the player and asks RootView to push `route` on the selected tab.
    func show(_ route: Route) {
        minimize()
        pendingRoute = route
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .inactive: model?.appWillResignActive()
        case .background: model?.appDidEnterBackground()
        case .active: model?.appDidBecomeActive()
        default: break
        }
    }

    // MARK: Remote commands

    /// Lock screen, Control Center, Dynamic Island and headphone controls. Registered once; the
    /// handlers always act on whatever `model` is current.
    private func registerRemoteCommandsIfNeeded() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        Self.addTarget(center.playCommand) { _ in
            NowPlaying.shared.withModel { $0.play() }
        }
        Self.addTarget(center.pauseCommand) { _ in
            NowPlaying.shared.withModel { $0.pause() }
        }
        Self.addTarget(center.togglePlayPauseCommand) { _ in
            NowPlaying.shared.withModel { $0.togglePlayPause() }
        }
        Self.addTarget(center.changePlaybackPositionCommand, value: {
            ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime
        }) { position in
            guard let position else { return false }
            return NowPlaying.shared.withModel { $0.seek(to: position) }
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        Self.addTarget(center.skipForwardCommand) { _ in
            NowPlaying.shared.withModel { $0.skip(by: 10) }
        }
        Self.addTarget(center.skipBackwardCommand) { _ in
            NowPlaying.shared.withModel { $0.skip(by: -10) }
        }
        Self.addTarget(center.nextTrackCommand) { _ in
            NowPlaying.shared.playNext()
        }
        center.previousTrackCommand.isEnabled = false
    }

    private func withModel(_ action: (PlayerViewModel) -> Void) -> Bool {
        guard let model, !model.isClosed, model.player != nil else { return false }
        action(model)
        return true
    }

    /// Registers `action` from a nonisolated context so MediaPlayer can call the handler on any
    /// thread without tripping Swift's main-actor isolation checks.
    nonisolated private static func addTarget(
        _ command: MPRemoteCommand,
        value: @escaping @Sendable (MPRemoteCommandEvent) -> Double? = { _ in nil },
        action: @escaping @MainActor @Sendable (Double?) -> Bool
    ) {
        command.isEnabled = true
        command.addTarget { event in
            let argument = value(event)
            if Thread.isMainThread {
                let handled = MainActor.assumeIsolated { action(argument) }
                return handled ? .success : .noActionableNowPlayingItem
            }
            Task { @MainActor in _ = action(argument) }
            return .success
        }
    }
}

/// Mirrors the current `PlayerViewModel` into `MPNowPlayingInfoCenter` (title, uploader, artwork,
/// duration, elapsed time and rate). AVPlayerViewController's own updates are turned off.
@MainActor
private final class NowPlayingInfo {
    private weak var model: PlayerViewModel?
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkCacheOrder: [String] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkLoadingFor: String?

    func reset(for model: PlayerViewModel) {
        self.model = model
        artworkTask?.cancel()
        artworkTask = nil
        artworkLoadingFor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func clear() {
        model = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkLoadingFor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func handle(_ event: PlayerViewModel.PlaybackEvent, for model: PlayerViewModel) {
        self.model = model
        if event == .metadata { loadArtworkIfNeeded(for: model) }
        publish()
    }

    private func publish() {
        guard let model, let video = model.video else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.uploaderName ?? "",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: model.streams?.isLive ?? false,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        var duration = Double(video.duration ?? 0)
        if let player = model.player {
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
            let elapsed = player.currentTime().seconds
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? max(elapsed, 0) : 0
            // `rate` is the requested rate; report 0 while stalled so the lock screen clock stops.
            let stalled = player.timeControlStatus != .playing
            info[MPNowPlayingInfoPropertyPlaybackRate] = stalled ? 0.0 : Double(player.rate)
        } else {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artworkCache[model.videoId] {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded(for model: PlayerViewModel) {
        let videoId = model.videoId
        guard artworkCache[videoId] == nil, artworkLoadingFor != videoId else { return }
        artworkLoadingFor = videoId
        let urls = Self.artworkURLs(videoId: videoId, thumbnail: model.streams?.thumbnailUrl)
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            for url in urls {
                guard let image = await Self.fetchImage(url) else { continue }
                guard !Task.isCancelled, let self else { return }
                self.store(Self.makeArtwork(image), for: videoId)
                return
            }
            PlaybackLog.shared.add("no artwork for \(videoId)", "nowplaying")
        }
    }

    private func store(_ artwork: MPMediaItemArtwork, for videoId: String) {
        artworkCache[videoId] = artwork
        artworkCacheOrder.removeAll { $0 == videoId }
        artworkCacheOrder.append(videoId)
        while artworkCacheOrder.count > 20 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
        if artworkLoadingFor == videoId { artworkLoadingFor = nil }
        if model?.videoId == videoId { publish() }
    }

    /// maxres → hq from i.ytimg.com (hqdefault always exists). With the Piped source, the
    /// instance's (usually proxied) thumbnail is tried first so nothing contacts Google unless needed.
    private static func artworkURLs(videoId: String, thumbnail: String?) -> [URL] {
        let youtube = ["maxresdefault", "hqdefault"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg")
        }
        let backend = RemoteImage.resolve(thumbnail)
        if AppSettings.shared.streamSource == .piped, let backend {
            return [backend] + youtube
        }
        return youtube + [backend].compactMap { $0 }
    }

    nonisolated private static func fetchImage(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UIImage(data: data)
    }

    /// Built in a nonisolated context: MediaPlayer calls the request handler off the main thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
