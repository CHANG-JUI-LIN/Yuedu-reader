@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// EPUB chapters on the browser engine lay out on their own thread
/// (`BrowserViewportLayoutOwner`). 14.trace (2026-09-22): 74 of 77 reading
/// hitches were frames in which a scroll callback laid out on the main thread.
@Suite(.serialized)
@MainActor
struct BrowserViewportAsyncLayoutTests {
    private struct Mounted {
        let engine: CoreTextScrollEngine
        let controller: CoreTextCollectionScrollViewController
        let collection: UICollectionView
        let window: UIWindow
        let chapter: BrowserScrollChapter
    }

    private static let html = "<body>" + (0..<160).map {
        "<p id='p\($0)' style='margin:24px 0'>Paragraph \($0) "
            + String(repeating: "中文 continuous layout sample ", count: 3 + $0 % 9) + "</p>"
    }.joined() + "</body>"

    private func mount(restoreTo anchor: String) async throws -> Mounted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let chapters = [MockBrowserLayoutResource.Chapter(title: "Async", href: "0.xhtml", html: Self.html, css: [])]
        let builder = MockAttributedStringBuilder(texts: [Self.html])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        let size = scene.coordinateSpace.bounds.size
        await browser.start(renderSize: size, bookId: "async-layout-\(UUID().uuidString)")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: 0, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: false)
        let chapter = try #require(engine.browserChapter(at: 0))
        let target = try #require(chapter.facts?.anchorOffsets[anchor])
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: 0, charOffset: target)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        return Mounted(engine: engine, controller: controller, collection: collection, window: window, chapter: chapter)
    }

    private func visibleCellsHaveText(_ m: Mounted) -> Bool {
        let viewport = m.collection.bounds
        let cells = m.collection.visibleCells.compactMap { $0 as? BrowserScrollTileCell }.filter {
            m.collection.convert($0.interactiveView.bounds, from: $0.interactiveView).intersection(viewport).height > 80
        }
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.interactiveView.displayList.items.contains { if case .text = $0 { true } else { false } }
        }
    }

    /// A restore to a paragraph that is not laid out lands on the estimate, then
    /// on the exact line once its layout arrives.
    @Test func restoreLandsExactlyOnceItsLayoutArrives() async throws {
        let m = try await mount(restoreTo: "p120")
        defer { m.window.isHidden = true; m.window.rootViewController = nil }
        await m.engine.waitForViewportIdle()
        m.collection.layoutIfNeeded()
        let target = try #require(m.chapter.facts?.anchorOffsets["p120"])
        let position = try #require(m.controller.positionForPersistence())
        #expect(position.spineIndex == 0)
        #expect(abs(position.charOffset - target) < 40, "restored near \(target), got \(position.charOffset)")
        #expect(visibleCellsHaveText(m))
        let row = try #require(m.engine.chunkIndex(forChapter: 0, charOffset: target))
        let frame = try #require(m.collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
        let within = try #require(m.engine.chunks[row].topOffset(forCharacterIndex: target))
        let lineTop = frame.minY + within
        let viewportTop = m.collection.contentOffset.y + m.collection.adjustedContentInset.top
        #expect(abs(lineTop - viewportTop) <= 1 / m.window.screen.scale + 0.001,
                "the target line is at the viewport top: line \(lineTop), top \(viewportTop)")
    }

    /// A jump into text that is not laid out: the frame shows no text rather
    /// than waiting, the chapter's owner lays it out, and it appears.
    @Test func scrollingIntoUnlaidTextNeverLaysOutOnTheMainThread() async throws {
        let m = try await mount(restoreTo: "p10")
        defer { m.window.isHidden = true; m.window.rootViewController = nil }
        await m.engine.waitForViewportIdle()
        m.collection.layoutIfNeeded()
        #expect(visibleCellsHaveText(m))
        let owner = try #require(m.chapter.layoutOwner)
        let far = try #require(m.chapter.facts?.anchorOffsets["p140"])
        let row = try #require(m.engine.chunkIndex(forChapter: 0, charOffset: far))
        let frame = try #require(m.collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
        m.collection.setContentOffset(CGPoint(x: 0, y: frame.minY), animated: false)
        m.controller.scrollViewDidScroll(m.collection)
        m.collection.layoutIfNeeded()
        #expect(m.chapter.hasViewportWork, "the region is requested, not laid out in the callback")
        #expect(!visibleCellsHaveText(m), "no text until its layout arrives (the chosen trade-off)")
        await m.engine.waitForViewportIdle()
        m.collection.layoutIfNeeded()
        #expect(visibleCellsHaveText(m))
        #expect(await owner.diagnostics().mainThreadTransactionCount == 0)
    }

    /// Requests made while one is laid out collapse to the latest.
    @Test func requestsWhileLayingOutCollapseToTheLatest() async throws {
        let owner = try BrowserViewportLayoutOwner(document: HTMLLayoutDocument(html: Self.html,
            configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 600)))
        let chapter = BrowserScrollChapter(spineIndex: 0, layoutOwner: owner, snapshot: owner.initialSnapshot,
            backgroundColor: .white, usesReaderBackground: false)
        let before = await owner.diagnostics().snapshotCount
        for y in stride(from: CGFloat(0), through: 6000, by: 600) {
            chapter.requestViewport(CGRect(x: 0, y: y, width: 320, height: 600))
        }
        await chapter.waitForViewportIdle()
        let transactions = await owner.diagnostics().snapshotCount - before
        #expect(transactions <= 2, "the first request and the latest one, not all eleven (\(transactions))")
        let last = CGRect(x: 0, y: 6000, width: 320, height: 600)
        #expect(chapter.materializedBounds.contains(last) || chapter.document.contentHeight < last.maxY)
    }
}
