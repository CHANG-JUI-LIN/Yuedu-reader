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
        cell.configure(tile: tile, horizontalInset: 12, leadingSpacing: 20, verticalInset: 24, bottomInset: 26)
        // The tile paints the insets above and below its window too; the window starts 24pt down.
        #expect(cell.interactiveView.frame == CGRect(x: 0, y: 0, width: tile.documentRect.width, height: 450))
        #expect(cell.renderingDocumentRect.minY == tile.documentRect.minY - 24)
        let text = try #require(cell.interactiveView.displayList.items.compactMap { if case .text(let t) = $0, t.renderedTextOverride == nil { return t }; return nil }.first)
        let point = cell.tileLocalPoint(fromRenderingPoint: CGPoint(x: text.rect.rawValue.midX, y: text.rect.rawValue.midY))
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

    /// A highlight's art can stand past the end of a column — 蜘蛛侠's head sits on top of the
    /// quote — and paged mode draws it in the page margin. The scroll tile cut it off at the
    /// column top (2026-10-15).
    @Test func scrollTilePaintsHighlightArtPastTheColumnTop() async throws {
        var settings = settings
        let reach: CGFloat = 48
        let art = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(
            backgroundColorHex: 0x00FF00, padding: ReaderStyleEdges(leading: Double(reach))))
        settings.regexHighlightConfiguration = RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [
            RegexHighlightRule(id: "art", name: "art", pattern: "「[^」]*」", isEnabled: true, isBuiltIn: false,
                               options: [], lightStyle: art, darkStyle: art)
        ])
        let resource = MockBrowserLayoutResource(chapters: [.init(title: "Vertical", href: "one.xhtml",
            html: "<html><body><p>「山路を登りながら考えた。」</p></body></html>",
            css: ["html { writing-mode: vertical-rl }"])])
        let builder = MockAttributedStringBuilder(texts: ["Legacy must not render this"])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        defer { engine.cancelPendingWork() }
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        scroll.browserAutoEngine = engine
        await scroll.start(initialChapter: 0, contentWidth: 400, viewportExtent: 320, loadAdjacentChapters: false)
        guard case .browser(let tile) = try #require(scroll.chunks.first) else { throw RouteError.legacy }
        let open = (tile.chapter.document.sourceText as NSString).range(of: "「").location
        let quote = try #require(tile.chapter.document.items(in: tile.documentRect).items.compactMap {
            if case .text(let text) = $0, NSLocationInRange(open, text.sourceRange) { return text }; return nil
        }.first)
        // The column starts below the document top, by the reader's top inset and the body's
        // margin (32pt) — but the fill reaches further up than that.
        #expect(quote.rect.rawValue.minY + 8 < reach, "the quote starts \(quote.rect.rawValue.minY)pt down")

        let inset: CGFloat = 24
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: tile.documentRect.width,
                                                       height: inset + tile.documentRect.height + inset))
        cell.configure(tile: tile, horizontalInset: 12, leadingSpacing: 0, verticalInset: inset, bottomInset: inset)
        cell.layoutIfNeeded()
        cell.interactiveView.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: cell.bounds, format: format).image { context in
            cell.layer.render(in: context.cgContext)
        }
        let pixels = try #require(RGBAPixels(image))
        let fillAbove = pixels.count(rows: 0..<Int(inset)) { r, g, b, a in a > 200 && r < 30 && g > 220 && b < 30 }
        #expect(fillAbove > 0, "no highlight fill above the column top")

        // The tile still reports positions in its own window.
        let drawn = try #require(cell.interactiveView.displayList.items.compactMap {
            if case .text(let text) = $0, NSLocationInRange(open, text.sourceRange) { return text }; return nil
        }.first)
        let point = cell.tileLocalPoint(fromRenderingPoint: CGPoint(x: drawn.rect.rawValue.midX, y: drawn.rect.rawValue.midY))
        let index = try #require(ReaderScrollItem.browser(tile).stringIndex(atLocalPoint: point))
        #expect(NSLocationInRange(index, drawn.sourceRange))
    }

    /// A vertical EPUB left mid-chapter reopens in scroll mode on the column the reader left, and
    /// saving reads that column back — also when it is too short to reach the screen's middle.
    @Test(arguments: [false, true])
    func scrollReopensOnTheColumnHoldingThePosition(shortColumn: Bool) async throws {
        let long = "山路を登りながら、こう考えた。智に働けば角が立つ。"
        let html = "<html><body>" + (0..<60).map { "<p>\($0 % 4 == 2 ? "「好。」" : long)</p>" }.joined()
            + "</body></html>"
        let inset: CGFloat = 24

        // A column near the middle of the chapter, clear of both ends of the scroll range.
        let probe = try await openVerticalScroll(html: html, at: 0, inset: inset)
        guard case .browser(let first) = try #require(probe.engine.chunks.first) else { throw RouteError.legacy }
        let document = first.chapter.document
        let columns = document.displayList.items.compactMap { item -> DisplayTextItem? in
            guard case .text(let text) = item, text.sourceRange.length > 0, text.renderedTextOverride == nil,
                  (text.sourceRange.length <= 4) == shortColumn else { return nil }
            return text
        }
        let middle = try #require(columns.min {
            abs($0.rect.rawValue.maxX - document.contentWidth / 2) < abs($1.rect.rawValue.maxX - document.contentWidth / 2)
        })
        try #require(document.contentWidth > 3 * probe.window.bounds.width, "content \(document.contentWidth)")
        let target = middle.sourceRange.location + 1
        probe.window.isHidden = true
        probe.pages.cancelPendingWork()

        let reader = try await openVerticalScroll(html: html, at: target, inset: inset)
        defer { reader.window.isHidden = true; reader.pages.cancelPendingWork() }
        let edge = try columnRightEdge(holding: target, in: reader)
        #expect(abs(edge - (reader.window.bounds.width - inset)) <= 1,
                "edge \(edge) offset=\(reader.collectionView.contentOffset.x)")
        let saved = try #require(reader.controller.positionForPersistence())
        #expect(saved.spineIndex == 0)
        #expect(NSLocationInRange(saved.charOffset, middle.sourceRange),
                "saved \(saved.charOffset), column \(middle.sourceRange)")

        let reopened = try await openVerticalScroll(html: html, at: saved.charOffset, inset: inset)
        defer { reopened.window.isHidden = true; reopened.pages.cancelPendingWork() }
        let again = try columnRightEdge(holding: saved.charOffset, in: reopened)
        #expect(abs(again - (reopened.window.bounds.width - inset)) <= 1, "edge \(again)")
        #expect(reopened.controller.positionForPersistence() == saved)
    }

    private struct VerticalScrollReader {
        let controller: CoreTextCollectionScrollViewController
        let engine: CoreTextScrollEngine
        let pages: BrowserLayoutPageEngine
        let window: UIWindow
        let collectionView: UICollectionView
    }

    /// A one-chapter vertical EPUB in the scroll reader on a phone-sized screen, opened at
    /// `charOffset`, once its restore has run.
    private func openVerticalScroll(html: String, at charOffset: Int, inset: CGFloat) async throws -> VerticalScrollReader {
        let resource = MockBrowserLayoutResource(chapters: [.init(title: "Vertical", href: "one.xhtml", html: html,
            css: ["html { writing-mode: vertical-rl }"])])
        let builder = MockAttributedStringBuilder(texts: ["Legacy must not render this"])
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let pages = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        await pages.start(renderSize: CGSize(width: 402, height: 874), bookId: UUID().uuidString)
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = pages
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .horizontalRTL,
            horizontalInset: inset, verticalInset: 72, backgroundColor: .white)
        controller.bottomMargin = 32
        controller.setInitialPosition(chapter: 0, charOffset: charOffset)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        for _ in 0..<500 where !engine.isReady || controller.positionForPersistence() == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        let collectionView = try #require(Self.collectionView(in: controller.view))
        return VerticalScrollReader(controller: controller, engine: engine, pages: pages, window: window,
                                    collectionView: collectionView)
    }

    /// Where the column holding `charOffset` has its right edge on screen.
    private func columnRightEdge(holding charOffset: Int, in reader: VerticalScrollReader) throws -> CGFloat {
        let row = try #require(reader.engine.chunkIndex(forChapter: 0, charOffset: charOffset))
        guard case .browser(let tile) = reader.engine.chunks[row] else { throw RouteError.legacy }
        let text = try #require(tile.chapter.document.displayList.items.compactMap { item -> DisplayTextItem? in
            if case .text(let text) = item, NSLocationInRange(charOffset, text.sourceRange) { return text }
            return nil
        }.first)
        let cell = try #require(reader.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) as? BrowserScrollTileCell)
        let local = CGPoint(x: text.rect.rawValue.maxX - cell.renderingDocumentRect.minX, y: 0)
        return cell.interactiveView.convert(local, to: reader.window).x
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let collectionView = view as? UICollectionView { return collectionView }
        return view.subviews.lazy.compactMap { collectionView(in: $0) }.first
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

/// A rendered image's pixels, row 0 at the top.
private struct RGBAPixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width, h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = buffer
    }

    func count(rows: Range<Int>, where matches: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        var count = 0
        for row in rows.clamped(to: 0..<height) {
            for col in 0..<width {
                let i = (row * width + col) * 4
                if matches(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) { count += 1 }
            }
        }
        return count
    }
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
