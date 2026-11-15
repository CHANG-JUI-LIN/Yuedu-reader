import Combine
import SwiftUI
import UIKit

/// A `yuedu://module?src=` link (Phase 6e-2), from the system (`onOpenURL`) or from a page in
/// the in-app browser: the same import sheet as 從網址, already loading the linked address,
/// behind the same source disclaimer (`SourceDisclaimerGate`) and the same 閱讀Pro gate
/// (`RuleModuleAddAccess`): without Pro the link opens the paywall.
///
/// Presented from the top view controller rather than a SwiftUI sheet on the root: a link can
/// arrive while the reader or the in-app browser covers the screen, and a root sheet cannot
/// show over them (the browser's own 來源配置 links are presented the same way).
@MainActor
enum RuleModuleLinkPresenter {
    private static var disclaimer = SourceDisclaimerGate<URL>()

    static func present(_ address: URL) {
        // A link can be what launches the app, before the entitlement has been read: a member
        // would be shown the paywall. The read's own signal is awaited, then the link is taken.
        let subscriptions = SubscriptionStore.shared
        guard subscriptions.hasResolvedEntitlements else {
            Task {
                for await isResolved in subscriptions.$hasResolvedEntitlements.values where isResolved { break }
                present(address)
            }
            return
        }
        guard let top = BookSourceFormLoginView.topViewController() else {
            AppLogger.error("Module link: nowhere to present", context: ["address": address.absoluteString], level: .warning)
            return
        }
        guard RuleModuleAddAccess.isGranted() else {
            top.present(UIHostingController(rootView: PaywallView(highlightedFeature: .moduleImport)
                .environmentObject(SubscriptionStore.shared)), animated: true)
            return
        }
        guard let address = disclaimer.pass(address) else {
            presentDisclaimer(from: top)
            return
        }
        presentSheet(address, from: top)
    }

    private static func presentDisclaimer(from top: UIViewController) {
        // The continue button needs the controller that does not exist yet when its own
        // `rootView` is built; held weakly, so nothing retains a cycle.
        final class ControllerBox { weak var controller: UIViewController? }
        let box = ControllerBox()
        let host = UIHostingController(rootView: SourceDisclaimerView {
            disclaimer.accept()
            // The sheet opens once the disclaimer has really gone.
            box.controller?.dismiss(animated: true) {
                guard let address = disclaimer.afterDismissal(),
                      let top = BookSourceFormLoginView.topViewController() else { return }
                presentSheet(address, from: top)
            }
        })
        host.coversFullScreen()
        box.controller = host
        top.present(host, animated: true)
    }

    private static func presentSheet(_ address: URL, from top: UIViewController) {
        let model = RuleModuleImportModel()
        model.address = address.absoluteString
        top.present(UIHostingController(rootView: RuleModuleImportSheet(model: model, title: localized("新增模組"))),
                    animated: true)
        Task { await model.fetch() }
    }
}
