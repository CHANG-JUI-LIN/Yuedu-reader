import SwiftUI
import UIKit

/// Opens what source JS asks the reader for — a page (`java.startBrowser` /
/// `java.startBrowserAwait`) or an image captcha (`java.getVerificationCode`) — from wherever
/// the script runs: search, a chapter, 書源驗證, a login menu. Legado's
/// `SourceVerificationHelp` does the same from any thread, in both Legado-E and MD3.
///
/// One sheet at a time: a request that arrives while one is up waits until it is gone, as
/// Legado's `getVerificationResult` is `@Synchronized`. Several sources checked in parallel
/// therefore queue their sheets instead of stacking them.
@MainActor
enum SourceBrowserPresenter {
    /// Installs this as `LegadoJSBridge.sharedBrowserPresenter` and
    /// `sharedCaptchaPresenter`. Called once at launch.
    static func install() {
        LegadoJSBridge.sharedBrowserPresenter = { request, completion in
            Task { @MainActor in
                present(request, completion: completion)
            }
        }
        LegadoJSBridge.sharedCaptchaPresenter = { request, completion in
            Task { @MainActor in
                presentCaptcha(request, completion: completion)
            }
        }
        LegadoJSBridge.sharedVideoPresenter = { request, title in
            Task { @MainActor in
                presentVideo(request, title: title)
            }
        }
        LegadoJSBridge.sharedOpenURLPresenter = { request in
            Task { @MainActor in
                presentOpenURL(request)
            }
        }
    }

    /// `java.openUrl`: an import link goes to the app's importer, which asks first; any
    /// other link waits its turn with the sheets for the reader's 開啟 — legado-E's
    /// `OpenUrlConfirmDialog` — and then opens in whatever app takes it.
    static func presentOpenURL(_ request: SourceOpenURLRequest) {
        if let mimeType = request.mimeType {
            AppLogger.parse("⟐ openUrl: mimeType not applicable on iOS", context: ["mimeType": mimeType])
        }
        if request.isImportLink {
            NotificationCenter.default.post(
                name: .sourceRequestedImportLink, object: nil, userInfo: ["url": request.url]
            )
            return
        }
        waiting.append(Pending(completion: { _ in }, content: .openURL(request)))
        presentNextIfIdle()
    }

    /// `java.openVideoPlayer`: the app's video player, full screen, playing at once — legado-E's
    /// `VideoPlayerActivity`. Not queued with the sheets: nothing waits on it.
    static func presentVideo(_ request: URLRequest, title: String) {
        guard let url = request.url, let topVC = BookSourceFormLoginView.topViewController(),
              let scene = topVC.view.window?.windowScene else {
            AppLogger.parse("⟐ openVideoPlayer: nowhere to present", context: [:])
            return
        }
        let stream = VideoStream(url: url, headers: request.allHTTPHeaderFields ?? [:])
        // Hosted outside the app's view tree, so without its `BookStore`: the one-link player
        // reads none, and a change that makes it read one must hand it over here. Nor its
        // `scenePhase`, which the player saves its place by on leaving the app.
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        let host = UIHostingController(rootView:
            VideoPlayerView(content: .link(stream, title: title)) { box.host?.dismiss(animated: true) }
                .followsScenePhase(of: scene)
        )
        box.host = host
        host.coversFullScreen()
        topVC.present(host, animated: true)
    }

    /// Shows `request`'s page. `completion` runs exactly once: with the page's HTML when the
    /// user confirms it (✓, or a Cloudflare challenge on it clearing), with nil when the page
    /// goes away any other way — ✕, a swipe, or nowhere to present it.
    static func present(_ request: SourceBrowserRequest, completion: @escaping (String?) -> Void) {
        enqueue(Pending(completion: completion, content: .page(request)), withdrawal: request.withdrawal)
    }

    /// Shows `request`'s captcha. `completion` runs exactly once: with the code the user
    /// entered, or nil when the sheet goes away without one.
    static func presentCaptcha(_ request: SourceCaptchaRequest, completion: @escaping (String?) -> Void) {
        enqueue(Pending(completion: completion, content: .captcha(request)), withdrawal: request.withdrawal)
    }

