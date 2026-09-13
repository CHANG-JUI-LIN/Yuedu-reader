import Foundation
import Network
import Testing
import WebKit
@testable import yuedu_app

@Suite("Source browser authentication", .serialized)
@MainActor
struct SourceBrowserAuthenticationTests {
    private func source() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "source-browser-test-\(UUID().uuidString)"
        source.bookSourceName = "Shushan authentication fixture"
        source.header = #"@js:JSON.stringify({'X-Api-Key':getSecretKey(),'X-Novel-Token':'SHUSAN_READ_2025'})"#
        source.jsLib = "function getSecretKey(){return java.base64Encode(source.getLoginHeader());}"
        return source
    }

    @Test("first browser load carries the login changed by the click action", .timeLimit(.minutes(1)))
    func authenticatedFirstLoad() async throws {
        let server = try ReviewAuthenticationServer()
        let url = try await server.start()
        defer { server.stop() }
        let source = source()
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }
        LoginManager.shared.storeLoginHeader(sourceUrl: source.bookSourceUrl, raw: "old-fixture-token")
        let script = "source.putLoginHeader('fresh-fixture-token');java.startBrowser('\(url.absoluteString)','Comments')"
        let target = ReaderHTMLUtilities.ReviewTarget(
            url: "", title: "Comments", sourceJS: script, sourceURL: source.bookSourceUrl
        )
        let resolved = try await LegadoReviewActionRunner.shared.resolve(target, source: source)
        let request = try #require(resolved.browserRequest)
        #expect(resolved.sourceURL == source.bookSourceUrl)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == Data("fresh-fixture-token".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "X-Novel-Token") == "SHUSAN_READ_2025")
        #expect(!resolved.requiresSourceJS)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let waiter = ReviewAuthenticationNavigationWaiter()
        webView.navigationDelegate = waiter
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        // Reproduce the old behavior using the same URL without the prepared request.
        try await waiter.load {
            coordinator.loadInitial(urlString: resolved.url, html: nil, in: webView)
        }
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "401 - user does not exist")
        try await waiter.load {
            coordinator.loadInitial(urlString: resolved.url, html: nil, request: request, in: webView)
        }
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "Comments")
        #expect(server.authenticatedCount == 1)
        // A prepared request must not be reused for an unrelated navigation.
        try await waiter.load {
            coordinator.loadInitial(urlString: url.appendingPathComponent("other").absoluteString,
                                    html: nil, request: request, in: webView)
        }
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "401 - user does not exist")
        #expect(server.authenticatedCount == 1)
    }

    @Test("login rotation, source isolation and JSON login headers use parser precedence")
    func currentCredentialsAndIsolation() throws {
        let first = source()
        let second = source()
        defer {
            LoginManager.shared.clearLogin(sourceUrl: first.bookSourceUrl)
            LoginManager.shared.clearLogin(sourceUrl: second.bookSourceUrl)
        }
        let bridge = ModernParserBridge(source: first)
        let url = "https://example.com/qm_comment"
        LoginManager.shared.storeLoginHeader(sourceUrl: first.bookSourceUrl, raw: "first-fixture-token")
        #expect(bridge.sourceBrowserRequest(urlString: url)?.value(forHTTPHeaderField: "X-Api-Key") == Data("first-fixture-token".utf8).base64EncodedString())
        LoginManager.shared.storeLoginHeader(sourceUrl: first.bookSourceUrl, raw: "second-fixture-token")
        #expect(bridge.sourceBrowserRequest(urlString: url)?.value(forHTTPHeaderField: "X-Api-Key") == Data("second-fixture-token".utf8).base64EncodedString())
        LoginManager.shared.storeLoginHeaders(sourceUrl: second.bookSourceUrl, headers: ["X-Api-Key": "other-source", "Authorization": "Bearer fixture"])
        let other = try #require(ModernParserBridge(source: second).sourceBrowserRequest(urlString: url))
        #expect(other.value(forHTTPHeaderField: "X-Api-Key") == "other-source")
        #expect(other.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(bridge.sourceBrowserRequest(urlString: "file:///tmp/review") == nil)
    }

    @Test(
        "live Shushan source opens Qimao comments with its current login",
        .enabled(if: liveValue("SHUSHAN_LIVE_API_KEY") != nil),
        .timeLimit(.minutes(1))
    )
    func liveShushanComments() async throws {
        let apiKey = try #require(Self.liveValue("SHUSHAN_LIVE_API_KEY"))
        let path = try #require(Self.liveValue("SHUSHAN_LIVE_SOURCE_PATH"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var source = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        source.bookSourceUrl = "shushan-live-test-\(UUID().uuidString)"
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }
        LoginManager.shared.storeLoginHeader(sourceUrl: source.bookSourceUrl, raw: apiKey)
        let url = "https://v1.vossc.com/qm_comment?item_id=5407075&book_id=141794&paragraph_id=253fac22"
        let raw = "<p>Paragraph<comment count=\"6\" onPress=\"java.showReadingBrowser('\(url)','七猫段评')\"></p>"
        let html = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(raw, reviewContext: .init(sourceName: source.bookSourceName, sourceURL: source.bookSourceUrl))
        let paragraph = try #require(ReaderHTMLUtilities.reviewParagraphs(fromHTML: html, excludingLeadingTitle: "").first)
        let href = try #require(paragraph.reviewHref)
        let target = try #require(ReaderHTMLUtilities.reviewTarget(fromHref: href))
        let resolved = try await LegadoReviewActionRunner.shared.resolve(target, source: source)
        let request = try #require(resolved.browserRequest)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let waiter = ReviewAuthenticationNavigationWaiter()
        webView.navigationDelegate = waiter
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        try await waiter.load {
            coordinator.loadInitial(urlString: resolved.url, html: nil, request: request, in: webView)
        }
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "评论")
        let countsJSON = try await webView.callAsyncJavaScript(
            """
            const response = await fetch('/paras/proxy_qmidea?action=paragraph_first&book_id=141794&item_id=5407075&paragraph_id=253fac22');
            const body = await response.json();
            return JSON.stringify({time: body.data.time_zone.comment_list.length, hot: body.data.hot_zone.comment_list.length});
            """, arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let countsData = try #require(countsJSON?.data(using: .utf8))
        let counts = try #require(JSONSerialization.jsonObject(with: countsData) as? [String: Int])
        #expect((counts["time"] ?? 0) + (counts["hot"] ?? 0) > 0, "Live comment counts: \(counts)")
    }

    nonisolated private static func liveValue(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    @Test("native Shushan markers retain source identity without cached credentials")
    func nativeMarkerAuthentication() async throws {
        let source = source()
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }
        let raw = #"<p>Paragraph<comment count="6" onPress="java.showReadingBrowser('https://example.com/qm_comment?book_id=141794&amp;paragraph_id=253fac22','七猫段评')"></p>"#
        let html = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(raw, reviewContext: .init(sourceName: source.bookSourceName, sourceURL: source.bookSourceUrl))
        let paragraph = try #require(ReaderHTMLUtilities.reviewParagraphs(fromHTML: html, excludingLeadingTitle: "").first)
        let href = try #require(paragraph.reviewHref)
        let target = try #require(ReaderHTMLUtilities.reviewTarget(fromHref: href))
        #expect(target.sourceURL == source.bookSourceUrl)
        #expect(target.requiresSourceJS)
        #expect(target.browserRequest == nil)
        LoginManager.shared.storeLoginHeader(sourceUrl: source.bookSourceUrl, raw: "fresh-fixture-token")
        let resolved = try await LegadoReviewActionRunner.shared.resolve(target, source: source)
        #expect(resolved.url == "https://example.com/qm_comment?book_id=141794&paragraph_id=253fac22")
        #expect(resolved.browserRequest?.value(forHTTPHeaderField: "X-Api-Key") == Data("fresh-fixture-token".utf8).base64EncodedString())
    }
}

@MainActor
private final class ReviewAuthenticationNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ error: Error?) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

/// Real HTTP/WKWebView transport: authentication is checked by the receiving server.
private final class ReviewAuthenticationServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ReviewAuthenticationServer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private var accepted = 0
    var authenticatedCount: Int { lock.withLock { accepted } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    self.finish(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/qm_comment")!))
                case .failed(let error): self.finish(.failure(error))
                case .cancelled: self.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var data = data
            if let chunk { data.append(chunk) }
            guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
                if error == nil && !done { self.receive(connection, data: data) } else { connection.cancel() }
                return
            }
            let headers = text.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { headers, line in
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let authenticated = headers["x-api-key"] == Data("fresh-fixture-token".utf8).base64EncodedString()
                && headers["x-novel-token"] == "SHUSAN_READ_2025"
            if authenticated { self.lock.withLock { self.accepted += 1 } }
            let title = authenticated ? "Comments" : "401 - user does not exist"
            let status = authenticated ? "200 OK" : "401 Unauthorized"
            let body = "<html><head><title>\(title)</title></head><body>\(title)</body></html>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
