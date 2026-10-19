import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// UIKit, like WebKit, asks `respondsToSelector:` before calling an optional delegate method.
/// The reader's edit-menu conformance became an isolated (`@MainActor`) conformance during the
/// Swift 6 migration; these tests ask the class exactly what `UIEditMenuInteraction` asks, so a
/// witness that stops being exposed to Objective-C — the selection menu silently reverting to
/// the system default — fails here instead of on a device.
@Suite("UIKit delegate witnesses")
struct UIKitDelegateWitnessTests {
    @Test("scroll reader's edit-menu delegate methods are exposed to UIKit", arguments: [
        "editMenuInteraction:menuForConfiguration:suggestedActions:",
        "editMenuInteraction:willPresentMenuForConfiguration:animator:",
        "editMenuInteraction:willDismissMenuForConfiguration:animator:",
    ])
    func scrollReaderEditMenu(selector: String) {
        #expect(CoreTextCollectionScrollViewController.instancesRespond(to: NSSelectorFromString(selector)))
    }
}