    /// Queues `pending`; when the wait behind it is ended from outside (a validation run out of
    /// time), a sheet still queued is dropped and one on screen is dismissed — which answers
    /// the script nil, as the reader's own ✕ does.
    private static func enqueue(_ pending: Pending, withdrawal: SourceWaitWithdrawal?) {
        waiting.append(pending)
        withdrawal?.onWithdraw { withdraw(pending.id) }
        presentNextIfIdle()
    }

    private static func withdraw(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).completion(nil)
            return
        }
        guard showingID == id, let host = showingHost else { return }
        host.presentingViewController?.dismiss(animated: true)
    }

    private struct Pending {
        enum Content {
            case page(SourceBrowserRequest)
            case captcha(SourceCaptchaRequest)
            case openURL(SourceOpenURLRequest)
        }

        let id = UUID()
        let completion: (String?) -> Void
        let content: Content
    }

    private static var waiting: [Pending] = []
    private static var isShowingSheet = false
    /// The sheet on screen, for `withdraw`. Weak: its going away is what answers the script.
    private static var showingID: UUID?
    private static weak var showingHost: UIViewController?

    private static func presentNextIfIdle() {
        guard !isShowingSheet, !waiting.isEmpty else { return }
        let pending = waiting.removeFirst()
        guard let topVC = BookSourceFormLoginView.topViewController() else {
            pending.completion(nil)
            presentNextIfIdle()
            return
        }
        isShowingSheet = true
        // The awaiting script is blocked until this fires; the box guarantees it does,
        // including when the sheet is swiped away instead of dismissed by a button.
        let awaitBox = BrowserAwaitBox { answer in
            pending.completion(answer)
            Task { @MainActor in
                isShowingSheet = false
                showingID = nil
                presentNextIfIdle()
            }
        }
        // `topVC` weakly: a strong capture would form a presenter ⇄ presented cycle that
        // outlives dismissal, and the box's deinit is what releases the script when the
        // sheet goes away without a button tap.
        let finish: (String?) -> Void = { [weak topVC] answer in
            guard let topVC else { awaitBox.finish(answer); return }
            topVC.dismiss(animated: true) {
                awaitBox.finish(answer)
            }
        }
        let hostVC: UIViewController
        switch pending.content {
        case .page(let request):
            let userAgent = request.urlRequest?.value(forHTTPHeaderField: "User-Agent")
            hostVC = UIHostingController(
                rootView: JsBridgeBrowserView(
                    // The request's URL, not the source's string: `url,{options}` is not a URL.
                    urlString: request.urlRequest?.url?.absoluteString ?? request.url,
                    title: request.title,
                    initialHTML: request.html,
                    initialRequest: request.urlRequest,
                    userAgent: userAgent?.isEmpty == false ? userAgent : nil,
                    finishesWhenChallengeClears: request.awaitsResult,
                    onDismiss: finish
                )
            )
            // Phone-oriented login pages need the whole of a wide window (iPad, an unfolded
            // iPhone Duo); a nested form sheet can clip the submit controls below its fixed height.
            if topVC.traitCollection.horizontalSizeClass == .regular {
                hostVC.coversFullScreen()
            }
        case .captcha(let request):
            hostVC = UIHostingController(
                rootView: SourceCaptchaView(request: request, onFinish: finish)
            )
            hostVC.sheetPresentationController?.detents = [.medium(), .large()]
        case .openURL(let request):
            // An alert dismisses itself when a button is tapped, so its actions finish the box
            // directly; `finish` would dismiss `topVC`'s next presentation.
            hostVC = openURLAlert(request) { awaitBox.finish(nil) }
        }
        showingID = pending.id
        showingHost = hostVC
        topVC.present(hostVC, animated: true)
    }

    private static func openURLAlert(
        _ request: SourceOpenURLRequest, done: @escaping () -> Void
    ) -> UIAlertController {
        let title = request.sourceName.isEmpty
            ? localized("要開啟這個連結嗎？")
            : String(format: localized("「%@」要開啟連結"), request.sourceName)
        let alert = UIAlertController(
            title: title, message: request.url.absoluteString, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: localized("取消"), style: .cancel) { _ in done() })
        alert.addAction(UIAlertAction(title: localized("動作：開啟"), style: .default) { _ in
            UIApplication.shared.open(request.url) { opened in
                if !opened {
                    AppLogger.parse("⟐ openUrl: no app opened the link", context: [
                        "scheme": request.url.scheme ?? "",
                    ])
                }
            }
            done()
        })
        return alert
    }
}
