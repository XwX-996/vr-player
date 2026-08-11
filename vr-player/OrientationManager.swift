import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hud-preview") {
            Self.supportedOrientations = .landscape
        }
#endif
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@MainActor
enum OrientationManager {
    static func lockPortrait() {
        update(mask: .portrait, preferred: .portrait)
    }

    static func lockLandscape() {
        update(mask: .landscape, preferred: nil)
    }

    private static func update(
        mask: UIInterfaceOrientationMask,
        preferred: UIInterfaceOrientationMask?
    ) {
        AppDelegate.supportedOrientations = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let requested = preferred ?? mask
        scene.windows.forEach {
            $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested))
    }
}
