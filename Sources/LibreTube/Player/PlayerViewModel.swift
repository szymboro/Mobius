import AVFoundation
import LibreTubeCore
import SwiftUI

/// Fast-changing playback state, kept apart from `PlayerViewModel` so that only the views that show
/// it (the mini player bar) re-render twice a second, not the whole player screen.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var position: Double = 0
    @Published fileprivate(set) var duration: Double = 0
    @Published fileprivate(set) var isPlaying = false

    var progress: Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// Owns one video's playback (AVPlayer, SABR server, SponsorBlock, history) and its metadata.
/// Lives as long as `NowPlaying.model`, not as long as any view; `close()` tears it down.
@MainActor
final class PlayerViewModel: ObservableObject {
    /// What the quality menu controls for the current stream.
    enum QualityMode: Equatable {
        /// Nothing to choose (no stream yet, or a single fixed stream).
        case unavailable
        /// The chosen quality is played exactly (SABR, progressive).
        case exact
        /// The chosen quality is a maximum for adaptive HLS (`preferredMaximumResolution`).
        case maximum
    }

    /// Changes `NowPlaying` mirrors into the system Now Playing info.
    enum PlaybackEvent {
        case metadata
        case playback
    }

    private enum PlaybackKind: String {
        case none, youtubeHLS, sabr, progressive, localHLS
    }
    enum Tab: String, CaseIterable, Identifiable {
        case related = "Related"
        case comments = "Comments"
        var id: Self { self }
    }

    private struct SkipSegment {
        let start: Double
        let end: Double
        let category: String
    }

    let videoId: String

    @Published private(set) var streams: Streams? {
        didSet { onEvent?(.metadata) }
    }
    @Published private(set) var phase: LoadPhase = .loading
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playbackError: String?
    @Published private(set) var related: [VideoInfo] = []
    @Published private(set) var skipNotice: String?

    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentsNextPage: String?
    @Published private(set) var commentsPhase: LoadPhase?
    @Published private(set) var commentsDisabled = false

    /// Quality menu state. Qualities are "720p"-style short-side pixel counts, best first;
    /// `qualitySelection == nil` means Auto.
    @Published private(set) var qualityOptions: [Int] = []
    @Published private(set) var qualitySelection: Int?
    @Published private(set) var qualityMode: QualityMode = .unavailable
    /// The quality AVPlayer is rendering right now (from `presentationSize`).
    @Published private(set) var playingQuality: Int?

    /// Set by the AVPlayerViewController delegate. PiP keeps the (hidden) expanded player mounted
    /// after minimizing, and both keep the SABR server running when the app goes to the background.
    var isFullScreen = false
    @Published var isPictureInPictureActive = false

    let clock = PlaybackClock()
    /// Called on the main actor; `NowPlaying` uses it to update `MPNowPlayingInfoCenter`.
    var onEvent: ((PlaybackEvent) -> Void)?
    /// True once `close()` ran; nothing may start playing afterwards.
    private(set) var isClosed = false
    private var loadTask: Task<Void, Never>?
    private var playbackKind: PlaybackKind = .none
    /// Max height LocalHLS was built with; higher quality caps would do nothing.
    private var localHLSMaxQuality: Int?
    /// Bumped on every SABR item rebuild so AVPlayer never reuses a cached master playlist.
    private var sabrItemGeneration = 0
    private var lastHistoryRecordPosition: Double = -1
    private var lastNowPlayingTick: Double = -1
    private var playbackKVO: [NSKeyValueObservation] = []
    private var playbackObservers: [NSObjectProtocol] = []

    private var segments: [SkipSegment] = []
    private var skippedSegments: Set<Int> = []
    private var timeObserver: Any?
    private var lastPosition: Double = 0
    private var isLoadingMoreComments = false
    private var skipNoticeTask: Task<Void, Never>?
    /// Retained while playing: AVAssetResourceLoader only holds its delegate weakly.
    private var localHLSLoader: LocalHLSLoader?

