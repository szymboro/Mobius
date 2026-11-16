import UIKit

/// Lets full-screen video force landscape on iPhone, even with the rotation lock on.
/// `AppDelegate` reports `mask` as the supported orientations; changing it and requesting a
/// geometry update rotates the interface regardless of the device's orientation lock.
@MainActor
enum Orientation {
    private(set) static var mask: UIInterfaceOrientationMask = defaultMask

    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// Landscape-only while `landscape` is true; back to portrait (and free rotation) after.
    static func forceLandscape(_ landscape: Bool, in viewController: UIViewController?) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        mask = landscape ? .landscape : defaultMask
        let scene = viewController?.view.window?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        // Every visible controller must re-read the mask before the rotation is honoured.
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        viewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientation.mask }
    }
}
