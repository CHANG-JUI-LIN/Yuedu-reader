import Foundation
import Testing
@testable import yuedu_app

/// A source's unseen page fetches no network image, as Legado's `BackstageWebView`
/// (`blockNetworkImage = true`), and no network font (a deliberate divergence): the page's
/// `didFinish` waited for both, and with it the read — 17k's WebView chapter page (YCK 1330#54)
/// took 37 s on its images, cqzww's TOC page (YCK 1330#292) 61 s on a 3.85 MB header font.
@Suite("Source pages load without their images and fonts", .serialized)
@MainActor
struct SourcePageResourceBlockingTests {
    nonisolated private static let text = "看不见图也没有字体的正文"
    nonisolated private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// `/page` shows `/pic.png` and sets its text in `/slow.ttf`, each answering after 6 s, and
    /// shows a `data:` image, which still draws.
    nonisolated private static func server() throws -> LoopbackPageServer {
        try LoopbackPageServer { path in
            if path.hasPrefix("/pic") { return .body(png, type: "image/png", after: .seconds(6)) }
            if path.hasPrefix("/slow") { return .body(Data(count: 2048), type: "font/ttf", after: .seconds(6)) }
            return .html("""
                <html><head><meta charset="utf-8">
                <style>@font-face { font-family: 'slow'; src: url('/slow.ttf') format('truetype'); }
                #content { font-family: 'slow'; }</style></head><body>
                <img src="/pic.png"><img id="inline" src="data:image/png;base64,\(png.base64EncodedString())">
                <div id="content"><p>\(text)</p></div></body></html>
                """)
        }
    }

    @Test("WebViewFetcher reads a page without fetching its image or font", .timeLimit(.minutes(1)))
    func webViewFetcherSkipsImagesAndFonts() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let started = ContinuousClock.now
        let html = try await WebViewFetcher.shared.fetchHTML(url: try #require(URL(string: "page", relativeTo: base)), timeout: 30)
        let elapsed = ContinuousClock.now - started
        print("⏱ WebViewFetcher page with a 6 s image and font: \(elapsed)")
        #expect(html.contains(Self.text))
        #expect(server.requests(startingWith: "/pic") == 0, "the page's image was requested")
        #expect(server.requests(startingWith: "/slow") == 0, "the page's font was requested")
        #expect(elapsed < .seconds(5), "the page waited for its image or font: \(elapsed)")
    }

    @Test("the headless WebView reads a page without fetching its image or font", .timeLimit(.minutes(1)))
    func headlessWebViewSkipsImagesAndFonts() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let page = try #require(URL(string: "page", relativeTo: base)).absoluteString
        let started = ContinuousClock.now
        let result = await LegadoHeadlessWebView.load(html: nil, url: page, js: nil, userAgent: nil, timeout: 30)
        let elapsed = ContinuousClock.now - started
        print("⏱ headless WebView page with a 6 s image and font: \(elapsed)")
        #expect(result.failure == nil)
        #expect(result.body.contains(Self.text))
        #expect(server.requests(startingWith: "/pic") == 0, "the page's image was requested")
        #expect(server.requests(startingWith: "/slow") == 0, "the page's font was requested")
        #expect(elapsed < .seconds(5), "the page waited for its image or font: \(elapsed)")
    }

    @Test("a data: image still draws")
    func inlineImageStillDraws() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let page = try #require(URL(string: "page", relativeTo: base)).absoluteString
        let result = await LegadoHeadlessWebView.load(
            html: nil, url: page,
            js: "(function(){ var i = document.getElementById('inline'); return String(i.complete && i.naturalWidth > 0); })()",
            userAgent: nil, timeout: 30
        )
        #expect(result.body == "true")
    }
}
