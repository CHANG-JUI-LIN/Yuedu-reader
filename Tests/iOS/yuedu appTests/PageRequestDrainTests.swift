import Foundation
import Testing
@testable import yuedu_app

/// A source's WebView page is read once the requests it has in flight are answered
/// (`PageRequestDrain`), after Legado's one second: 17k's chapter page (YCK 1330#54) empties its
/// text and rebuilds it from chained requests that can answer past that second, and was read
/// empty.
@Suite("WebView reads wait for the page's own requests", .serialized)
@MainActor
struct PageRequestDrainTests {
    nonisolated private static let late = "后来才到的正文"
    nonisolated private static let early = "马上就有的正文"

    nonisolated private static func page(_ script: String, body: String = "占位") -> String {
        """
        <html><head><meta charset="utf-8"></head><body><div id="content">\(body)</div>
        <script>\(script)</script></body></html>
        """
    }

    nonisolated private static let fill = "function fill(t) { document.getElementById('content').innerHTML = '<p>' + t + '</p>'; }"

    /// `/xhr` and `/fetch` empty the page and refill it from `/data` (2.5 s); `/chain` does it
    /// from two requests one after the other (1.2 s each), as 17k does; `/static` asks for
    /// nothing; `/hang` shows its text at once and holds a request that is never answered.
    nonisolated private static func server() throws -> LoopbackPageServer {
        try LoopbackPageServer { path in
            switch path.split(separator: "/").first.map(String.init) {
            case "xhr":
                return .html(page(fill + """
                    document.getElementById('content').innerHTML = '';
                    var x = new XMLHttpRequest(); x.open('GET', '/data/xhr');
                    x.onload = function () { fill(x.responseText); }; x.send();
                    """))
            case "fetch":
                return .html(page(fill + """
                    document.getElementById('content').innerHTML = '';
                    fetch('/data/fetch').then(function (r) { return r.text(); }).then(fill);
                    """))
            case "chain":
                return .html(page(fill + """
                    document.getElementById('content').innerHTML = '';
                    var a = new XMLHttpRequest(); a.open('GET', '/step/1');
                    a.onreadystatechange = function () {
                      if (a.readyState !== 4) return;
                      var b = new XMLHttpRequest(); b.open('GET', '/step/2');
                      b.onload = function () { fill(b.responseText); }; b.send();
                    };
                    a.send();
                    """))
            case "static":
                return .html(page("", body: "<p>\(early)</p>"))
            case "hang":
                return .html(page("var x = new XMLHttpRequest(); x.open('GET', '/never'); x.send();",
                                  body: "<p>\(early)</p>"))
            case "data":
                return .text(late, after: .milliseconds(2500))
            case "step":
                return .text(late, after: .milliseconds(1200))
            default:
                return .never
            }
        }
    }

    @Test("an XHR that answers after the read's second is waited for", .timeLimit(.minutes(1)))
    func xhrIsWaitedFor() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "xhr", relativeTo: base)), timeout: 30)
        #expect(html.contains(Self.late))
    }

    @Test("a fetch and the body read after it are waited for", .timeLimit(.minutes(1)))
    func fetchIsWaitedFor() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "fetch", relativeTo: base)), timeout: 30)
        #expect(html.contains(Self.late))
    }

    @Test("a request the previous answer starts is waited for too", .timeLimit(.minutes(1)))
    func chainedRequestsAreWaitedFor() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "chain", relativeTo: base)), timeout: 30)
        #expect(html.contains(Self.late))
        #expect(server.requests(startingWith: "/step/2") == 1)
    }

    @Test("the headless WebView waits for the page's requests", .timeLimit(.minutes(1)))
    func headlessWebViewWaits() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let page = try #require(URL(string: "chain", relativeTo: base)).absoluteString
        let result = await LegadoHeadlessWebView.load(html: nil, url: page, js: nil, userAgent: nil, timeout: 30)
        #expect(result.failure == nil)
        #expect(result.body.contains(Self.late))
    }

    @Test("a page with nothing in flight is read without waiting", .timeLimit(.minutes(1)))
    func idlePageIsNotHeld() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let started = ContinuousClock.now
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "static", relativeTo: base)), timeout: 30)
        let elapsed = ContinuousClock.now - started
        print("⏱ idle page read after \(elapsed) (jsWait \(AppConfig.webViewJSRenderWait) s)")
        #expect(html.contains(Self.early))
        #expect(elapsed < .seconds(AppConfig.webViewJSRenderWait) + .milliseconds(1500))
    }

    @Test("a request that never ends holds the read only up to the limit", .timeLimit(.minutes(1)))
    func neverEndingRequestIsCapped() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let started = ContinuousClock.now
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "hang", relativeTo: base)), timeout: 30)
        let elapsed = ContinuousClock.now - started
        print("⏱ page holding a request read after \(elapsed)")
        #expect(html.contains(Self.early))
        #expect(elapsed >= .milliseconds(PageRequestDrain.limitMs))
        #expect(elapsed < .milliseconds(PageRequestDrain.limitMs) + .seconds(5))
    }
}
