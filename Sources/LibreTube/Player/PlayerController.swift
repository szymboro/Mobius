import AVKit
import SwiftUI

/// Wraps `AVPlayerViewController` for system controls, full screen and
/// Picture-in-Picture.
struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let model: PlayerViewModel
    /// Shown over the video (under AVKit's controls) in audio-only mode.
    var artwork: String?
    var isAudioOnly = false

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> InlinePlayerContainer {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // NowPlaying publishes title, artwork and timing itself; AVKit would overwrite it.
        controller.updatesNowPlayingInfoCenter = false
        controller.delegate = context.coordinator
        return InlinePlayerContainer(playerController: controller, player: player, model: model)
    }

    func updateUIViewController(_ container: InlinePlayerContainer, context: Context) {
        container.player = player
        container.showArtwork(artwork, visible: isAudioOnly)
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: PlayerViewModel

        init(model: PlayerViewModel) {
            self.model = model
        }
    }
}

extension PlayerController.Coordinator: @preconcurrency AVPlayerViewControllerDelegate {
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        model.isFullScreen = true
        // Turn to landscape once AVKit's full-screen controller is up, even with rotation lock on.
        coordinator.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled else { return }
            Orientation.forceLandscape(true, in: context.viewController(forKey: .to))
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [model] context in
            guard !context.isCancelled else { return }
            model.isFullScreen = false
            Orientation.forceLandscape(false, in: playerViewController)
        }
    }

    /// Set before the app finishes backgrounding (automatic PiP), so the container keeps the
    /// player attached for PiP instead of detaching it for background audio.
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        model.isPictureInPictureActive = true
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        model.isPictureInPictureActive = true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        model.isPictureInPictureActive = false
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        model.isPictureInPictureActive = false
    }

    /// The PiP "restore" button: bring the expanded player back (it stays mounted while in PiP).
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        NowPlaying.shared.expand()
        completionHandler(true)
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool {
        false
    }
}

/// Hosts the inline `AVPlayerViewController` as a child. AVPlayerViewController reports
/// `prefersStatusBarHidden = true`, and when embedded in SwiftUI that hid the clock and status
/// icons while the player was on screen. This container keeps the status bar visible inline
/// (AVKit's own full-screen presentation still manages it there).
final class InlinePlayerContainer: UIViewController {
    let playerController: AVPlayerViewController
    private let model: PlayerViewModel

    /// The player to show; detached from the controller while backgrounded (see below).
    var player: AVPlayer {
        didSet { attach() }
    }

    /// AVKit pauses a player shown by an AVPlayerViewController when the app goes to the
    /// background (e.g. the screen locks). Unless PiP takes over, detach it there so audio keeps
    /// playing, and reattach when returning (`PlayerViewModel` resumes it if AVKit paused it).
    private var isInBackground = UIApplication.shared.applicationState == .background

    init(playerController: AVPlayerViewController, player: AVPlayer, model: PlayerViewModel) {
        self.playerController = playerController
        self.player = player
        self.model = model
        super.init(nibName: nil, bundle: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        attach()
    }

    private func attach() {
        let detach = isInBackground && !model.isPictureInPictureActive
        let target = detach ? nil : player
        if playerController.player !== target { playerController.player = target }
    }

    @objc private func didEnterBackground() {
        isInBackground = true
        attach()
    }

    private var artworkHost: UIHostingController<AudioOnlyArtwork>?
    /// Changes each time the artwork appears, so its badge shows again and then fades.
    private var artworkToken = UUID()

    /// Covers the video with the thumbnail. It lives in `contentOverlayView`, which AVKit draws
    /// above the video but below its own controls, so playback controls keep working.
    func showArtwork(_ url: String?, visible: Bool) {
        guard visible else {
            artworkHost?.view.isHidden = true
            return
        }
        if artworkHost?.view.isHidden ?? true { artworkToken = UUID() }
        _ = playerController.view // loads the controller, creating contentOverlayView
        guard let overlay = playerController.contentOverlayView else { return }
        if let host = artworkHost {
            host.rootView = AudioOnlyArtwork(url: url, token: artworkToken)
        } else {
            let host = UIHostingController(rootView: AudioOnlyArtwork(url: url, token: artworkToken))
            host.view.backgroundColor = .black
            host.view.isUserInteractionEnabled = false
            host.view.frame = overlay.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(host.view)
            artworkHost = host
        }
        artworkHost?.view.isHidden = false
    }

    @objc private func willEnterForeground() {
        isInBackground = false
        attach()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(playerController)
        playerController.view.frame = view.bounds
        playerController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
    }

    override var prefersStatusBarHidden: Bool { false }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
}

/// Thumbnail with an "Audio only" badge, in place of the video. The badge fades out after a few
/// seconds and comes back when audio only is switched on again or the video changes.
struct AudioOnlyArtwork: View {
    let url: String?
    let token: UUID
    @State private var showsBadge = true

    var body: some View {
        ZStack {
            Color.black
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: url) }
                .clipped()
                // Dimmed only while the badge is up, to keep it readable.
                .opacity(showsBadge ? 0.6 : 1)
            Label("Audio only", systemImage: "headphones")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .opacity(showsBadge ? 1 : 0)
        }
        .task(id: "\(token)|\(url ?? "")") {
            showsBadge = true
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { showsBadge = false }
        }
    }
}
