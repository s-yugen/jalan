import UIKit
import CarPlay

/// Named in Info.plist for the CarPlay scene. iOS creates it when the phone connects to a CarPlay
/// car, even if the app isn't open on the phone.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var carPlay: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        carPlay = CarPlayController(model: .shared, interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        carPlay?.disconnect()
        carPlay = nil
    }
}
