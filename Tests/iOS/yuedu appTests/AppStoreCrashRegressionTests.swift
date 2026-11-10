import Foundation
import JavaScriptCore
import SwiftUI
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

@Suite("App Store crash regressions", .serialized)
struct AppStoreCrashRegressionTests {
    @Test("a JS-held DOM cannot alias an extractor's thread-local document")
    func javascriptDOMDoesNotEscapeThreadCache() throws {
        let html = "<html><body><p id='held' data-owner='original'>Held text</p>"
            + String(repeating: "<div>Cacheable page content</div>", count: 200) + "</body></html>"
        let extractorDocument = try JsoupDocumentCache.current.document(for: html, baseURL: "")
        let context = try #require(JSContext())
        let base = try #require(JSValue(undefinedIn: context))
        let bridge = LegadoJsoupBridge()
        let heldByJavaScript = bridge.parse(html, base)

        // A serial JS queue is not pinned to an OS thread. A wrapper may outlive this
        // call and be queried on another worker while the extractor reuses this cache.
        let nativeNode = try #require(extractorDocument.select("#held").first())
        try nativeNode.attr("data-owner", "extractor")
        try nativeNode.text("Changed by the extractor")
        let jsNode = try #require(heldByJavaScript.select("#held").first)
        #expect(jsNode.attr("data-owner") == "original")
        #expect(jsNode.text() == "Held text")
        #expect(bridge.parse(html, base).select("#held").first?.text() == "Held text")
    }

    @Test("source JS keeps its parsed document alive across later evaluations and cache eviction")
    func javascriptKeepsParsedDocument() {
        let engine = JSCoreEngine()
        let html = "<html><body><p id='held'>Held text</p>"
            + String(repeating: "<div>Page content</div>", count: 300) + "</body></html>"
        #expect(engine.evaluate("var heldDocument = org.jsoup.Jsoup.parse(result); heldDocument.select('#held').text();", result: html) == "Held text")
        #expect(engine.evaluate("org.jsoup.Jsoup.parse(result).select('#other').text();", result: html.replacingOccurrences(of: "id='held'", with: "id='other'")) == "Held text")
        #expect(engine.evaluate("heldDocument.select('#held').text();") == "Held text")
    }

    @Test("download options render empty, single and terminal chapter ranges")
    @MainActor
    func downloadRangeBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let bookID = UUID()
        func view(current: Int, total: Int) -> some View {
            ReaderDownloadOptionsView(
                bookId: bookID, bookTitle: "Download range", currentChapterIndex: current, totalChapters: total,
                onStart: { _, _ in }, onPause: {}, onResume: {}, onSkipFailed: {}, onRemove: {}, onClose: {}
            ).environmentObject(store)
        }
        // Construct the real body for each opening boundary. The old body created
        // Slider(1...1, step: 1) and trapped in Normalizing before any interaction.
        for (current, total, hasSlider) in [(0, 100, true), (0, 0, false), (0, 1, false), (99, 100, false), (100, 100, false), (-1, -1, false)] {
            let host = UIHostingController(rootView: view(current: current, total: total))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            #expect(sliders(in: host.view).isEmpty == !hasSlider)
        }
    }

    @Test("parallel CSS reads of identical HTML cannot share mutable SwiftSoup indexes")
    func identicalHTMLOnConcurrentThreads() {
        let rows = (0..<100).map { "<div CLASS='entry' data-index='\($0)'><a href='/\($0)'>Chapter \($0)</a></div>" }.joined()
        let html = "<html><body>\(rows)</body></html>"
        #expect(html.count > 4096) // Exercise cached page documents, not uncached fragments.
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                let extractor = CssExtractor()
                for _ in 0..<4 {
                    let links = try extractor.extractList(from: html, rule: ".entry a@href", baseURL: "https://example.com")
                    // As written, as Legado's AnalyzeByJSoup reads an attribute.
                    #expect(links == (0..<100).map { "/\($0)" })
                    let indices = try extractor.extractList(from: html, rule: "div.entry[data-index]@data-index", baseURL: "")
                    #expect(indices == (0..<100).map(String.init))
                }
            } catch {
                Issue.record(error)
            }
        }
    }

    @MainActor
    private func sliders(in view: UIView) -> [UISlider] {
        (view as? UISlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
    }
}
