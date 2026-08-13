import Testing
import UIKit
@testable import yuedu_app

/// Mock resource provider + mock attributed-string builder for engine tests.
@MainActor
final class MockBrowserLayoutResource: BrowserLayoutResourceProviding {
    struct Chapter {
        let title: String
        let href: String
        let html: String
        let css: [String]
    }

    var chapters: [Chapter]
    var failChapterHTML: Set<Int> = []
    var failChapterCSS: Set<Int> = []

    init(chapters: [Chapter]) {
        self.chapters = chapters
    }

    var chapterCount: Int { chapters.count }
    func chapterTitle(at index: Int) -> String { chapters[safe: index]?.title ?? "" }
    func chapterSourceHref(at index: Int) -> String? { chapters[safe: index]?.href }
    func chapterHTML(at index: Int) async throws -> String {
        if failChapterHTML.contains(index) { throw MockError.failed }
        return chapters[safe: index]?.html ?? ""
    }
    func processedCSS(forChapter index: Int) async -> [String] {
        if failChapterCSS.contains(index) { return [] }
        return chapters[safe: index]?.css ?? []
    }
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] { [:] }
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)? { nil }

    enum MockError: Error { case failed }
}

/// Plain-text attributed builder so the legacy delegate can paginate without
/// the full HTML pipeline.
@MainActor
final class MockAttributedStringBuilder: AttributedStringBuilding {
    let texts: [String]

    init(texts: [String]) {
        self.texts = texts
    }

    var chapterCount: Int { texts.count }

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }

    func chapterSourceHref(at index: Int) -> String? { "chapter\(index).xhtml" }

    func chapterDataSize(at index: Int) async -> Int {
        texts[safe: index]?.utf8.count ?? 0
    }

    func chapterIndex(for href: String) -> Int? {
        texts.indices.first { "chapter\($0).xhtml" == href }
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard texts.indices.contains(index) else { throw AttributedStringBuildingError.chapterOutOfRange(index) }
        let text = texts[index]
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize),
            .foregroundColor: themeTextColor,
        ])
        return AttributedChapterBuildResult(
            attributedString: attributed,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:],
            revision: ContentRevision()
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Engine contract: page mapping, position restore, anchors, links, atomic
/// fallback, theme change — through the full PageRenderingProvider surface.
@MainActor
struct BrowserLayoutPageEngineTests {

