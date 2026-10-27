import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ReaderScrollPresentationTests {
    @Test(arguments: [false, true])
    func screenPagesAndExcerptsFollowTheScrollChapter(browserRoute: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.coordinateSpace.bounds.size
        let texts = (0..<3).map { chapter in
            (0..<150).map { "Chapter \(chapter) paragraph \($0) 中文👩🏽‍💻 reading content." }.joined(separator: "\n")
        }
        let builder = MockAttributedStringBuilder(texts: texts)
        let settings = EPUBTestFixtures.renderSettings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paged = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: directory))
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        let displayedEngine: any PagedReaderEngine
        if browserRoute {
            let chapters = texts.enumerated().map { index, text in
                MockBrowserLayoutResource.Chapter(title: "Chapter \(index)", href: "\(index).xhtml",
                    html: "<body><p>" + text.replacingOccurrences(of: "\n", with: "</p><p>") + "</p></body>", css: [])
            }
            let browser = BrowserLayoutPageEngine(resource: MockBrowserLayoutResource(chapters: chapters),
                delegate: paged, settings: settings, mode: .browserAuto)
            browser.usesViewportScrolling = true
            await browser.start(renderSize: size, bookId: UUID().uuidString)
            engine.browserAutoEngine = browser
            displayedEngine = browser
        } else {
            await paged.start(renderSize: size, bookId: UUID().uuidString)
            displayedEngine = paged
        }
        // Start in chapter one: its text and geometry belong to the scroll
        // engine, independently of the paged engine still showing chapter zero.
        await engine.start(initialChapter: 1, contentWidth: size.width - 24,
                           viewportExtent: size.height, loadAdjacentChapters: true)
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialBarInsets(.init(topBand: 60, bottomBand: 50, topMargin: 20, bottomMargin: 20))
        controller.setInitialPosition(chapter: 1, charOffset: 0)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        #expect(controller.autoScrollViewportHeight < size.height)
        #expect(controller.screenPagination(forChapter: 1)?.localPageIndex == 0)
        #expect(try #require(controller.screenPagination(forChapter: 1)).displayPageCount > 2)
        #expect(controller.screenPagination(forChapter: 99) == nil)

        var committed: CoreTextReadingPosition?
        controller.onProgressCommit = { committed = $0 }
        // Both forward and reverse chapter transitions must ignore currentPage=0.
        for spine in [1, 2, 1, 0] {
            controller.setInitialPosition(chapter: spine, charOffset: 0)
            collection.layoutIfNeeded()
            #expect(controller.screenPagination(forChapter: spine)?.localPageIndex == 0)
            let start = collection.contentOffset
            let pageHeight = controller.autoScrollViewportHeight
            collection.setContentOffset(CGPoint(x: start.x, y: start.y + pageHeight * 1.1), animated: false)
            controller.scrollViewDidEndDecelerating(collection)
            let actual = try #require(committed)
            #expect(actual.spineIndex == spine && actual.charOffset > 0)
            #expect(controller.screenPagination(forChapter: spine)?.localPageIndex == 1)
            let position = ReaderDisplayedPosition.resolve(engine: displayedEngine, currentPage: 0,
                isScrolling: true, sessionLocation: .init(spineIndex: actual.spineIndex, charOffset: actual.charOffset))
            #expect(position == actual)
            let source = try #require(engine.chapterText(forSpine: position.spineIndex))
            let expected = String((source as NSString).substring(from: position.charOffset).prefix(30))
            #expect(ReaderDisplayedPosition.excerpt(in: source, charOffset: position.charOffset) == expected)
            #expect(!expected.isEmpty)
            collection.setContentOffset(start, animated: false)
            controller.scrollViewDidEndDecelerating(collection)
            #expect(controller.screenPagination(forChapter: spine)?.localPageIndex == 0)
        }
        let first = displayedEngine.charOffset(forPage: 0)
        let pagedPosition = ReaderDisplayedPosition.resolve(engine: displayedEngine, currentPage: 0,
            isScrolling: false, sessionLocation: .init(spineIndex: 2, charOffset: 300))
        #expect(pagedPosition == CoreTextReadingPosition(spineIndex: first.spineIndex, charOffset: first.charOffset))
    }

    @Test func bookmarkExcerptUsesUTF16AndKeepsWholeGraphemes() {
        let text = "前言👩🏽‍💻正文" + String(repeating: "甲", count: 40)
        let source = text as NSString
        let offset = source.range(of: "正文").location
        #expect(ReaderDisplayedPosition.excerpt(in: text, charOffset: offset) == "正文" + String(repeating: "甲", count: 28))
        #expect(ReaderDisplayedPosition.excerpt(in: text, charOffset: 3).hasPrefix("👩🏽‍💻正文"))
        #expect(ReaderDisplayedPosition.excerpt(in: text, charOffset: source.length).isEmpty)
        #expect(ReaderDisplayedPosition.excerpt(in: text, charOffset: -1).isEmpty)
    }
}
