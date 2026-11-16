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
        return InlinePlayerContainer(playerController: controller)
    }

    func updateUIViewController(_ container: InlinePlayerContainer, context: Context) {
        if container.playerController.player !== player {
            container.playerController.player = player
        }
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
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        model.isFullScreen = false
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        model.isPictureInPictureActive = true
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

    init(playerController: AVPlayerViewController) {
        self.playerController = playerController
        super.init(nibName: nil, bundle: nil)
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
