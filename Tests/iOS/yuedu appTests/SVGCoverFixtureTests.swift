import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct SVGCoverFixtureTests {
    static func timeout<T: Sendable>(nanos: UInt64, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    struct TimeoutError: Error {}

    /// Engine-level: an empty (SVG-only) first chapter under browserForced must
    /// NOT fall back to legacy and must NOT livelock — the browser engine
    /// publishes a TERMINAL diagnostic page (exactly 1 page, effectiveEngine
    /// stays browser), and position queries never re-ensure the session.
    @Test func emptyCoverPublishesDiagnosticAndNeverRelayouts() async throws {
        let oldMode = BrowserLayoutFeature.mode
        BrowserLayoutFeature.mode = .browserForced
        defer { BrowserLayoutFeature.mode = oldMode }

        let chapter = MockBrowserLayoutResource.Chapter(
            title: "cover", href: "c0.xhtml",
            html: "<html><body><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect width=\"100\" height=\"100\"/></svg></body></html>",
            css: []
        )
        let chapter2 = MockBrowserLayoutResource.Chapter(
            title: "ch1", href: "c1.xhtml",
            html: "<html><body><p>First real page of chapter one.</p></body></html>",
            css: []
        )
        let resource = MockBrowserLayoutResource(chapters: [chapter, chapter2])
        let builder = MockAttributedStringBuilder(texts: ["cover", "ch1"])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)"))
        let settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings)
        await engine.start(renderSize: CGSize(width: 390, height: 844), bookId: "t")

        // Spine 0 (empty SVG): the BROWSER engine owns the outcome — choice is
        // browser (never legacy), state is a terminal unsupported diagnostic,
        // and the diagnostic chapter counts as exactly ONE page.
        #expect(engine.choice(for: 0)?.isBrowser == true, "forced mode must never fall back to legacy")
        let state = engine.testChapterLayoutStates[0]
        guard case .unsupportedDiagnostic(let page) = state else {
            Issue.record("expected unsupportedDiagnostic state, got \(String(describing: state))")
            return
        }
        #expect(page.reason == .imageOnlyDocument)
        #expect(engine.totalPages >= 1)

        // The diagnostic page is a REAL browser page VC — not a placeholder
        // (which would re-trigger ensure) and not a legacy page.
        let atIndexVC = engine.pageViewController(at: 0)
        #expect(atIndexVC is BrowserForcedDiagnosticViewController)
        let positionVC = engine.pageViewController(for: .chapterStart(0))
        #expect(positionVC is BrowserForcedDiagnosticViewController)

        // Session-ensure seal: exactly ONE session for (generation 0, spine 0),
        // and 100 position queries must not create more (the livelock).
        #expect(engine.testSessionEnsureCounts["0:0"] == 1, "sessionEnsure must run exactly once")
        for _ in 0..<100 {
            _ = engine.pageViewController(for: .chapterStart(0))
        }
        #expect(engine.testSessionEnsureCounts["0:0"] == 1, "position queries must not re-ensure the session")
        #expect(engine.totalPages >= 1)

        // The reader turns past the diagnostic cover: chapter 1 still preloads
        // normally and the reader can reach it.
        let positionVC1 = engine.pageViewController(for: .chapterStart(1))
        #expect(positionVC1 is PlaceholderPageViewController, "unloaded chapter must yield a placeholder, not nil")
        for _ in 0..<20 {
            if engine.choice(for: 1) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("NAV2 choice1=\(String(describing: engine.choice(for: 1))) totalPages=\(engine.totalPages)")
        #expect(engine.totalPages >= 2, "preload must complete so the reader can turn to chapter one")
    }

    /// browserAuto keeps the legacy fallback: the same SVG-only cover falls
    /// back to the delegate engine (the forced-mode diagnostic must NOT leak
    /// into auto mode).
    @Test func autoModeSVGCoverFallsBackToLegacy() async throws {
        let oldMode = BrowserLayoutFeature.mode
        BrowserLayoutFeature.mode = .browserAuto
        defer { BrowserLayoutFeature.mode = oldMode }

        let chapter = MockBrowserLayoutResource.Chapter(
            title: "cover", href: "c0.xhtml",
            html: "<html><body><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect width=\"100\" height=\"100\"/></svg></body></html>",
            css: []
        )
        let resource = MockBrowserLayoutResource(chapters: [chapter])
        let builder = MockAttributedStringBuilder(texts: ["cover"])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)"))
        let settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings)
        await engine.start(renderSize: CGSize(width: 390, height: 844), bookId: "t")

        // Auto mode: capability fallback to legacy — the SVG cover renders from
        // the delegate with >= 1 page, and NO diagnostic state is published.
        if case .browser = engine.choice(for: 0) {
            Issue.record("browserAuto must fall back to legacy for unsupported SVG")
        }
        #expect(delegate.layouts[0] != nil)
        #expect(engine.totalPages >= 1)
        #expect(engine.testChapterLayoutStates[0] == nil, "auto mode must not publish forced diagnostics")
        let vc = engine.pageViewController(at: 0)
        #expect(vc is CoreTextPageViewController, "auto-mode fallback page comes from the legacy engine")
    }

    /// Real EPUB spine=0 (unsupported-svg cover): does layoutNextPage hang?
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"] != nil
        || FileManager.default.fileExists(atPath: "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub")))
    func realSpineZeroLayoutCompletes() async throws {
        let path = ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"]
            ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub"
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: 0)
        let css = await adapter.processedCSS(forChapter: 0)
        print("SPINE0 length=\(html.count) cssFiles=\(css.count)")
        let config = BrowserLayoutConfig(
            renderWidth: 366, renderHeight: 820, rootFontSize: 17,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let s = BrowserLayoutSession(html: html, cssTexts: css, config: config, imageLoader: { _ in nil }, generation: 1)
        s.diagnosticSpine = 0
        // Walk manually step-by-step to find the hang point.
        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { _ in nil })
        let result = try doc.makeLayout(containerSize: CGSize(width: 390, height: 844))
        print("SPINE0 boxes=\(result.boxCount) rootTag=\(result.rootBox.debugTag) children=\(result.rootBox.children.count) lines=\(result.rootBox.lines.count)")
        var walker = PageWalker(box: result.rootBox, pageSize: CGSize(width: 390, height: 844),
                                contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        var steps = 0
        while let step = walker.nextStep(), steps < 50 {
            steps += 1
            print("SPINE0 step \(steps)")
        }
        print("SPINE0 steps=\(steps)")
        // Now the full session path (the one the engine uses).
        let firstPage: PageFragments? = try await Self.timeout(nanos: 8_000_000_000) {
            try await s.layoutNextPage()
        }
        print("SPINE0-SESSION firstPage=\(firstPage != nil) pages=\(s.completedPages.count)")
        #expect(firstPage == nil)  // empty cover: no content → nil is CORRECT
    }

    @Test func svgChapterFinishCompletes() async throws {
        let html = """
        <html><body>
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
          <rect x="0" y="0" width="100" height="100" fill="red"/>
          <path d="M10 10 L90 90"/>
          <text x="10" y="50">SVG Text</text>
        </svg>
        <p>After SVG paragraph content.</p>
        </body></html>
        """
        let config = BrowserLayoutConfig(
            renderWidth: 366, renderHeight: 820, rootFontSize: 17,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let session = BrowserLayoutSession(
            html: html, cssTexts: [], config: config, imageLoader: { _ in nil }, generation: 1
        )
        // First page must complete within 3s (task-race timeout).
        let firstPage: PageFragments? = try await Self.timeout(nanos: 3_000_000_000) {
            try await session.layoutNextPage()
        }
        #expect(firstPage != nil)
        // Finish must complete within 3s too.
        _ = try await Self.timeout(nanos: 3_000_000_000) {
            try await session.finish()
            return true
        }
        print("SVG-FIXTURE pages=\(session.completedPages.count)")
        #expect(session.completedPages.count >= 1)
    }
}
