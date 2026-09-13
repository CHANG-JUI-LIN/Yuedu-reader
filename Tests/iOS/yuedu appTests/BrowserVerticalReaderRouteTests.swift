import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserVerticalReaderRouteTests {
    private var settings: ReaderRenderSettings {
        var settings = ReaderRenderSettings(theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 24, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 0,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 24, left: 12, bottom: 24, right: 12))
        settings.writingMode = .verticalRTL
        return settings
    }

    @Test func pagedAndScrollUseBrowserWithRTLTiles() async throws {
        let html = "<html><body>" + String(repeating: "<p><a href='#end'><ruby>山路<rt>やまみち</rt></ruby></a>を登りながら考えた。</p>", count: 25) + "<p id='end'>終わり</p></body></html>"
        let resource = MockBrowserLayoutResource(chapters: [.init(title: "Vertical", href: "one.xhtml", html: html,
            css: ["html { writing-mode: vertical-rl } rt { font-size: 50% }"])])
        let builder = MockAttributedStringBuilder(texts: ["Legacy must not render this"])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        defer { engine.cancelPendingWork() }
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        #expect(engine.choice(for: 0)?.isBrowser == true)
        let page = try #require(engine.pageViewController(at: 0) as? BrowserLayoutPageViewController)
        let texts = page.pageView.displayList.items.compactMap { if case .text(let t) = $0 { return t }; return nil }
        #expect(!texts.isEmpty)
        #expect(texts.allSatisfy { $0.writingMode == .verticalRTL })
        #expect(texts.contains { $0.renderedTextOverride == "やまみち" })
        let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        scroll.browserAutoEngine = engine
        await scroll.start(initialChapter: 0, contentWidth: 400, viewportExtent: 320, loadAdjacentChapters: false)
        #expect(scroll.chunks.count > 1)
        let tiles = try scroll.chunks.map { item in
            guard case .browser(let tile) = item else { throw RouteError.legacy }
            #expect(item.writingMode == .verticalRTL)
            #expect(item.height == 400)
            #expect(item.width <= 320)
            return tile
        }
        #expect(tiles.first?.documentRect.maxX == tiles.first?.chapter.document.contentWidth)
        #expect(tiles.last?.documentRect.minX == 0)
        for pair in zip(tiles, tiles.dropFirst()) { #expect(pair.0.documentRect.minX == pair.1.documentRect.maxX) }
        let tile = try #require(tiles.first)
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: tile.documentRect.width + 20, height: 450))
        cell.configure(tile: tile, horizontalInset: 12, leadingSpacing: 20, verticalInset: 24)
        #expect(cell.interactiveView.frame.origin == CGPoint(x: 0, y: 24))
        let text = try #require(cell.interactiveView.displayList.items.compactMap { if case .text(let t) = $0, t.renderedTextOverride == nil { return t }; return nil }.first)
        let point = CGPoint(x: text.rect.rawValue.midX, y: text.rect.rawValue.midY)
        let index = try #require(ReaderScrollItem.browser(tile).stringIndex(atLocalPoint: point))
        #expect(NSLocationInRange(index, text.sourceRange))
        #expect(!cell.interactiveView.interactionRegions.regions.isEmpty)
        #expect(scroll.loadedScrollExtent == tile.chapter.document.contentWidth)
        let last = try #require(tiles.last)
        let lastText = try #require(last.chapter.document.items(in: last.documentRect).items.compactMap {
            if case .text(let text) = $0, text.rect.rawValue.midX > 0,
               text.rect.rawValue.midX < last.documentRect.width { return text }; return nil
        }.last)
        #expect(scroll.chunkIndex(forChapter: 0, charOffset: lastText.sourceRange.location) == tiles.count - 1)
    }

    @Test(arguments: [false, true])
    func cancelledPreparationDoesNotPoisonTheNextOpen(replaceBeforeOldTaskCompletes: Bool) async throws {
        let resource = PausedRubyResource()
        let builder = MockAttributedStringBuilder(texts: ["Legacy ruby is not the accepted route"])
        let engine = BrowserLayoutPageEngine(resource: resource,
            delegate: CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
                offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))),
            settings: settings, mode: .browserAuto)
        defer { engine.cancelPendingWork() }
        // The next open's restore transaction cancels an already-started preload
        // while chapter resource preparation is suspended. No timing-based waits.
        let opening = Task { await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString) }
        await resource.entered.wait()
        engine.cancelPendingWork(cause: .refreshTransaction)
        if replaceBeforeOldTaskCompletes {
            let replacement = Task { await engine.preloadChapter(at: 0) }
            await resource.replacementEntered.wait()
            resource.resume.release()
            await opening.value
            #expect(await replacement.value.isReady)
        } else {
            resource.resume.release()
            await opening.value
            #expect(engine.choice(for: 0)?.isBrowser != false)
            #expect(await engine.preloadChapter(at: 0).isReady)
        }
        #expect(engine.choice(for: 0)?.isBrowser == true)
        let page = try #require(engine.pageViewController(for: .init(spineIndex: 0, charOffset: 1)) as? BrowserLayoutPageViewController)
        #expect(page.pageView.displayList.items.contains {
            if case .text(let text) = $0 { return text.renderedTextOverride == "やまみち" }
            return false
        })
    }

    enum RouteError: Error { case legacy }
}

@MainActor
private final class RubyPreparationSignal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class PausedRubyResource: BrowserLayoutResourceProviding {
    let entered = RubyPreparationSignal()
    let replacementEntered = RubyPreparationSignal()
    private var preparationCount = 0
    let resume = RubyPreparationSignal()
    var chapterCount: Int { 1 }
    func chapterTitle(at index: Int) -> String { "Ruby" }
    func chapterSourceHref(at index: Int) -> String? { "ruby.xhtml" }
    func chapterHTML(at index: Int) async throws -> String { "<p><ruby>山路<rt>やまみち</rt></ruby>を登る。</p>" }
    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
        .currentCompatibility(html: html, cssTexts: ["html { writing-mode:vertical-rl }"])
    }
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] {
        preparationCount += 1
        if preparationCount == 1 { entered.release() }
        else { replacementEntered.release() }
        await resume.wait()
        return [:]
    }
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)? { nil }
}
