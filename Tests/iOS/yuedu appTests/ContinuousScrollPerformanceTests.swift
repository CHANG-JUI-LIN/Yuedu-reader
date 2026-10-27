@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ContinuousScrollPerformanceTests {
    @Test func fontResolutionReusesExactRequestsIncludingMissesAndKeepsABound() {
        var calls = 0
        var cache: BrowserDocumentFontResolver? = BrowserDocumentFontResolver(capacity: 3) { families, _, _, size in
            calls += 1
            return families == ["missing"] ? nil : UIFont.systemFont(ofSize: size)
        }
        weak let released = cache
        let first = cache!.resolve(families: ["A", "B"], weight: 400, italic: false, size: 17)
        for _ in 0..<100 {
            #expect(cache!.resolve(families: ["A", "B"], weight: 400, italic: false, size: 17) === first)
            #expect(cache!.resolve(families: ["missing"], weight: 400, italic: false, size: 17) == nil)
        }
        #expect(calls == 2)
        _ = cache!.resolve(families: ["B", "A"], weight: 400, italic: false, size: 17)
        // Each dimension must preserve the original lookup, even past the bound.
        _ = cache!.resolve(families: ["A", "B"], weight: 700, italic: false, size: 17)
        _ = cache!.resolve(families: ["A", "B"], weight: 400, italic: true, size: 17)
        _ = cache!.resolve(families: ["A", "B"], weight: 400, italic: false, size: 18)
        #expect(calls == 6)
        #expect(cache!.retainedCount == 3)
        cache = nil
        #expect(released == nil)
        let nextDocument = BrowserDocumentFontResolver { _, _, _, size in
            calls += 1
            return UIFont.systemFont(ofSize: size)
        }
        #expect(nextDocument.resolve(families: ["missing"], weight: 400, italic: false, size: 17) != nil)
        #expect(calls == 7, "a previous document's negative result must not survive")
    }

    @Test func continuousLayoutKeepsGeometryWhileResolvingEachFontTupleOnce() async throws {
        let session = try await PublicationSession.open(
            sourceURL: EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries))
        let resolver = EPUBStyleResolver(resourceProvider: ReadiumBookResourceAdapter(session: session),
            fontRegistrationService: CoreTextFontRegistrationService())
        let html = "<body>" + (0..<60).map { i in
            "<p>\(i) The quick brown fox 閱讀文字 <b>bold</b> <i>italic</i> "
                + String(repeating: "continuous text 連續滾動內容 ", count: 8) + "</p>"
        }.joined() + "</body>"
        let css = "p { font-family: Georgia, TimesNewRomanPSMT, PingFangTC-Regular; font-size: 17px; }"
        var reference: BrowserScrollDocument?
        var baselineTimes: [Double] = []
        var cachedTimes: [Double] = []
        for pass in 0..<3 {
            // Alternate order so a warm system font cache does not favor one path.
            for memoized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
                var calls = 0
                let lookup: ([String], Int, Bool, CGFloat) -> UIFont? = { families, weight, italic, size in
                    calls += 1
                    return resolver.registeredFonts.resolve(families: families, weight: weight, italic: italic, size: size)
                }
                let memo = BrowserDocumentFontResolver(resolve: lookup)
                let config = BrowserLayoutConfig(renderWidth: 320, renderHeight: 600, rootFontSize: 17,
                    fontResolver: { families, weight, italic, size in
                        memoized ? memo.resolve(families: families, weight: weight, italic: italic, size: size)
                            : lookup(families, weight, italic, size)
                    })
                let start = SourcePerfTrace.now
                let document = try SourcePerfTrace.span("test.continuous.fontResolution",
                    "memoized=\(memoized) pass=\(pass)", thresholdMs: 0) {
                    try HTMLLayoutDocument(html: html, css: [css], configuration: config)
                        .prepareContinuous(validateCapabilities: false).makeDocument()
                }
                let ms = (SourcePerfTrace.now - start) * 1000
                if memoized {
                    cachedTimes.append(ms)
                    #expect(memo.requestCount > memo.resolutionCount * 10)
                    #expect(calls == memo.resolutionCount)
                    #expect(memo.retainedCount < 128)
                } else {
                    baselineTimes.append(ms)
                    #expect(calls > 100)
                }
                print("[ContinuousScrollPerf] memoized=\(memoized) pass=\(pass) ms=\(ms) resolverCalls=\(calls) requests=\(memo.requestCount)")
                if let reference {
                    #expect(document.sourceText == reference.sourceText)
                    #expect(document.contentSize == reference.contentSize)
                    #expect(fingerprint(document) == fingerprint(reference))
                    // Reverse viewport probes include seams and the far end of the chapter.
                    for y in [CGFloat(0), 1900, 3900, 1900, 0, document.contentHeight - 600] {
                        let offset = document.charOffset(atDocumentY: y)
                        #expect(offset == reference.charOffset(atDocumentY: y))
                        #expect(document.documentY(forCharOffset: offset) == reference.documentY(forCharOffset: offset))
                    }
                } else { reference = document }
            }
        }
        print("[ContinuousScrollPerf] baselineMs=\(baselineTimes) memoizedMs=\(cachedTimes)")
    }

    private func fingerprint(_ document: BrowserScrollDocument) -> [String] {
        document.displayList.items.map { item in
            switch item {
            case .text(let t): return "\(t.sourceRange)|\(t.rect)|\(t.baselineY)|\(t.text)|\(t.font.fontDescriptor)"
            case .image(let i): return "image|\(i.sourceRange)|\(i.rect)|\(i.source)"
            case .fill(let f): return "fill|\(f.rect)|\(f.color)"
            }
        }
    }

    @Test func unchangedVerticalHostUpdatesDoNotReloadDuringReverseAndCrossChapterScrolling() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let chapters = (0..<3).map { i in
            MockBrowserLayoutResource.Chapter(title: "Chapter \(i)", href: "\(i).xhtml",
                html: "<body>" + String(repeating: "<p>Chapter \(i) continuous scrolling contents 測試文字。</p>", count: 60) + "</body>", css: [])
        }
        let builder = MockAttributedStringBuilder(texts: chapters.map(\.html))
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
            delegate: delegate, settings: settings, mode: .browserAuto)
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "continuous-scroll-test")
        await engine.start(initialChapter: 1, contentWidth: size.width - 24,
            viewportExtent: size.height, loadAdjacentChapters: true)
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: 1, charOffset: 0)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        controller.update(axis: .vertical, sides: .init(left: 12, right: 12), vertical: 20)
        collection.layoutIfNeeded()
        let original = try #require(collection.dataSource)
        let spy = CountingDataSource(original)
        collection.dataSource = spy
        collection.reloadData()
        collection.layoutIfNeeded()
        try #require(engine.chapterRanges.count == 3)
        // Measured viewport heights can change tile counts. Navigate by stable
        // source coordinates instead of retaining indices from the estimate.
        for spine in [0, 1, 2, 1, 0] {
            let chapter = try #require(engine.browserChapter(at: spine))
            let sourceOffset = spine == 2 ? max(0, (chapter.document.sourceText as NSString).length - 1) : 0
            controller.setInitialPosition(chapter: spine, charOffset: sourceOffset)
            collection.layoutIfNeeded()
            let offset = collection.contentOffset
            let contentSize = collection.contentSize
            let count = spy.cellRequests
            let cells = collection.visibleCells.compactMap { $0 as? BrowserScrollTileCell }
            try #require(!cells.isEmpty)
            let views = cells.map(\.interactiveView)
            for _ in 0..<10 {
                controller.update(axis: .vertical, sides: .init(left: 12, right: 12), vertical: 20)
                collection.layoutIfNeeded()
            }
            #expect(spy.cellRequests == count, "same geometry must not request replacement cells")
            #expect(collection.contentOffset == offset)
            #expect(collection.contentSize == contentSize)
            for (cell, view) in zip(cells, views) { #expect(cell.interactiveView === view) }
        }
        // Actual inset changes must still reach the collection view.
        let insets = ReaderScrollBarInsets(topBand: 20, bottomBand: 30, topMargin: 8, bottomMargin: 10)
        controller.update(axis: .vertical, sides: .init(left: 12, right: 12), vertical: 20, barInsets: insets)
        controller.view.layoutIfNeeded()
        #expect(collection.contentInset.top == 8)
        #expect(collection.contentInset.bottom == 10)
        // Bounds can change without any explicit margin setting changing.
        // Such a bridge update must still rebind the tile's viewport geometry.
        collection.layoutIfNeeded()
        let beforeResize = spy.cellRequests
        collection.bounds.size.height -= 40
        controller.update(axis: .vertical, sides: .init(left: 12, right: 12), vertical: 20, barInsets: insets)
        collection.layoutIfNeeded()
        #expect(spy.cellRequests > beforeResize)
        withExtendedLifetime(spy) {}
    }

    private final class CountingDataSource: NSObject, UICollectionViewDataSource {
        let base: any UICollectionViewDataSource
        var cellRequests = 0
        init(_ base: any UICollectionViewDataSource) { self.base = base }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            base.collectionView(collectionView, numberOfItemsInSection: section)
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            cellRequests += 1
            return base.collectionView(collectionView, cellForItemAt: indexPath)
        }
    }
}
