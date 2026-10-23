import Combine
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

    /// #21/#54/#55: the loading overlay came off at commit, and a 段評 page whose script waited on
    /// `java.ajax` showed WebKit's white until it returned. It now stays until the page is drawn.
    @Test("the loading overlay stays through a page's synchronous java.ajax until it is drawn", .timeLimit(.minutes(1)))
    func overlayWaitsForFirstPaint() async throws {
        let bridge = JsBridgeBrowserBridge()
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        coordinator.bridge = bridge
        let log = EventLog()
        let phases = bridge.$phase.sink { phase in
            switch phase {
            case .committed: log.events.append("committed")
            case .painted: log.events.append("painted")
            case .finished: log.events.append("finished")
            case .loading, .failed: break
            }
        }
        defer { phases.cancel() }

        let resources = HeldImageSchemeHandler(page: """
            <html><body><img src="yuedu-test://held.gif"><p id="comments"></p><script>
            document.getElementById('comments').textContent = window.java.ajax('https://example.com/comments');
            </script></body></html>
            """)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: "yuedu-test")
        configuration.userContentController.addUserScript(WKUserScript(
            source: JsBridgeBrowserRepresentable.sourcePageBootstrap(injectedJavaScript: ""),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addScriptMessageHandler(
            coordinator, contentWorld: .defaultClient,
            name: JsBridgeBrowserRepresentable.Coordinator.firstPaintMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: JsBridgeBrowserRepresentable.Coordinator.firstPaintScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        let uiDelegate = SourceWebUIDelegate()
        uiDelegate.sourceBridgePromptHandler = { _, completion in
            // A comments request that takes longer than a few frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    log.events.append("ajax")
                    completion("本段的評論")
                }
            }
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.uiDelegate = uiDelegate
        webView.navigationDelegate = coordinator

        // Frames come round only for a web view on screen.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        webView.load(URLRequest(url: try #require(URL(string: "yuedu-test://page.html"))))
        // The image holds the load open: the page is drawn before it finishes.
        for await phase in bridge.$phase.values where phase == .painted || phase == .finished { break }
        #expect(log.events == ["committed", "ajax", "painted"])
        #expect(try await webView.evaluateJavaScript("document.getElementById('comments').textContent") as? String == "本段的評論")

        resources.releaseImage()
        for await phase in bridge.$phase.values where phase == .finished { break }
        #expect(log.events == ["committed", "ajax", "painted", "finished"])
    }

    @Test("a first paint counts only for the page that committed")
    func firstPaintOnlyAfterCommit() async {
        let bridge = JsBridgeBrowserBridge()
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        coordinator.bridge = bridge
        // After the phase changes queued before it.
        func settle() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        // The last page's paint, posted as the next one started loading.
        coordinator.setPhase(.loading)
        coordinator.setPhase(.painted)
        await settle()
        #expect(bridge.phase == .loading)

        // A small page that finished before its frames came round.
        coordinator.setPhase(.committed)
        coordinator.setPhase(.finished)
        coordinator.setPhase(.painted)
        await settle()
        #expect(bridge.phase == .finished)
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

@MainActor
private final class EventLog {
    var events: [String] = []
}

/// Serves `page` at once and holds every other resource until `releaseImage()`.
@MainActor
private final class HeldImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let page: String
    private var held: [any WKURLSchemeTask] = []

    init(page: String) {
        self.page = page
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        guard url.absoluteString.hasSuffix(".html") else {
            held.append(urlSchemeTask)
            return
        }
        let data = Data(page.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html",
                                             expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held.removeAll { $0 === urlSchemeTask }
    }

    func releaseImage() {
        for task in held {
            guard let url = task.request.url else { continue }
            task.didReceive(URLResponse(url: url, mimeType: "image/gif", expectedContentLength: 0, textEncodingName: nil))
            task.didFinish()
        }
        held.removeAll()
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
