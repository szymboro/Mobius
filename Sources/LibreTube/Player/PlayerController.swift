import AVKit
import SwiftUI

/// Wraps `AVPlayerViewController` for system controls, full screen and
/// Picture-in-Picture.
struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let model: PlayerViewModel

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
