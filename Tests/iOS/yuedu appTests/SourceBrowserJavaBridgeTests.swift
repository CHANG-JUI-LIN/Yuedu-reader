import Foundation
import Testing
import WebKit
@testable import yuedu_app

@Suite("Source browser Java bridge", .serialized)
@MainActor
struct SourceBrowserJavaBridgeTests {
    @Test("WKWebView keeps java.ajax synchronous while native work completes asynchronously", .timeLimit(.minutes(1)))
    func webViewSynchronousAjax() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: JsBridgeBrowserRepresentable.sourcePageBootstrap(
                injectedJavaScript: "window.sourcePreloadRan=true;"
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let uiDelegate = SourceWebUIDelegate()
        var capturedPayload = ""
        uiDelegate.sourceBridgePromptHandler = { payload, completion in
            capturedPayload = payload
            // The production source runtime performs network work asynchronously.
            // Complete on a later main-queue turn to prove WebKit pauses only the
            // calling script and resumes it with a synchronous return value.
            DispatchQueue.main.async {
                completion(#"{"comments":[{"id":1}]}"#)
            }
        }
        let navigationDelegate = SourceBrowserNavigationWaiter()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = uiDelegate
        webView.navigationDelegate = navigationDelegate

        try await navigationDelegate.load(
            """
            <html><body><script>
            try {
              window.bridgeResult = window.java.ajax('https://example.com/comments');
            } catch (error) {
              window.bridgeResult = 'error:' + String(error);
            }
            </script></body></html>
            """,
            in: webView
        )

        let value = try await webView.evaluateJavaScript("window.bridgeResult") as? String
        #expect(value == #"{"comments":[{"id":1}]}"#)
        #expect(try await webView.evaluateJavaScript("window.sourcePreloadRan") as? Bool == true)
        let payloadData = try #require(capturedPayload.data(using: .utf8))
        let payload = try #require(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        #expect(payload["method"] as? String == "ajax")
        #expect(payload["arguments"] as? [String] == ["https://example.com/comments"])
    }

    @Test("browser-page upConfig updates the active sheet configuration")
    func browserPageUpConfig() throws {
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        var updatedJSON: String?
        var reply: String?
        coordinator.sourceConfigurationUpdateHandler = { updatedJSON = $0 }

        let payload = #"{"method":"upConfig","arguments":["{\"heightPercentage\":0.72,\"skipCollapsed\":true}"]}"#
        coordinator.handleSourceJavaPrompt(payload) { reply = $0 }

        #expect(reply == "")
        let json = try #require(updatedJSON)
        let parsed = SourceBrowserPresentationConfiguration(json: json)
        #expect(parsed.heightPercentage == 0.72)
        #expect(parsed.skipCollapsed)
    }
}

private final class SourceBrowserNavigationWaiter: NSObject, WKNavigationDelegate {
    private var completion: ((Result<Void, Error>) -> Void)?

    @MainActor
    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = { result in continuation.resume(with: result) }
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        completion?(result)
        completion = nil
    }
}
