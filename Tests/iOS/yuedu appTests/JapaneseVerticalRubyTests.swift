import Combine
import SwiftSoup
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Local corpus acceptance for the package's newly supported vertical text path.
/// The copyrighted book stays outside the repository; CI explicitly skips it.
@Suite("Japanese vertical package corpus", .serialized)
@MainActor
struct JapaneseVerticalRubyTests {
    nonisolated private static let bookPath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/kusamakura-japanese-vertical-writing.epub"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: bookPath)))
    func importedBookSurvivesProductionReaderOpenAndClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        let result = try await LocalBookImportService.importBooks(at: [URL(fileURLWithPath: Self.bookPath)], store: store)
        let book = try #require(result.books.first)
        defer { store.delete(bookId: book.id) }
        #expect(result.failures.isEmpty)
        #expect(BookStore(metadataFileURL: metadata).books.contains { $0.id == book.id })
        let session = try await PublicationSession.open(sourceURL: store.localEPUBURL(for: book))
        #expect(session.epubWritingMode == .verticalRL)
        var settings = ReaderRenderSettings(theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 24, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 0,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 24, left: 12, bottom: 24, right: 12))
        settings.writingMode = .verticalRTL
        let rendererBookID = book.id.uuidString
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: rendererBookID,
                      renderSize: CGSize(width: 320, height: 480), settings: settings)
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        defer { engine.cancelPendingWork() }
        await engine.preloadChapter(at: 1)
        #expect(engine.choice(for: 1)?.isBrowser == true)
        let vc = try #require(engine.pageViewController(for: .init(spineIndex: 1, charOffset: 0)) as? BrowserLayoutPageViewController)
        let texts = vc.pageView.displayList.items.compactMap { if case .text(let t) = $0 { return t }; return nil }
        #expect(texts.allSatisfy { $0.writingMode == .verticalRTL })
        #expect(texts.contains { $0.renderedTextOverride != nil })
        let scroll = try #require(renderer.scrollEngine)
        #expect(scroll.browserAutoEngine === engine)
        await scroll.start(initialChapter: 1, contentWidth: 400, viewportExtent: 320, loadAdjacentChapters: false)
        #expect(!scroll.chunks.isEmpty)
        #expect(scroll.chunks.allSatisfy { if case .browser = $0 { return $0.writingMode == .verticalRTL }; return false })
        store.updateLastOpened(bookId: book.id)
        store.updatePosition(bookId: book.id, position: 0.01, forceSave: true)
        engine.cancelPendingWork()
        store.reloadFromDisk()
        #expect(store.books.contains { $0.id == book.id && $0.isInBookshelf })
        #expect(FileManager.default.fileExists(atPath: store.localEPUBURL(for: book).path))

        // Open the persisted book again with the same render-cache identity and
        // restore inside chapter 1, as opposed to only checking the cover at 0.
        let reopenedBook = try #require(store.books.first { $0.id == book.id })
        let reopenedSession = try await PublicationSession.open(sourceURL: store.localEPUBURL(for: reopenedBook))
        let reopened = EPUBPageRenderer()
        reopened.load(publicationSession: reopenedSession, bookIdentifier: rendererBookID,
                      renderSize: CGSize(width: 320, height: 480), settings: settings)
        for await ready in reopened.$isCoreTextReady.values { if ready { break } }
        let reopenedEngine = try #require(reopened.engine as? BrowserLayoutPageEngine)
        defer { reopenedEngine.cancelPendingWork() }
        let position = CoreTextReadingPosition(spineIndex: 1, charOffset: 2725)
        let observer = reopened.$pendingVisibleRefreshCommit.compactMap { $0 }.sink { commit in
            Task { @MainActor in
                reopened.finishVisibleRefresh(transactionID: commit.transactionID, outcome: .applied)
            }
        }
        defer { observer.cancel() }
        let restored = await reopened.refresh(.init(intent: .layout, mode: .paged,
            settings: settings, position: position, viewportSize: CGSize(width: 320, height: 480)))
        #expect(restored.isCompleted)
        #expect(reopenedEngine.choice(for: 1)?.isBrowser == true)
        let restoredVC = try #require(reopenedEngine.pageViewController(for: position) as? BrowserLayoutPageViewController)
        #expect(reopenedEngine.chapterText(forSpine: 1) == engine.chapterText(forSpine: 1))
        #expect(restoredVC.pageView.displayList.items.contains {
            if case .text(let text) = $0 { return text.renderedTextOverride != nil && text.writingMode == .verticalRTL }
            return false
        })
        let reopenedScroll = try #require(reopened.scrollEngine)
        await reopenedScroll.start(initialChapter: 1, contentWidth: 400, viewportExtent: 320, loadAdjacentChapters: false)
        #expect(!reopenedScroll.chunks.isEmpty)
        #expect(reopenedScroll.chunks.allSatisfy { if case .browser = $0 { return true }; return false })

    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: bookPath)))
    func originalBookThroughEPUBResourceAdapter() async throws {
        let publication = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: Self.bookPath))
        let adapter = EPUBBrowserLayoutResourceAdapter(session: publication)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("JapaneseVerticalPackage")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var chapterCount = 0
        var totalAnnotations = 0
        for index in publication.chapters.indices {
            let html = try await adapter.chapterHTML(at: index)
            let parsed = try SwiftSoup.parse(html)
            let rt = try parsed.select("rt").array()
            guard !rt.isEmpty else { continue }
            let input = await adapter.cssFrontendInput(forChapter: index, html: html)
            let images = await adapter.prefetchImages(forChapter: index, html: html, renderWidth: 320)
            let config = BrowserLayoutConfig(renderWidth: 272, renderHeight: 432, rootFontSize: 24,
                fontFamilies: ["HiraginoSans-W3"],
                contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
                fontResolver: adapter.fontResolver(), writingMode: .verticalRTL)
            let document = HTMLLayoutDocument(input: input, configuration: config, imageLoader: { images[$0] })
            #expect(document.capabilities().supported, "spine=\(index): \(document.capabilities().unsupportedFeatures)")
            let session = try document.makePageSession()
            let first = try #require(try await session.layoutNextPage())
            #expect(session.completedPages.count == 1)
            #expect(!session.isFinished)
            try await session.finish()
            let ranges = BrowserPageGeometry.buildPageRanges(session.completedPages, sourceText: session.sourceText)
            #expect(ranges.first?.location == 0)
            let lastEnd = try #require(ranges.last.map(NSMaxRange))
            // Existing sourceText retains collapsed trailing whitespace even
            // when the last shaped line trims it. No visible character may go missing.
            let trailing = (session.sourceText as NSString).substring(from: lastEnd)
            #expect(trailing.unicodeScalars.allSatisfy { " \t\n\r\u{000C}".unicodeScalars.contains($0) })
            var annotations: [String] = []
            for page in session.completedPages {
                let list = DisplayListBuilder.build(for: page, sourceText: session.sourceText)
                annotations += list.items.compactMap { item in
                    if case .text(let text) = item, text.renderedTextOverride != nil { return text.text }
                    return nil
                }
            }
            #expect(annotations == (try rt.map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }))
            let flow = try document.prepareContinuous().makeDocument()
            #expect(flow.sourceText == session.sourceText)
            #expect(flow.contentHeight == 480)
            #expect(flow.contentWidth > 320)
            if chapterCount == 0 {
                #expect(session.sourceText.contains("山路"))
                for page in session.completedPages.prefix(2) {
                    let list = DisplayListBuilder.build(for: page, sourceText: session.sourceText)
                    let image = UIGraphicsImageRenderer(size: first.pageRect.rawValue.size).image {
                        UIColor.white.setFill(); $0.fill(first.pageRect.rawValue); list.draw(in: $0.cgContext)
                    }
                    try image.pngData()?.write(to: output.appendingPathComponent("page-\(page.index).png"))
                }
            }
            chapterCount += 1; totalAnnotations += annotations.count
            print("JapaneseVerticalPackage spine=\(index) pages=\(session.completedPages.count) UTF16=\((session.sourceText as NSString).length) ruby=\(annotations.count) size=\(flow.contentSize)")
        }
        #expect(chapterCount == 13)
        #expect(totalAnnotations > 1000)
        print("JapaneseVerticalPackage evidence=\(output.path) chapters=\(chapterCount) annotations=\(totalAnnotations)")
    }
}