    /// Localhost HLS server fed by YouTube's SABR protocol; retained for the life of the player.
    private var sabrServer: SabrHLSServer?
    private var sabrMasterURL: URL?
    private var sabrItemObservation: NSKeyValueObservation?
    /// True while the server is deliberately stopped because the screen went away.
    private var isSabrSuspended = false
    /// The SABR item failed while suspended; rebuild it when the screen comes back.
    private var sabrNeedsReload = false

    init(videoId: String) {
        self.videoId = videoId
    }

    var video: VideoInfo? {
        streams.map { VideoInfo(videoId: videoId, streams: $0) }
    }

    // MARK: Loading

    /// Starts loading and playing; the task is owned by the model so minimizing can't cancel it.
    func start() {
        guard loadTask == nil, !isClosed else { return }
        loadTask = Task { [weak self] in await self?.load() }
    }

    func load() async {
        guard streams == nil, !isClosed else { return }
        phase = .loading
        let settings = AppSettings.shared
        PlaybackLog.shared.begin("video \(videoId), source \(settings.streamSource.rawValue), quality \(settings.preferredQuality)")
        do {
            let streams = try await settings.streams(videoId: videoId)
            guard !isClosed else { return }
            self.streams = streams
            related = (optional(streams.relatedStreams) ?? []).map { VideoInfo($0) }.uniqued()
            fillMissingDetails(from: streams)
            phase = .loaded
            await startPlayback(streams, preferredQuality: settings.preferredQuality)
            if settings.sponsorBlockEnabled, !isClosed {
                await loadSegments(categories: Array(settings.sponsorBlockCategories))
            }
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadSegments(categories: [String]) async {
        guard !categories.isEmpty else { return }
        do {
            let result = try await AppSettings.shared.api.sponsorSegments(videoId: videoId, categories: categories)
            segments = result.compactMap { segment -> SkipSegment? in
                let bounds = (optional(segment.segment) ?? []).map { Double($0) }
                guard bounds.count >= 2, bounds[1] > bounds[0] else { return nil }
                return SkipSegment(start: bounds[0], end: bounds[1], category: optional(segment.category) ?? "")
            }
        } catch {
            // SponsorBlock answers 404 when a video has no segments.
            segments = []
        }
    }

    func loadComments() async {
        switch commentsPhase {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        commentsPhase = .loading
        do {
            let page = try await fetchFirstCommentsPage()
            comments = (optional(page.comments) ?? []).uniqued()
            commentsNextPage = optional(page.nextpage)
            commentsDisabled = optional(page.disabled) ?? false
            commentsPhase = .loaded
        } catch {
            commentsPhase = isCancellation(error) ? nil : .failed(error.localizedDescription)
        }
    }

    func reloadComments() async {
        commentsPhase = nil
        await loadComments()
    }

    func loadMoreComments() async {
        guard let page = commentsNextPage, !isLoadingMoreComments else { return }
        isLoadingMoreComments = true
        defer { isLoadingMoreComments = false }
        do {
            // Continuation tokens only work with the backend that issued them.
            let next = commentsFromInnerTube
                ? try await YouTubeInnerTube.commentsNextPage(videoId: videoId, nextpage: page)
                : try await AppSettings.shared.api.commentsNextPage(videoId: videoId, nextpage: page)
            comments.appendUnique(optional(next.comments) ?? [])
            commentsNextPage = optional(next.nextpage)
        } catch {
            // Keep the token; the sentinel retries when it reappears.
        }
    }

    // MARK: InnerTube metadata

    /// Whether `comments` / `commentsNextPage` came from YouTube's InnerTube API rather than Piped.
    private var commentsFromInnerTube = false

    /// On-device source: InnerTube first, Piped as fallback. Piped source: Piped first, InnerTube when
    /// Piped fails or only returns avatar-less comments (decayed instances send `thumbnail: null`).
    private func fetchFirstCommentsPage() async throws -> CommentsPage {
        let api = AppSettings.shared.api
        if AppSettings.shared.streamSource == .onDevice {
            do {
                let page = try await YouTubeInnerTube.comments(videoId: videoId)
                commentsFromInnerTube = true
                return page
            } catch {
                if isCancellation(error) { throw error }
                let page = try await api.comments(videoId: videoId)
                commentsFromInnerTube = false
                return page
            }
        }
        do {
            let page = try await api.comments(videoId: videoId)
            if !page.comments.isEmpty, page.comments.allSatisfy({ $0.thumbnail.isEmpty }),
               let youtube = try? await YouTubeInnerTube.comments(videoId: videoId), !youtube.comments.isEmpty {
                commentsFromInnerTube = true
                return youtube
            }
            commentsFromInnerTube = false
            return page
        } catch {
            if isCancellation(error) { throw error }
            guard let page = try? await YouTubeInnerTube.comments(videoId: videoId) else { throw error }
            commentsFromInnerTube = true
            return page
        }
    }

    /// The iOS player endpoint (on-device source) has no uploader avatar, subscriber count, likes, upload
    /// date or related videos. Fetch them from InnerTube `next` in the background; never blocks playback.
    private func fillMissingDetails(from streams: Streams) {
        let missing = (optional(streams.uploaderAvatar) ?? "").isEmpty
            || streams.uploaderSubscriberCount <= 0
            || streams.likes <= 0
            || streams.uploadTimestamp == nil
            || related.isEmpty
        guard missing else { return }
        let videoId = videoId
        Task { [weak self] in
            guard let details = try? await YouTubeInnerTube.next(videoId: videoId) else { return }
            self?.apply(details)
        }
    }

    private func apply(_ details: VideoDetails) {
        guard var updated = streams else { return }
        if (optional(updated.uploaderAvatar) ?? "").isEmpty, let avatar = details.uploaderAvatar {
            updated.uploaderAvatar = avatar
        }
        if updated.uploaderSubscriberCount <= 0, let subscribers = details.uploaderSubscriberCount {
            updated.uploaderSubscriberCount = subscribers
        }
        if updated.likes <= 0, let likes = details.likes {
            updated.likes = likes
        }
        if updated.uploadTimestamp == nil, let date = details.uploadDate {
            updated.uploaded = Int(date.timeIntervalSince1970 * 1000)
        }
        if !updated.uploaderVerified, details.uploaderVerified {
            updated.uploaderVerified = true
        }
        if updated.relatedStreams.isEmpty, !details.related.isEmpty {
            updated.relatedStreams = details.related
        }
        if related.isEmpty, !details.related.isEmpty {
            related = details.related.map { VideoInfo($0) }.uniqued()
        }
        if updated != streams { streams = updated }
    }


    // MARK: Playback

    /// Playback order: YouTube's HLS → SABR through the local `SabrHLSServer` (on-device source,
    /// non-live) → a muxed progressive stream → HLS built on the device from the DASH files.
    private func startPlayback(_ streams: Streams, preferredQuality: String) async {
        var item: AVPlayerItem?
        var sabrFailure: String?
        let log = PlaybackLog.shared
        log.add("streams: hls=\(streams.hls != nil) live=\(streams.isLive) video=\(streams.videoStreams.count) audio=\(streams.audioStreams.count) duration=\(streams.duration)s")
        if let hls = optional(streams.hls), !hls.isEmpty, let url = URL(string: hls) {
            log.add("playing YouTube HLS")
            item = AVPlayerItem(url: url)
            playbackKind = .youtubeHLS
        } else if !streams.isLive, AppSettings.shared.streamSource == .onDevice {
            do {
                let started = Date()
                item = try await startSabr(preferredQuality: preferredQuality)
                playbackKind = .sabr
                log.add("SABR ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                guard !isCancellation(error), !isClosed else { return }
                sabrFailure = "SABR streaming failed: \(Self.describe(error))"
                log.add(sabrFailure ?? "")
            }
        }
        guard !isClosed else { return }
        if item == nil {
            log.add("using fallback stream (progressive or on-device HLS; YouTube may cut this off after ~70 s)")
            item = await fallbackItem(streams, preferredQuality: preferredQuality, priorFailure: sabrFailure)
        }
        guard let item, !isClosed else { return }
        if let sabrFailure {
            // Playing from the fallback; keep the reason visible for a moment.
            playbackError = sabrFailure
            showNotice(sabrFailure + " Using fallback stream.", for: 6)
        }
        configureQualityMenu(streams: streams, preferredQuality: preferredQuality)
        applyQualityCap(to: item)
        activateAudioSession()
        let player = AVPlayer(playerItem: item)
        self.player = player
        observeDiagnostics(player)
        observePlayback(player)

        if let resume = resumePosition(duration: intValue(streams.duration)) {
            seek(to: resume)
        }
        player.play()
        addTimeObserver()
    }

    /// The pre-SABR path: a muxed progressive stream, else LocalHLS. Sets `playbackError` and
    /// returns nil when nothing is playable; `priorFailure` is prepended to that message.
    private func fallbackItem(_ streams: Streams, preferredQuality: String, priorFailure: String?) async -> AVPlayerItem? {
        func fail(_ message: String) -> AVPlayerItem? {
            playbackError = [priorFailure, message].compactMap { $0 }.joined(separator: "\n")
            return nil
        }
        if let url = Self.playbackURL(for: streams, preferredQuality: preferredQuality) {
            playbackKind = (optional(streams.hls) ?? "").isEmpty ? .progressive : .youtubeHLS
            return AVPlayerItem(url: url)
        }
        if streams.isLive {
            return fail("YouTube didn't provide a playable stream for this livestream. Try again, or switch Video Source in Settings.")
        }
        do {
            // No HLS from YouTube: build one on the device from the DASH files.
            let maxHeight = Self.height(ofQuality: preferredQuality)
            let hls = try await LocalHLS.build(streams: streams, maxHeight: maxHeight)
            guard !isClosed else { return nil }
            let loader = LocalHLSLoader(hls: hls)
            localHLSLoader = loader
            localHLSMaxQuality = maxHeight
            playbackKind = .localHLS
            return AVPlayerItem(asset: loader.makeAsset())
        } catch {
            guard !isCancellation(error) else { return nil }
            return fail("Couldn't open the video stream: \(Self.describe(error))")
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            PlaybackLog.shared.add("audio session activation failed: \(Self.describe(error))")
        }
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    // MARK: Controls

    var isPaused: Bool { (player?.rate ?? 0) == 0 }

    /// Plays, first restarting the SABR server if it was suspended or died in the background.
    func play() {
        guard let player, !isClosed else { return }
        activateAudioSession()
        if sabrServerNeedsRestart {
            resumeSabrIfNeeded(thenPlay: true)
        } else {
            player.play()
        }
    }

    func pause() {
        player?.pause()
    }

    func togglePlayPause() {
        if isPaused { play() } else { pause() }
    }

    func skip(by seconds: Double) {
        guard player != nil else { return }
        var target = max(currentPosition() + seconds, 0)
        if clock.duration > 0 { target = min(target, clock.duration - 1) }
        seek(to: target)
    }

    // MARK: Quality

    /// Fills the menu for the stream that is now playing. For SABR the selection was already
    /// resolved (and applied to the server) in `startSabr`.
    private func configureQualityMenu(streams: Streams, preferredQuality: String) {
        let preferred = Self.height(ofQuality: preferredQuality)
        switch playbackKind {
        case .sabr:
            qualityOptions = sabrServer?.availableQualities ?? []
            qualityMode = qualityOptions.count > 1 ? .exact : .unavailable
        case .progressive:
            qualityOptions = Self.muxedStreams(streams).map(\.height).filter { $0 > 0 }.uniquedInOrder()
            qualityMode = qualityOptions.count > 1 ? .exact : .unavailable
            qualitySelection = Self.resolve(preferred, in: qualityOptions)
        case .youtubeHLS, .localHLS:
            var heights = (optional(streams.videoStreams) ?? [])
                .compactMap { Self.height(ofQuality: optional($0.quality) ?? "") ?? intValue($0.height) }
                .filter { $0 > 0 }
                .sorted(by: >)
                .uniquedInOrder()
            if heights.isEmpty { heights = [1080, 720, 480, 360, 240, 144] }
            if playbackKind == .localHLS, let cap = localHLSMaxQuality {
                heights = heights.filter { $0 <= cap }
            }
            qualityOptions = heights
            qualityMode = heights.isEmpty ? .unavailable : .maximum
            qualitySelection = Self.resolve(preferred, in: heights)
        case .none:
            qualityOptions = []
            qualityMode = .unavailable
            qualitySelection = nil
        }
        PlaybackLog.shared.add("quality menu: \(playbackKind.rawValue) \(qualityMode) options=\(qualityOptions.map { "\($0)p" }.joined(separator: ",")) selected=\(Self.qualityLabel(qualitySelection))")
    }

    /// Caps adaptive HLS variant selection; no effect on progressive streams or SABR (whose
    /// master playlist is restricted by the server instead).
    private func applyQualityCap(to item: AVPlayerItem) {
        guard playbackKind == .youtubeHLS || playbackKind == .localHLS else { return }
        if let height = qualitySelection {
            item.preferredMaximumResolution = CGSize(width: CGFloat(height) * 16 / 9, height: CGFloat(height))
        } else {
            item.preferredMaximumResolution = .zero
        }
    }

    /// Applies a quality menu choice (nil = Auto) for the rest of this session.
    func selectQuality(_ quality: Int?) {
        guard let player, !isClosed, qualityMode != .unavailable, quality != qualitySelection else { return }
        let previous = qualitySelection
        qualitySelection = quality
        let log = PlaybackLog.shared
        log.add("quality change: \(Self.qualityLabel(previous)) -> \(Self.qualityLabel(quality)) (\(playbackKind.rawValue), at \(String(format: "%.1f", currentPosition()))s, playing \(playingQuality.map { "\($0)p" } ?? "?"))")
        switch playbackKind {
        case .sabr:
            guard let server = sabrServer, let base = sabrMasterURL else { return }
            server.selectedQuality = quality
            if isSabrSuspended {
                // The item is rebuilt when the server comes back.
                sabrNeedsReload = true
                return
            }
            let url = sabrItemURL(base: base)
            log.add("loading SABR master \(url.absoluteString)")
            let item = AVPlayerItem(url: url)
            observeSabrItem(item)
            replaceItem(with: item)
        case .youtubeHLS, .localHLS:
            if let item = player.currentItem { applyQualityCap(to: item) }
        case .progressive:
            guard let streams, let url = Self.playbackURL(for: streams, preferredQuality: Self.qualityLabel(quality)) else { return }
            replaceItem(with: AVPlayerItem(url: url))
        case .none:
            break
        }
    }

    /// Swaps in `item` at the current position, keeping the play/pause state.
    private func replaceItem(with item: AVPlayerItem) {
        guard let player else { return }
        let position = currentPosition()
        let wasPlaying = player.rate != 0
        player.replaceCurrentItem(with: item)
        if position > 1 { seek(to: position) }
        if wasPlaying { player.play() } else { player.pause() }
        playingQuality = nil
        onEvent?(.playback)
    }

    /// "auto", or "720p".
    static func qualityLabel(_ quality: Int?) -> String {
        quality.map { "\($0)p" } ?? "auto"
    }

    /// The best option not above `preferred`, else the lowest; nil (Auto) without a preference.
    private static func resolve(_ preferred: Int?, in options: [Int]) -> Int? {
        guard let preferred, !options.isEmpty else { return nil }
        return options.first { $0 <= preferred } ?? options.last
    }

    // MARK: Diagnostics

    private var diagnosticObservers: [NSObjectProtocol] = []
    private var diagnosticKVO: [NSKeyValueObservation] = []

    /// Logs AVPlayer state changes, stalls and HLS error-log entries to `PlaybackLog`.
    /// The player-level KVO follows item replacements (quality changes, SABR rebuilds) by itself.
    private func observeDiagnostics(_ player: AVPlayer) {
        let log = PlaybackLog.shared
        diagnosticKVO = [
            player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                let state: String
                switch player.timeControlStatus {
                case .paused: state = "paused"
                case .playing: state = "playing"
                case .waitingToPlayAtSpecifiedRate: state = "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
                @unknown default: state = "unknown"
                }
                log.add("player \(state) at \(String(format: "%.1f", player.currentTime().seconds))s", "avplayer")
            },
            player.observe(\.currentItem?.status, options: [.new]) { player, _ in
                guard let item = player.currentItem else { return }
                let status = ["unknown", "readyToPlay", "failed"][min(item.status.rawValue, 2)]
                var line = "item \(status)"
                if let error = item.error as NSError? {
                    line += ": \(error.localizedDescription) (\(error.domain) \(error.code))"
                    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                        line += " underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
                    }
                }
                log.add(line, "avplayer")
            },
        ]
        let center = NotificationCenter.default
        diagnosticObservers.forEach(center.removeObserver)
        diagnosticObservers = [
            center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: nil) { note in
                guard let event = (note.object as? AVPlayerItem)?.errorLog()?.events.last else { return }
                log.add("HLS error \(event.errorDomain) \(event.errorStatusCode): \(event.errorComment ?? "") uri=\(event.uri ?? "-")", "avplayer")
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: nil) { note in
                let t = (note.object as? AVPlayerItem)?.currentTime().seconds ?? -1
                log.add("playback stalled at \(String(format: "%.1f", t))s", "avplayer")
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: nil) { note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                log.add("failed to play to end: \(error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "?")", "avplayer")
            },
            center.addObserver(forName: AVPlayerItem.newAccessLogEntryNotification, object: nil, queue: nil) { note in
                guard let event = (note.object as? AVPlayerItem)?.accessLog()?.events.last else { return }
                log.add("access: \(Int(event.indicatedBitrate / 1000)) kbps, stalls=\(event.numberOfStalls), dropped=\(event.numberOfDroppedVideoFrames), uri=\(event.uri ?? "-")", "avplayer")
            },
        ]
    }

    /// Play/pause/rate/seek changes for the mini player and the system Now Playing info.
    private func observePlayback(_ player: AVPlayer) {
        playbackKVO = [
            player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.playbackStateChanged() }
            },
            player.observe(\.rate, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.playbackStateChanged() }
            },
        ]
        let center = NotificationCenter.default
        playbackObservers.forEach(center.removeObserver)
        playbackObservers = [
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    self.onEvent?(.playback)
                }
            },
        ]
    }

    private func playbackStateChanged() {
        guard let player, !isClosed else { return }
        let playing = player.rate != 0
        if clock.isPlaying != playing { clock.isPlaying = playing }
        onEvent?(.playback)
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        (diagnosticObservers + playbackObservers).forEach(center.removeObserver)
        diagnosticObservers = []
        playbackObservers = []
        diagnosticKVO = []
        playbackKVO = []
        sabrItemObservation = nil
    }

    // MARK: SABR

    private func startSabr(preferredQuality: String) async throws -> AVPlayerItem {
        let manifest = try await YouTubeExtractor.sabrManifest(videoId: videoId)
        let server = try SabrHLSServer(manifest: manifest)
        // The session's choice starts from Settings › Preferred Quality.
        let selection = Self.resolve(Self.height(ofQuality: preferredQuality), in: server.availableQualities)
        server.selectedQuality = selection
        qualitySelection = selection
        PlaybackLog.shared.add("SABR qualities: \(server.availableQualities.map { "\($0)p" }.joined(separator: ",")), starting with \(Self.qualityLabel(selection))")
        let url = try await server.start()
        if Task.isCancelled || isClosed {
            server.stop()
            throw CancellationError()
        }
        sabrServer = server
        sabrMasterURL = url
        let item = AVPlayerItem(url: sabrItemURL(base: url))
        observeSabrItem(item)
        return item
    }

    /// The master playlist URL for a new AVPlayerItem; the query (ignored by the server) keeps
    /// AVFoundation from reusing a cached playlist after the selection changed.
    private func sabrItemURL(base: URL) -> URL {
        sabrItemGeneration += 1
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = [
            URLQueryItem(name: "q", value: Self.qualityLabel(qualitySelection)),
            URLQueryItem(name: "g", value: String(sabrItemGeneration)),
        ]
        return components.url ?? base
    }

    private func observeSabrItem(_ item: AVPlayerItem) {
        sabrItemObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error.map { Self.describe($0) } ?? "unknown error"
            Task { @MainActor in await self?.sabrPlaybackFailed(message) }
        }
    }

    /// AVPlayer gave up on the SABR stream: switch to the fallback at the same position.
    private func sabrPlaybackFailed(_ message: String) async {
        guard !isClosed else { return }
        PlaybackLog.shared.add("AVPlayer failed the SABR item at \(String(format: "%.1f", currentPosition()))s: \(message) (suspended=\(isSabrSuspended))")
        guard sabrServer != nil, let streams else { return }
        if isSabrSuspended {
            // Expected: the server was stopped on purpose. Rebuild when it is resumed.
            sabrNeedsReload = true
            return
        }
        let position = currentPosition()
        sabrItemObservation = nil
        sabrServer?.stop()
        sabrServer = nil
        sabrMasterURL = nil

        let failure = "SABR playback failed: \(message)"
        let preferredQuality = AppSettings.shared.preferredQuality
        guard let item = await fallbackItem(streams, preferredQuality: preferredQuality, priorFailure: failure), !isClosed else {
            removeTimeObserver()
            player?.pause()
            player = nil
            return
        }
        playbackError = failure
        showNotice(failure + " Using fallback stream.", for: 6)
        configureQualityMenu(streams: streams, preferredQuality: preferredQuality)
        applyQualityCap(to: item)
        player?.replaceCurrentItem(with: item)
        if position > 1 { seek(to: position) }
        player?.play()
    }

    private var sabrServerNeedsRestart: Bool {
        guard let sabrServer else { return false }
        return isSabrSuspended || !sabrServer.isRunning
    }

    /// Restarts the SABR server after a suspension (or after its listener died while the app was
    /// suspended), rebuilding the item if the port changed or the old item failed meanwhile.
    private func resumeSabrIfNeeded(thenPlay: Bool = false) {
        guard let server = sabrServer, sabrServerNeedsRestart else {
            if thenPlay { player?.play() }
            return
        }
        PlaybackLog.shared.add("resuming local server (suspended=\(isSabrSuspended))")
        isSabrSuspended = false
        let oldURL = sabrMasterURL
        let oldPort = oldURL?.port.flatMap { UInt16(exactly: $0) }
        Task { [weak self] in
            do {
                let url = try await server.start(preferredPort: oldPort)
                guard let self, self.sabrServer === server, !self.isClosed else { return }
                if url != oldURL || self.sabrNeedsReload || self.player?.currentItem?.status == .failed {
                    self.sabrNeedsReload = false
                    self.sabrMasterURL = url
                    let position = self.currentPosition()
                    let item = AVPlayerItem(url: self.sabrItemURL(base: url))
                    self.observeSabrItem(item)
                    self.player?.replaceCurrentItem(with: item)
                    if position > 1 { self.seek(to: position) }
                }
                if thenPlay { self.player?.play() }
            } catch {
                await self?.sabrPlaybackFailed("couldn't restart the local server: \(Self.describe(error))")
            }
        }
    }

    private func currentPosition() -> Double {
        if let seconds = player?.currentTime().seconds, seconds.isFinite, seconds > 0 { return seconds }
        return lastPosition
    }

    /// Resume from the stored history position unless it is at the very start or end.
    private func resumePosition(duration: Int?) -> Double? {
        let entry = LibraryStore.shared.history.first { optional($0.videoId) == videoId }
        guard let position = entry.map({ $0.position }), position > 5 else { return nil }
        if let duration, duration > 0, position > Double(duration) - 10 { return nil }
        return position
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addTimeObserver() {
        guard let player, timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTime(time.seconds)
            }
        }
    }

    private func removeTimeObserver() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func handleTime(_ seconds: Double) {
        guard seconds.isFinite, !isClosed else { return }
        lastPosition = seconds
        updateClock(seconds)
        if abs(seconds - lastHistoryRecordPosition) >= 30 {
            recordHistory()
        }
        if abs(seconds - lastNowPlayingTick) >= 5 {
            lastNowPlayingTick = seconds
            onEvent?(.playback)
        }
        guard AppSettings.shared.sponsorBlockEnabled else { return }
        for (index, segment) in segments.enumerated() where !skippedSegments.contains(index) {
            if seconds >= segment.start, seconds < segment.end - 0.3 {
                skippedSegments.insert(index)
                seek(to: segment.end)
                showSkipNotice(for: segment.category)
                break
            }
        }
    }

    private func updateClock(_ seconds: Double) {
        clock.position = seconds
        var duration = Double(intValue(streams?.duration) ?? 0)
        if let itemDuration = player?.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        if clock.duration != duration { clock.duration = duration }
        let playing = (player?.rate ?? 0) != 0
        if clock.isPlaying != playing { clock.isPlaying = playing }
        if let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0 {
            let quality = Int(min(size.width, size.height).rounded())
            if quality != playingQuality {
                playingQuality = quality
                PlaybackLog.shared.add("rendering \(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    private func showSkipNotice(for category: String) {
        showNotice("Skipped \(SponsorBlockCategory.title(for: category).lowercased())", for: 2.5)
    }

    private func showNotice(_ text: String, for seconds: Double) {
        skipNotice = text
        skipNoticeTask?.cancel()
        skipNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.skipNotice = nil
        }
    }

    // MARK: Lifecycle (driven by NowPlaying, not by views)

    /// The expanded player was minimized to the mini bar; playback continues.
    func didMinimize() {
        capturePosition()
        recordHistory()
    }

    /// Records the watch position, then stops playback and the SABR server for good. Called when
    /// the mini player is closed or another video replaces this one.
    func close() {
        guard !isClosed else { return }
        capturePosition()
        recordHistory()
        isClosed = true
        onEvent = nil
        loadTask?.cancel()
        loadTask = nil
        removeTimeObserver()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        sabrServer?.stop()
        sabrServer = nil
        sabrMasterURL = nil
        localHLSLoader = nil
        skipNoticeTask?.cancel()
        clock.isPlaying = false
    }

    /// While paused in the background the app gets suspended and the local listener would die,
    /// so stop the server on purpose; playing (background audio) or PiP keeps it running.
    func appDidEnterBackground() {
        guard !isClosed else { return }
        capturePosition()
        recordHistory()
        guard let sabrServer, !isSabrSuspended, isPaused, !isPictureInPictureActive else { return }
        PlaybackLog.shared.add("app in background while paused: suspending local server")
        isSabrSuspended = true
        sabrServer.stop()
    }

    func appDidBecomeActive() {
        guard !isClosed else { return }
        resumeSabrIfNeeded()
    }

    private func capturePosition() {
        if let seconds = player?.currentTime().seconds, seconds.isFinite, seconds > 0 {
            lastPosition = seconds
        }
    }

    private func recordHistory() {
        lastHistoryRecordPosition = lastPosition
        guard let video, let entry = ModelFactory.historyEntry(for: video, position: lastPosition) else { return }
        LibraryStore.shared.recordWatch(entry)
    }

    // MARK: Stream selection

    /// Muxed (audio+video) progressive streams, best first.
    static func muxedStreams(_ streams: Streams) -> [(height: Int, url: URL)] {
        (optional(streams.videoStreams) ?? [])
            .compactMap { stream -> (height: Int, url: URL)? in
                guard optional(stream.videoOnly) != true,
                      let string = optional(stream.url),
                      let url = URL(string: string)
                else { return nil }
                let streamHeight = Self.height(ofQuality: optional(stream.quality) ?? "")
                    ?? intValue(stream.height) ?? 0
                return (streamHeight, url)
            }
            .sorted { $0.height > $1.height }
    }

    /// Prefers HLS (native in AVPlayer); otherwise the best muxed (audio+video)
    /// progressive stream not exceeding the preferred quality.
    static func playbackURL(for streams: Streams, preferredQuality: String) -> URL? {
        if let hls = optional(streams.hls), !hls.isEmpty, let url = URL(string: hls) {
            return url
        }
        let candidates = muxedStreams(streams)
        guard let maxHeight = Self.height(ofQuality: preferredQuality) else {
            return candidates.first?.url
        }
        return (candidates.first { $0.height <= maxHeight } ?? candidates.last)?.url
    }

    /// "720p60" → 720; "auto" → nil.
    static func height(ofQuality quality: String) -> Int? {
        Int(quality.prefix { $0.isNumber })
    }
}

private extension Array where Element: Hashable {
    func uniquedInOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
