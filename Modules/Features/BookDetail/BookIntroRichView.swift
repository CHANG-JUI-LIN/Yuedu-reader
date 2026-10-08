import SwiftUI
import UIKit
import WebKit

// MARK: - Rich introduction (`<usehtml>` / `<useweb>`)

/// Renders a `<usehtml>` fragment or a `<useweb>` page with WebKit, so its CSS applies
/// in full — legado-E shows `<useweb>` in a WebView and MD3 both modes. The view
/// reports its content height and never scrolls itself; the detail page scrolls.
///
/// A fragment's `<button>名稱@onclick:腳本</button>` and `url,{"click":…}` images run
/// their scripts through `onAction`, as legado-E and MD3 do on `<usehtml>` only: a
/// `<useweb>` page is shown as written.
struct BookIntroWebView: UIViewRepresentable {
    enum Mode {
        case fragment
        case page
    }

    let markup: String
    let mode: Mode
    let baseURL: URL?
    @Binding var contentHeight: CGFloat
    /// Runs a button's or image's script; nil leaves them inert.
    var onAction: ((BookIntroAction) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(contentHeight: $contentHeight) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Coordinator.heightMessage)
        configuration.userContentController.add(context.coordinator, name: Coordinator.actionMessage)
        for script in [Coordinator.heightScript, Coordinator.actionScript] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAction = onAction
        let document = documentHTML(traits: webView.traitCollection, coordinator: context.coordinator)
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: baseURL)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in [Coordinator.heightMessage, Coordinator.actionMessage] {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    /// A `<usehtml>` fragment inherits the page's text style, as MD3 wraps it; a
    /// `<useweb>` page that brings its own document is loaded as written.
    private func documentHTML(traits: UITraitCollection, coordinator: Coordinator) -> String {
        if mode == .page, markup.range(of: "<html", options: .caseInsensitive) != nil {
            return markup
        }
        let body = mode == .fragment ? coordinator.interactiveFragment(for: markup).html : markup
        let resolvedTraits = traits.modifyingTraits {
            $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
        }
        let textColor = UIColor(DSColor.textPrimary).resolvedColor(with: resolvedTraits).cssHex
        let linkColor = UIColor(DSColor.accent).resolvedColor(with: resolvedTraits).cssHex
        let buttonTextColor = UIColor(DSColor.textOnAccent).resolvedColor(with: resolvedTraits).cssHex
        let fontSize = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        html,body{margin:0;padding:0;background:transparent;}
        body{color:\(textColor);font:-apple-system-subheadline;font-size:\(fontSize)px;
        line-height:1.5;word-wrap:break-word;-webkit-text-size-adjust:none;}
        a{color:\(linkColor);} img{max-width:100%;height:auto;}
        .\(BookIntroInteractiveFragment.buttonClass){-webkit-appearance:none;appearance:none;border:0;
        border-radius:8px;margin:4px 8px 4px 0;padding:4px 10px;background:\(linkColor);
        color:\(buttonTextColor);font:inherit;font-size:0.9em;font-weight:600;}
        [\(BookIntroInteractiveFragment.actionAttribute)]{cursor:pointer;}
        </style></head><body>\(body)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessage = "yueduIntroHeight"
        /// Reports the document height now and whenever layout changes it (images
        /// arriving, fonts loading).
        static let heightScript = """
        (function(){
          function post(){ window.webkit.messageHandlers.\(heightMessage).postMessage(
            Math.ceil(document.documentElement.scrollHeight)); }
          new ResizeObserver(post).observe(document.documentElement);
          window.addEventListener('load', post); post();
        })();
        """

        static let actionMessage = "yueduIntroAction"
        /// Sends the index of the button or image the reader tapped.
        static let actionScript = """
        (function(){
          var attribute = '\(BookIntroInteractiveFragment.actionAttribute)';
          document.addEventListener('click', function(event){
            var element = event.target.closest('[' + attribute + ']');
            if (!element) { return; }
            event.preventDefault();
            window.webkit.messageHandlers.\(actionMessage).postMessage(element.getAttribute(attribute));
          }, true);
        })();
        """

        @Binding var contentHeight: CGFloat
        var loadedDocument: String?
        var onAction: ((BookIntroAction) -> Void)?
        /// Parsed once per intro rather than on every update.
        private var parsedMarkup: String?
        private var parsedFragment = BookIntroInteractiveFragment(html: "", actions: [])

        func interactiveFragment(for markup: String) -> BookIntroInteractiveFragment {
            if parsedMarkup != markup {
                parsedMarkup = markup
                parsedFragment = BookIntroInteractiveFragment(fragment: markup)
            }
            return parsedFragment
        }

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case Self.heightMessage:
                guard let height = (message.body as? NSNumber).map({ CGFloat(truncating: $0) }),
                      height > 0, abs(height - contentHeight) > 0.5 else { return }
                contentHeight = height
            case Self.actionMessage:
                guard let index = (message.body as? String).flatMap({ Int($0) }),
                      parsedFragment.actions.indices.contains(index) else { return }
                onAction?(parsedFragment.actions[index])
            default:
                break
            }
        }

        /// The intro's own document loads in place; a link the reader taps opens in
        /// the system browser rather than replacing the intro.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}

private extension UIColor {
    var cssHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%d,%d,%d,%.3f)",
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()), alpha
        )
    }
}

// MARK: - Running intro scripts

/// One tap on a 簡介 button or image, with the book and source its script runs against.
struct BookIntroActionRequest: Identifiable, Equatable {
    let id = UUID()
    let action: BookIntroAction
    let source: BookSource
    let book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot
    let runtimeVariables: [String: String]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// Runs the 簡介 script in `request` and shows what it asks for: toasts, a page it
    /// builds, its error, and — for `java.refreshBookInfo()` — the detail page's reload.
    func bookIntroActions(
        _ request: Binding<BookIntroActionRequest?>,
        onRefresh: @escaping () async -> Void
    ) -> some View {
        modifier(BookIntroActionHost(request: request, onRefresh: onRefresh))
    }
}

private struct BookIntroActionHost: ViewModifier {
    @Binding var request: BookIntroActionRequest?
    let onRefresh: () async -> Void

    @State private var page: ReaderHTMLUtilities.ReviewTarget?
    @State private var failure: Failure?

    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) {
                guard let request else { return }
                let outcome = await LegadoReviewActionRunner.shared.runIntroAction(
                    request.action,
                    book: request.book,
                    runtimeVariables: request.runtimeVariables,
                    source: request.source,
                    presentToast: { BookSourceFormLoginView.presentToastAlert(message: $0) }
                )
                if let message = outcome.errorMessage {
                    failure = Failure(name: request.action.displayName, message: message)
                }
                if let target = outcome.page {
                    // A script that toasts and then opens its page (光遇聚合's 书籍讨论)
                    // would otherwise ask for the sheet while the toast holds the presenter.
                    BookSourceFormLoginView.dismissToastAlert { page = target }
                }
                if outcome.refreshesBook {
                    await onRefresh()
                }
                self.request = nil
            }
            .sheet(item: $page) { target in
                LegadoReviewBrowserView(target: target) { _ in page = nil }
                    .presentationDetents([.medium, .large])
            }
            .alert(
                localized("來源配置腳本錯誤"),
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button(localized("好"), role: .cancel) {}
            } message: { failure in
                Text(verbatim: "\(failure.name)\n\(failure.message)")
            }
    }
}
