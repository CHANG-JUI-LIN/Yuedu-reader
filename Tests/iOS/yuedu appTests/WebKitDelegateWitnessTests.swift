import Foundation
import Testing
import WebKit
@testable import yuedu_app

/// WebKit decides once, with `respondsToSelector:`, whether to call an optional delegate
/// method. Under strict concurrency a Swift method whose completion-handler type differs
/// from the SDK's (`WK_SWIFT_UI_ACTOR` → `@MainActor`) only "nearly matches" the
/// requirement: it is no longer the protocol witness, is no longer exposed to Objective-C,
/// and WebKit silently stops calling it — navigation interception and JS dialogs go dead
/// with a warning, not an error. These tests ask the class exactly what WebKit asks.
@Suite("WebKit delegate witnesses")
struct WebKitDelegateWitnessTests {
    private static let navigationAction = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
    private static let navigationActionWithPreferences =
        NSSelectorFromString("webView:decidePolicyForNavigationAction:preferences:decisionHandler:")
    private static let navigationResponse = NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")

    @Test("decidePolicyFor navigation action is exposed to WebKit", arguments: [
        ("LegadoHeadlessWebView", LegadoHeadlessWebView.self as NSObject.Type),
        ("JsBridgeBrowserRepresentable.Coordinator", JsBridgeBrowserRepresentable.Coordinator.self),
        ("RSSArticleWebReaderView.Coordinator", RSSArticleWebReaderView.Coordinator.self),
    ])
    func decidePolicyForNavigationAction(name: String, type: NSObject.Type) {
        #expect(type.instancesRespond(to: Self.navigationAction), "\(name)")
    }

    @Test("decidePolicyFor navigation action with preferences is exposed to WebKit", arguments: [
        ("BrowserState", BrowserState.self as NSObject.Type),
        ("SourceLoginWebViewRepresentable.Coordinator", SourceLoginWebViewRepresentable.Coordinator.self),
    ])
    func decidePolicyForNavigationActionWithPreferences(name: String, type: NSObject.Type) {
        #expect(type.instancesRespond(to: Self.navigationActionWithPreferences), "\(name)")
    }

    @Test("decidePolicyFor navigation response is exposed to WebKit")
    func decidePolicyForNavigationResponse() {
        #expect(WebViewFetcher.instancesRespond(to: Self.navigationResponse))
    }

    @Test("JS alert, confirm and prompt panels are exposed to WebKit", arguments: [
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
    ])
    func javaScriptPanels(selector: String) {
        #expect(SourceWebUIDelegate.instancesRespond(to: NSSelectorFromString(selector)))
    }
}
