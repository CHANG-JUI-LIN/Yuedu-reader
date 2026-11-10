import Foundation
import WebKit

/// The images and web fonts a source's unseen page would fetch, not fetched.
///
/// Images follow Legado: its `BackstageWebView` — the WebView behind `webView: true` URLs,
/// `java.webView` and resource sniffing — sets `blockNetworkImage = true` (legado-E
/// `BackstageWebView.kt:158`, MD3 `:141`); its pool turns images back on only for pages people
/// look at (`WebViewPool.kt:106`). A page's `load` event waits for every image, so a WebKit page
/// that loaded them finished much later than Legado's: 17k's chapter page (YCK 1330#54) took
/// 37 s to `didFinish`.
///
/// Fonts are a deliberate divergence (maintainer decision, 2026-11-10): Legado loads them. The
/// `load` event waits for a web font as it does for an image, and nothing here ever draws one —
/// the page is read as DOM text. cqzww's TOC page (YCK 1330#292) titles its header in a 3.85 MB
/// font: measured in the simulator, `load` came after 61 s on a cold start (past the 60 s
/// deadline), 6–11 s after that, and 0.8 s with fonts blocked. A source that decodes an
/// obfuscation font downloads the font file itself (`java.queryTTF`), not through this page.
///
/// A page whose text arrives after `load` is still read with it (`PageRequestDrain`). Pages a
/// person sees — the browser, login and verification pages — are other WebViews and keep their
/// images and fonts.
@MainActor
enum SourcePageResourceBlocking {
    static let identifier = "yuedu.source-page.block-network-images-and-fonts"
    /// Network images and fonts only, as `blockNetworkImage`: a `data:` image or font still loads.
    static let rules = #"[{"trigger":{"url-filter":"^https?://","resource-type":["image","font"]},"action":{"type":"block"}}]"#

    private static var compiled: WKContentRuleList?
    private static var compiling: Task<WKContentRuleList?, Never>?

    /// The compiled list, compiled once per launch. Nil only when WebKit refused to compile it,
    /// which is logged: pages then load their images and fonts, as before.
    static func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        if let compiling { return await compiling.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            guard let store = WKContentRuleListStore.default() else {
                AppLogger.parse("Source page resource blocking unavailable: no content rule list store", level: .error)
                return nil
            }
            do {
                return try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: rules
                )
            } catch {
                AppLogger.parse("Source page resource blocking rules failed to compile", error: error, level: .error)
                return nil
            }
        }
        compiling = task
        let list = await task.value
        compiled = list
        compiling = nil
        return list
    }

    /// Blocks network images and fonts in `controller`'s pages. WebKit keys the lists a
    /// controller holds by identifier, so installing it again on a reused WebView changes nothing.
    static func install(on controller: WKUserContentController) async {
        guard let list = await ruleList() else { return }
        controller.add(list)
    }
}
