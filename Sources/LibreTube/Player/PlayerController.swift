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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // NowPlaying publishes title, artwork and timing itself; AVKit would overwrite it.
        controller.updatesNowPlayingInfoCenter = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
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
