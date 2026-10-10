import AVKit
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
    }

    /// `java.openVideoPlayer`: the system player, full screen, playing at once — legado-E's
    /// `VideoPlayerActivity`. Not queued with the sheets: nothing waits on it.
    static func presentVideo(_ request: URLRequest, title: String) {
        guard let url = request.url, let topVC = BookSourceFormLoginView.topViewController() else {
            AppLogger.parse("⟐ openVideoPlayer: nowhere to present", context: [:])
            return
        }
        AudioSessionActivator.activate(category: .playback, mode: .moviePlayback)
        let player = AVPlayer(playerItem: AVPlayerItem(
            asset: HeaderedMediaAsset.make(url: url, headers: request.allHTTPHeaderFields ?? [:])
        ))
        let controller = AVPlayerViewController()
        controller.player = player
        controller.title = title
        controller.modalPresentationStyle = .fullScreen
        topVC.present(controller, animated: true) { player.play() }
    }

    /// Shows `request`'s page. `completion` runs exactly once: with the page's HTML when the
    /// user confirms it (✓, or a Cloudflare challenge on it clearing), with nil when the page
    /// goes away any other way — ✕, a swipe, or nowhere to present it.
    static func present(_ request: SourceBrowserRequest, completion: @escaping (String?) -> Void) {
        waiting.append(Pending(completion: completion, content: .page(request)))
        presentNextIfIdle()
    }

    /// Shows `request`'s captcha. `completion` runs exactly once: with the code the user
    /// entered, or nil when the sheet goes away without one.
    static func presentCaptcha(_ request: SourceCaptchaRequest, completion: @escaping (String?) -> Void) {
        waiting.append(Pending(completion: completion, content: .captcha(request)))
        presentNextIfIdle()
    }

    private struct Pending {
        enum Content {
            case page(SourceBrowserRequest)
            case captcha(SourceCaptchaRequest)
        }

        let completion: (String?) -> Void
        let content: Content
    }

    private static var waiting: [Pending] = []
    private static var isShowingSheet = false

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
            // Phone-oriented login pages need the full iPad viewport; a nested form sheet
            // can clip the submit controls below its fixed height.
            if topVC.traitCollection.userInterfaceIdiom == .pad {
                hostVC.modalPresentationStyle = .fullScreen
            }
        case .captcha(let request):
            hostVC = UIHostingController(
                rootView: SourceCaptchaView(request: request, onFinish: finish)
            )
            hostVC.sheetPresentationController?.detents = [.medium(), .large()]
        }
        topVC.present(hostVC, animated: true)
    }
}