    private func makeSettings(fontSize: CGFloat = 17) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "paper",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 12,
            marginV: 12,
            footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
    }

    private func makeEngine(
        chapters: [MockBrowserLayoutResource.Chapter],
        fontSize: CGFloat = 17,
        mode: EPUBLayoutEngineMode = .browserAuto
    ) async -> (engine: BrowserLayoutPageEngine, resource: MockBrowserLayoutResource, delegate: CoreTextPageEngine) {
        let resource = MockBrowserLayoutResource(chapters: chapters)
        let builder = MockAttributedStringBuilder(texts: chapters.map { $0.title })
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bl-test-\(UUID().uuidString)"))
        let settings = makeSettings(fontSize: fontSize)
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(
            resource: resource, delegate: delegate, settings: settings, mode: mode
        )
        await engine.start(renderSize: CGSize(width: 300, height: 400), bookId: "test")
        return (engine, resource, delegate)
    }

    private func plainChapter(_ text: String, index: Int = 0) -> MockBrowserLayoutResource.Chapter {
        MockBrowserLayoutResource.Chapter(
            title: "Chapter \(index)",
            href: "chapter\(index).xhtml",
            html: "<html><body><p>\(text)</p></body></html>",
            css: []
        )
    }

    @Test func browserChapterPagesAndOffsetMapping() async throws {
        let chapter = plainChapter(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20))
        let (engine, _, _) = await makeEngine(chapters: [chapter])
        #expect(engine.choice(for: 0)?.isBrowser == true)
        #expect(engine.totalPages >= 2)

        // charOffset → page → charOffset round trip lands within the same page.
        let offset = 200
        let page = engine.pageIndex(forSpine: 0, charOffset: offset)
        let (spine, restoredOffset) = engine.charOffset(forPage: page)
        #expect(spine == 0)
        let restoredPage = engine.pageIndex(forSpine: 0, charOffset: restoredOffset)
        #expect(restoredPage == page)

        // Page view vends and carries its reading position.
        let vc = engine.pageViewController(at: page)
        #expect(vc is BrowserLayoutPageViewController)
        let position = (vc as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
        #expect(position?.spineIndex == 0)

        // `pageSourceRanges` is now STORED and refreshed by `pages`'s didSet
        // (it used to re-walk every fragment on every access, inside a binary
        // search). It must stay in step with the pages the chapter ended with.
        let layout = try #require(engine.testChapterLayout?.layout)
        #expect(layout.pageSourceRanges.count == layout.pages.count,
                "stale page ranges: \(layout.pageSourceRanges.count) ranges for \(layout.pages.count) pages")
    }

    /// A page whose chapter layout has not reached it yet must still identify
    /// ITSELF. The placeholder used to be default-constructed
    /// (`PlaceholderPageViewController()`), reporting `globalPageIndex == 0`
    /// and a nil reading position; when the turn settled,
    /// `CoreTextPagedView.Coordinator.readingPosition(from:)` fell back to that
    /// 0 and resolved it to spine 0 / offset 0 — so turning a page while a
    /// chapter was still paginating threw the reader back to the front cover.
    @Test func placeholderForUnlaidChapterCarriesItsOwnPageIndex() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        let (engine, _, _) = await makeEngine(chapters: [
            plainChapter(text, index: 0),
            plainChapter(text, index: 1),
        ])
        // start() preloads chapter 0 only — chapter 1 has no pages yet.
        let target = engine.pageIndex(forSpine: 1, charOffset: 0)
        #expect(target > 0, "chapter 1 must not begin at global page 0")

        let vc = engine.pageViewController(at: target)
        let placeholder = try #require(
            vc as? PlaceholderPageViewController,
            "an un-laid-out chapter page should vend a placeholder"
        )
        #expect(placeholder.globalPageIndex == target,
                "placeholder reported page \(placeholder.globalPageIndex), expected \(target)")
        #expect(placeholder.coreTextReadingPosition?.spineIndex == 1,
                "placeholder must anchor to its OWN chapter, not the book start")
    }

    @Test func positionRestoresNearOffsetAfterInvalidate() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let (engine, _, _) = await makeEngine(chapters: [plainChapter(text)])
        let offset = 600
        let pageBefore = engine.pageIndex(forSpine: 0, charOffset: offset)
        _ = engine.pageViewController(at: pageBefore)  // sets currentPage

        await engine.invalidateLayout(newSize: CGSize(width: 260, height: 360))

        // After re-layout with a different size, the offset restores to the
        // SAME vicinity (not the old page number).
        let pageAfter = engine.pageIndex(forSpine: 0, charOffset: offset)
        let (_, offsetAfter) = engine.charOffset(forPage: pageAfter)
        #expect(abs(offsetAfter - offset) < 600)  // within a couple of pages
    }

    @Test func fontChangeRestoresByOffsetNotPageNumber() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let (engine, _, _) = await makeEngine(chapters: [plainChapter(text)], fontSize: 17)
        let offset = 600
        let pageSmall = engine.pageIndex(forSpine: 0, charOffset: offset)
        #expect(pageSmall != 0)

        // Larger font → fewer chars per page → same offset must map to a
        // LATER page, and the restored offset stays near 600.
        engine.updateRenderSettings(makeSettings(fontSize: 24))
        await engine.invalidateLayout(newSize: CGSize(width: 300, height: 400))
        let pageLarge = engine.pageIndex(forSpine: 0, charOffset: offset)
        #expect(pageLarge >= pageSmall)
        let (_, restored) = engine.charOffset(forPage: pageLarge)
        #expect(abs(restored - offset) < 600)
    }

    @Test func anchorNavigation() async throws {
        let html = """
        <html><body><p id="mark">Target paragraph with anchor.</p><p>More text.</p></body></html>
        """
        let chapter = MockBrowserLayoutResource.Chapter(title: "c", href: "c.xhtml", html: html, css: [])
        let (engine, _, _) = await makeEngine(chapters: [chapter])
        let offset = try #require(engine.charOffset(forSpine: 0, fragment: "mark"))
        let page = engine.pageIndex(forSpine: 0, charOffset: offset)
        let (_, restored) = engine.charOffset(forPage: page)
        #expect(abs(restored - offset) < 100)
    }

    @Test func linkResolutionNavigatesToTargetChapter() async throws {
        let c0 = plainChapter("First chapter text.", index: 0)
        let c1 = plainChapter("Second chapter text.", index: 1)
        let (engine, _, _) = await makeEngine(chapters: [c0, c1])
        // Link from chapter 0 to chapter1.xhtml.
        let page = await engine.resolveInternalLink("chapter1.xhtml", fromSpineIndex: 0)
        let (spine, _) = engine.localPosition(for: try #require(page))
        #expect(spine == 1)
    }

    @Test func capabilityFailureFallsBackWholeChapterToLegacy() async throws {
        // float CSS → scanner rejects → the DELEGATE lays out the chapter.
        let chapter = MockBrowserLayoutResource.Chapter(
            title: "floaty",
            href: "f.xhtml",
            html: "<html><body><div style=\"float: left\">x</div></body></html>",
            css: []
        )
        let (engine, _, delegate) = await makeEngine(chapters: [chapter])
        let choice = engine.choice(for: 0)
        guard case .legacyFallback(let reasons) = choice else {
            Issue.record("expected legacyFallback, got \(String(describing: choice))")
            return
        }
        #expect(reasons.contains(.float))
        // The chapter must be laid out on the DELEGATE (atomic fallback).
        #expect(delegate.layouts[0] != nil)
        #expect(engine.totalPages >= 1)
        // Page view comes from the legacy engine.
        let vc = engine.pageViewController(at: 0)
        #expect(vc is CoreTextPageViewController)
    }

    @Test func engineFailureFallsBackWholeChapter() async throws {
        let chapter = plainChapter("Text that will fail to load.", index: 0)
        let (engine, resource, _) = await makeEngine(chapters: [chapter])
        resource.failChapterHTML.insert(0)
        await engine.notifyChapterDataChanged(at: 0)
        let choice = engine.choice(for: 0)
        guard case .legacyEngineFailure = choice else {
            Issue.record("expected legacyEngineFailure, got \(String(describing: choice))")
            return
        }
        // The whole chapter renders from the legacy engine — no partial browser
        // pages.
        let vc = engine.pageViewController(at: 0)
        #expect(vc is CoreTextPageViewController)
    }

    @Test func themeChangeKeepsBrowserPages() async throws {
        let chapter = plainChapter("Theme text.")
        let (engine, _, _) = await makeEngine(chapters: [chapter])
        engine.applyThemeChange(textColor: .systemBlue, backgroundColor: .systemGray6)
        let vc = engine.pageViewController(at: 0)
        guard let pageVC = vc as? BrowserLayoutPageViewController else {
            Issue.record("expected browser page")
            return
        }
        let textItems = pageVC.pageView.displayList.items.compactMap { item -> DisplayTextItem? in
            if case .text(let t) = item { return t }
            return nil
        }
        let first = try #require(textItems.first)
        #expect(first.color == UIColor.systemBlue)
    }

    @Test func readingPositionRoundTrip() async throws {
        let chapter = plainChapter(String(repeating: "A sentence for position mapping. ", count: 10))
        let (engine, _, _) = await makeEngine(chapters: [chapter])
        let page = engine.totalPages - 1
        let position = try #require(engine.readingPosition(forPage: page))
        let restored = engine.pageIndex(for: position)
        #expect(restored == page)
    }

    /// THE LIVELOCK REGRESSION: an image-only / zero-page chapter under
    /// browserForced MUST publish a terminal diagnostic page (1 page, browser
    /// engine, never re-ensured). Position queries must not start a second
    /// session, and the reader must be able to turn past the diagnostic.
    @Test func browserForcedImageOnlyChapterPublishesDiagnosticPage() async throws {
        // A chapter that lays out ZERO pages (SVG-only body). The legacy
        // delegate would render the title placeholder; forced mode must NOT
        // delegate — it publishes the browser engine's diagnostic page.
        let emptyCover = MockBrowserLayoutResource.Chapter(
            title: "cover",
            href: "c0.xhtml",
            html: "<html><body><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect width=\"100\" height=\"100\"/></svg></body></html>",
            css: []
        )
        let nextChapter = MockBrowserLayoutResource.Chapter(
            title: "ch1", href: "c1.xhtml",
            html: "<html><body><p>Real chapter text to keep the reader moving.</p></body></html>",
            css: []
        )
        let resource = MockBrowserLayoutResource(chapters: [emptyCover, nextChapter])
        let builder = MockAttributedStringBuilder(texts: ["cover", "next1"])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bl-rg-\(UUID().uuidString)"))
        let settings = makeSettings()
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        // Forced mode is injected, never set on the global: two tests in this
        // suite run in parallel, and flipping a shared `var` made the capability
        // fallback test fail depending on interleaving.
        let engine = BrowserLayoutPageEngine(
            resource: resource, delegate: delegate, settings: settings,
            mode: .browserForced, showDebugOverlay: true
        )
        await engine.start(renderSize: CGSize(width: 390, height: 844), bookId: "rg")

        // Choice stays BROWSER — the browser engine owns the diagnostic page.
        #expect(engine.choice(for: 0)?.isBrowser == true)
        // State is a TERMINAL unsupported diagnostic (image-only document).
        let state = engine.testChapterLayoutStates[0]
        guard case .unsupportedDiagnostic(let page) = state else {
            Issue.record("expected unsupportedDiagnostic state, got \(String(describing: state))")
            return
        }
        #expect(page.reason == .imageOnlyDocument)
        #expect(page.spineIndex == 0)
        #expect(page.unsupportedFeatures.contains(.unsupportedSVG))
        // The diagnostic counts as exactly ONE page so the reader can turn past.
        #expect(engine.totalPages >= 1)

        // pageViewController(at:)/(for:) returns the DIAGNOSTIC page VC — never
        // a placeholder that re-triggers ensure.
        let atVC = engine.pageViewController(at: 0)
        #expect(atVC is BrowserForcedDiagnosticViewController)
        let positionVC = engine.pageViewController(for: .chapterStart(0))
        #expect(positionVC is BrowserForcedDiagnosticViewController)

        // Session-ensure seal: exactly ONE (generation, spine) session; 100
        // position queries must not start another (the livelock loops forever
        // when placeholders keep re-ensuring).
        #expect(engine.testSessionEnsureCounts["0:0"] == 1)
        for _ in 0..<100 {
            _ = engine.pageViewController(for: .chapterStart(0))
        }
        #expect(engine.testSessionEnsureCounts["0:0"] == 1, "100 position queries must not re-ensure the session")
        #expect(engine.totalPages >= 1)

        // Reader can still move to chapter 1: preload proceeds normally.
        await engine.preloadChapter(at: 1)
        #expect(engine.choice(for: 1)?.isBrowser == true)
        #expect(engine.totalPages >= 2, "reader can turn past the diagnostic cover into chapter one")
    }
}
