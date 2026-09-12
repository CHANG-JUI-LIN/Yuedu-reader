@testable import YueduCoreText
import Combine
import Testing
import UIKit
@testable import yuedu_app

@Suite("EPUB BrowserAuto routing", .serialized)
@MainActor
struct EPUBAutoRoutingTests {
    @Test("opening and reopening EPUB selects BrowserAuto")
    func openingAndReopeningUsesBrowserAuto() async throws {
        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let bookID = UUID().uuidString
        for _ in 0..<2 {
            let renderer = EPUBPageRenderer()
            // Await the normal renderer startup; a second engine.start would
            // race the renderer's actual viewport and test the wrong layout.
            renderer.load(publicationSession: session, bookIdentifier: bookID,
                          renderSize: CGSize(width: 320, height: 480), settings: EPUBTestFixtures.renderSettings())
            let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
            for await ready in renderer.$isCoreTextReady.values where ready { break }
            #expect(engine.totalPages > 0)
            #expect(engine.choice(for: 0)?.isBrowser == true)
            #expect(engine.chapterText(forSpine: 0)?.contains("Simple prose paragraph.") == true)
            let position = CoreTextReadingPosition(spineIndex: 0, charOffset: 8)
            engine.updateReadingPosition(position)
            #expect(engine.pageIndex(for: position) != nil)
            #expect(renderer.engine is BrowserLayoutPageEngine)
        }
    }

    @Test("returning from scroll retains the BrowserAuto page engine")
    func scrollDoesNotReplaceBrowserAuto() async throws {
        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        let bookID = UUID().uuidString
        renderer.load(publicationSession: session, bookIdentifier: bookID,
                      renderSize: CGSize(width: 320, height: 480), settings: EPUBTestFixtures.renderSettings())
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        let scrollEngine = try #require(renderer.scrollEngine)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        await scrollEngine.start(initialChapter: 0, contentWidth: 320, viewportExtent: 480)
        #expect(scrollEngine.isReady)
        let item = try #require(scrollEngine.chunks.first)
        guard case .browser(let tile) = item else {
            Issue.record("Normal EPUB scroll must publish Browser tiles when Auto selects Browser")
            return
        }
        #expect(tile.chapter.document.sourceText.contains("Simple prose paragraph."))
        #expect(scrollEngine.chunkIndex(forChapter: 0, charOffset: 0) == 0)
        let controller = CoreTextCollectionScrollViewController(engine: scrollEngine, axis: .vertical,
            horizontalInset: 12, verticalInset: 0, backgroundColor: .white)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 344, height: 480)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? BrowserScrollTileCell)
        #expect(cell.currentTile?.chapter === tile.chapter)
        #expect(cell.interactiveView.frame.minX == 12)
        #expect(collection.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }
            .contains { $0.minimumPressDuration == 0.4 && $0.delegate === controller } == true)
        let settings = ReaderRenderSettings(theme: "test", textColor: .red, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8,
            letterSpacing: 0, marginH: 0, marginV: 0, footerHeight: 0, contentInsets: .zero)
        scrollEngine.updateRenderSettings(settings)
        #expect(await scrollEngine.reslice(restoreAt: 0, contentWidth: 240, viewportExtent: 480))
        guard case .browser(let resized) = scrollEngine.chunks[0] else {
            Issue.record("Resizing must retain Browser routing")
            return
        }
        #expect(resized.documentRect.width == 240)
        #expect(resized.chapter !== tile.chapter)
        #expect(resized.chapter.document.displayList.items.contains { item in
            if case .text(let text) = item { return text.color == .red }
            return false
        })
        #expect(renderer.engine as? BrowserLayoutPageEngine === engine)
        #expect(engine.pageIndex(for: .chapterStart(0)) != nil)
        #expect(engine.chapterText(forSpine: 0)?.contains("Simple prose paragraph.") == true)
    }
    @Test func normalEntryDefaultsToJustifiedInBothModes() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        let prose = String(repeating: "春眠不覺曉處處聞啼鳥夜來風雨聲花落知多少", count: 12)
        entries["OPS/chapter1.xhtml"] = Data("<html xmlns='http://www.w3.org/1999/xhtml'><head><style>body,p {margin:0;font-size:20px}</style></head><body><p>\(prose)</p></body></html>".utf8)
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(entries: entries))
        let renderer = EPUBPageRenderer()
        let bookID = UUID().uuidString
        renderer.load(publicationSession: session, bookIdentifier: bookID,
            renderSize: CGSize(width: 313, height: 480), settings: EPUBTestFixtures.renderSettings())
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let layout = try #require(engine.testLayout(for: 0))
        let scroll = try #require(renderer.scrollEngine)
        await scroll.start(initialChapter: 0, contentWidth: 313, viewportExtent: 480, loadAdjacentChapters: false)
        guard case .browser(let tile) = try #require(scroll.chunks.first) else {
            Issue.record("Expected Browser scroll")
            return
        }
        let paged = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        for list in [paged, tile.chapter.document.displayList] {
            let lines = list.items.compactMap { item -> DisplayTextItem? in
                if case .text(let text) = item { return text }; return nil
            }
            #expect(lines.count > 3)
            for line in lines.prefix(3) {
                #expect(abs(line.rect.maxX - 313) < 0.1, "text=\(line.text), rect=\(line.rect.rawValue), items=\(lines.count)")
            }
        }
    }

    @Test func unsupportedChapterUsesTheSameAutoDecisionInBothModes() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        entries["OPS/chapter1.xhtml"] = Data("<html xmlns='http://www.w3.org/1999/xhtml'><body><div style='display:flex'><p>Retained content.</p></div></body></html>".utf8)
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(entries: entries))
        let renderer = EPUBPageRenderer()
        let bookID = UUID().uuidString
        renderer.load(publicationSession: session, bookIdentifier: bookID,
            renderSize: CGSize(width: 320, height: 480), settings: EPUBTestFixtures.renderSettings())
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        #expect(engine.choice(for: 0)?.isBrowser == false)
        let scroll = try #require(renderer.scrollEngine)
        await scroll.start(initialChapter: 0, contentWidth: 320, viewportExtent: 480, loadAdjacentChapters: false)
        let item = try #require(scroll.chunks.first)
        #expect(item.legacyChunk != nil)
        #expect(item.attributedString.string.contains("Retained content."))
    }

}
