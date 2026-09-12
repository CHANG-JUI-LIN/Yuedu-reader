@testable import YueduCoreText
import Combine
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reported title page engine routing", .serialized)
@MainActor
struct BrowserLayoutReportedTitlePageTests {
    @Test(.enabled(if: BrowserLayoutRedChamberRegressionTests.epubPath != nil))
    func autoAcceptsAuthoredTitlePage() async throws {
        typealias Fixture = BrowserLayoutRedChamberRegressionTests
        let session = try await Fixture.session()
        let spine = try await Fixture.locateFirstChapter(session: session)
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reported-title-page-routing", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let offsets = output.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: offsets) }
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: Fixture.viewport)
        let legacy = CoreTextPageEngine(attributedBuilder: builder,
            renderSettings: Fixture.settings, offsetStore: CharOffsetStore(directoryURL: offsets))
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
            renderSize: Fixture.viewport, settings: Fixture.settings)
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine,
            "Normal EPUB entry must enable BrowserAuto without a simulator launch argument")
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        await engine.preloadChapter(at: spine)
        let choice = try #require(engine.choice(for: spine))
        #expect(choice.isBrowser, "Actual choice: \(choice.debugLabel)")
        let layout = try #require(engine.testLayout(for: spine))
        #expect(!layout.pages.isEmpty)
        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        try #require(DisplayListRenderer.render(list, size: Fixture.viewport).pngData())
            .write(to: output.appendingPathComponent("browser-auto.png"))

        await legacy.start(renderSize: Fixture.viewport, bookId: UUID().uuidString)
        await legacy.preloadChapter(at: spine)
        let legacyPage = legacy.pageIndex(forSpine: spine, charOffset: 0)
        let image = try #require(legacy.renderSnapshot(forPage: legacyPage))
        try #require(image.pngData()).write(to: output.appendingPathComponent("legacy.png"))
        let (_, root) = try await Fixture.buildBoxTree(spine: spine)
        let k1 = try #require(Fixture.findK1(in: root))
        #expect(abs(k1.contentSize.width - 15 * k1.style.fontSize) < 0.5)
        #expect(abs(k1.margins.left - k1.margins.right) < 0.5)
        let report: [String: Any] = ["spine": spine, "autoChoice": choice.debugLabel,
            "productionMode": BrowserLayoutFeature.mode.description,
            "browserPages": layout.pages.count,
            "fontSize": k1.style.fontSize, "authoredWidth": "15em",
            "usedWidth": k1.contentSize.width, "marginLeft": k1.margins.left,
            "marginRight": k1.margins.right, "marginTop": k1.margins.top]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("routing.json"))
        print("Reported title page evidence: \(output.path)")
    }
    @Test(.enabled(if: BrowserLayoutRedChamberRegressionTests.epubPath != nil))
    func normalGalleryScrollUsesBrowserAndPaintsPurpleBadges() async throws {
        typealias Fixture = BrowserLayoutRedChamberRegressionTests
        let session = try await Fixture.session()
        let renderer = EPUBPageRenderer()
        let bookID = UUID().uuidString
        renderer.load(publicationSession: session, bookIdentifier: bookID,
            renderSize: Fixture.viewport, settings: Fixture.settings)
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        let scroll = try #require(renderer.scrollEngine)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let width = Fixture.viewport.width - Fixture.settings.contentInsets.left - Fixture.settings.contentInsets.right
        await scroll.start(initialChapter: 4, contentWidth: width, viewportExtent: Fixture.viewport.height,
                           loadAdjacentChapters: false)
        #expect(engine.choice(for: 4)?.isBrowser == true)
        let first = try #require(scroll.chunks.first)
        guard case .browser(let tile) = first else {
            Issue.record("The real gallery chapter must use Browser in normal scroll")
            return
        }
        let purple = UIColor(red: 95 / 255.0, green: 82 / 255.0, blue: 160 / 255.0, alpha: 1)
        let badges = tile.chapter.document.displayList.items.filter {
            if case .fill(let fill) = $0 { return fill.color == purple }
            return false
        }
        #expect(badges.count == 6)
        #expect(tile.chapter.document.contentHeight > Fixture.viewport.height)
        #expect(scroll.chunks.count > 1)
        #expect(scroll.chunkIndex(forChapter: 4, charOffset: 0) == 0)
        for item in scroll.chunks {
            #expect(item.height <= 2000)
            #expect(item.legacyChunk == nil)
        }
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: Fixture.viewport.width, height: 2000))
        cell.configure(tile: tile, horizontalInset: Fixture.settings.contentInsets.left, leadingSpacing: 0)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reported-gallery-normal-scroll")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { context in
            Fixture.settings.backgroundColor.setFill()
            context.fill(cell.bounds)
            cell.layer.render(in: context.cgContext)
        }
        try #require(image.pngData()).write(to: output.appendingPathComponent("scroll-cell.png"))
        let paged = try #require(engine.testLayout(for: 4))
        #expect(paged.sourceText == tile.chapter.document.sourceText)
        let firstWhite = try #require(BrowserLayoutTestSupport.allTextFragments([paged.pages[0]]).first {
            (paged.sourceText as NSString).substring(with: $0.sourceRange) == "红"
        })
        #expect(firstWhite.rect.minY >= Fixture.settings.contentInsets.top,
            "white text rect=\(firstWhite.rect.rawValue), document=\(firstWhite.documentRect.rawValue), baseline=\(firstWhite.baselineY)")
        try #require(DisplayListRenderer.render(paged.displayList(forPage: 0,
            themeTextColor: Fixture.settings.textColor, oldThemeColor: paged.themeTextColor),
            size: Fixture.viewport).pngData()).write(to: output.appendingPathComponent("paged.png"))
        print("Normal gallery scroll evidence: \(output.path)")
    }

}
