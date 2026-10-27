import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ContinuousScrollRestoreTests {
    enum Source: String, CaseIterable { case txt, markdown, onlineText, onlineHTML }

    private func engine(_ source: Source) -> CoreTextScrollEngine {
        // Short paragraphs deliberately end before the horizontal centre of the
        // viewport. Selection hit-testing is not a reading-position resolver.
        let body = (0..<(source == .markdown ? 900 : 240)).map { "短句\($0)。" }.joined(separator: "\n\n")
        let builder: any AttributedStringBuilding
        switch source {
        case .txt:
            let text = "第1章 起始\n" + body + "\n第2章 繼續\n" + body
            let mapped = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
            builder = TXTLazyAttributedStringBuilder(mappedTextFile: mapped,
                chapterIndexes: TXTChapterParser.parseMappedChapterIndexes(mapped, bookTitle: "Restore"))
        case .markdown:
            builder = MarkdownAttributedStringBuilder(markdown: "# 起始\n\n" + body + "\n\n# 繼續\n\n" + body,
                                                       fallbackTitle: "Restore")
        case .onlineText, .onlineHTML:
            let payloads = (0..<2).map { index in
                ChapterContentPayload(index: index, title: "章節\(index)", plainText: body,
                    body: source == .onlineText ? .plainText(body)
                        : .html(body.components(separatedBy: "\n\n").map { "<p>\($0)</p>" }.joined()),
                    sourceHref: "https://example.invalid/chapter/\(index)")
            }
            builder = OnlineProviderAttributedStringBuilder(provider: RestoreContentProvider(payloads: payloads),
                                                             renderSize: CGSize(width: 390, height: 844))
        }
        return CoreTextScrollEngine(builder: builder, renderSettings: EPUBTestFixtures.renderSettings())
    }

    private func mount(_ engine: CoreTextScrollEngine, position: CoreTextReadingPosition) throws
        -> (UIWindow, CoreTextCollectionScrollViewController, UICollectionView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: position.spineIndex, charOffset: position.charOffset)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        return (window, controller, collection)
    }

    @Test(arguments: Source.allCases)
    func shortLineProgressSurvivesDiskSaveAndColdReopen(source: Source) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let width = scene.coordinateSpace.bounds.width - 24
        let first = engine(source)
        let spine = source == .markdown ? 1 : 0
        await first.start(initialChapter: spine, contentWidth: width, loadAdjacentChapters: false)
        guard case .legacy(let chunk) = try #require(first.chunks.dropFirst().first) else {
            Issue.record("Expected the attributed-string scroll route"); return
        }
        chunk.materializeFrameIfNeeded()
        let lines = CTFrameGetLines(try #require(chunk.frame)) as! [CTLine]
        let line = try #require(lines.dropFirst(8).first)
        let target = CoreTextReadingPosition(spineIndex: spine, charOffset: CTLineGetStringRange(line).location)
        #expect(target.charOffset > chunk.charRange.location)
        let (window, controller, collection) = try mount(first, position: target)
        defer { window.isHidden = true; window.rootViewController = nil }
        var saved: CoreTextReadingPosition?
        controller.onProgressCommit = { saved = $0 }
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        #expect(saved == target, "\(source): a short line must not save the chunk start")

        let bookID = "scroll-restore-test-" + UUID().uuidString
        let path = StorageLocations.readingPosition.appendingPathComponent(bookID + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        await JSONFileReadingPositionStore().save(try #require(saved), for: bookID)
        window.isHidden = true
        window.rootViewController = nil
        let reopened = try #require(JSONFileReadingPositionStore().loadSync(for: bookID))
        let second = engine(source)
        await second.start(initialChapter: reopened.spineIndex, contentWidth: width, loadAdjacentChapters: false)
        let (nextWindow, nextController, nextCollection) = try mount(second, position: reopened)
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        var resaved: CoreTextReadingPosition?
        nextController.onProgressCommit = { resaved = $0 }
        nextController.scrollViewDidEndDragging(nextCollection, willDecelerate: false)
        #expect(resaved == target, "\(source): rebuilding the engine and viewport must preserve the saved line")
    }

    @Test(arguments: Source.allCases)
    func restoreIncludesChapterLeadingSpacing(source: Source) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let engine = engine(source)
        let width = scene.coordinateSpace.bounds.width - 24
        await engine.start(initialChapter: 0, contentWidth: width, loadAdjacentChapters: false)
        await engine.start(initialChapter: 1, contentWidth: width, loadAdjacentChapters: false)
        let row = try #require(engine.chapterRanges[1]?.lowerBound)
        guard case .legacy(let chunk) = engine.chunks[row] else { Issue.record("Expected CoreText"); return }
        chunk.materializeFrameIfNeeded()
        let lines = CTFrameGetLines(try #require(chunk.frame)) as! [CTLine]
        let offset = CTLineGetStringRange(try #require(lines.dropFirst(8).first)).location
        let (window, _, collection) = try mount(engine, position: .init(spineIndex: 1, charOffset: offset))
        defer { window.isHidden = true; window.rootViewController = nil }
        let cell = try #require(collection.cellForItem(at: IndexPath(item: row, section: 0)) as? CoreTextChunkCollectionCell)
        let lineY = try #require(chunk.topOffset(forCharacterIndex: offset))
        let actual = cell.drawView.convert(CGPoint(x: 0, y: lineY), to: collection).y
        let requested = collection.contentOffset.y + collection.adjustedContentInset.top
        #expect(abs(actual - requested) <= 1 / window.screen.scale + 0.001,
                "\(source): restored line displaced by \(actual - requested)pt at a chapter boundary")
    }

    @Test(arguments: Source.allCases)
    func previousChapterArrivalPreservesTheLiveLineAndExitSnapshot(source: Source) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let engine = engine(source)
        let width = scene.coordinateSpace.bounds.width - 24
        await engine.start(initialChapter: 1, contentWidth: width, loadAdjacentChapters: false)
        let (window, controller, collection) = try mount(engine, position: .chapterStart(1))
        defer { window.isHidden = true; window.rootViewController = nil }
        // Move without a scroll-end callback: the held checkpoint is still the
        // opening position when the previous chapter completes.
        collection.setContentOffset(CGPoint(x: 0, y: 431.25), animated: false)
        collection.layoutIfNeeded()
        let position = try #require(controller.positionForPersistence())
        #expect(position.spineIndex == 1)
        #expect(position.charOffset > 0)
        func lineScreenY() throws -> CGFloat {
            let row = try #require(engine.chunkIndex(forChapter: 1, charOffset: position.charOffset))
            let cell = try #require(collection.cellForItem(at: IndexPath(item: row, section: 0)) as? CoreTextChunkCollectionCell)
            let y = try #require(cell.currentChunk?.topOffset(forCharacterIndex: position.charOffset))
            return cell.drawView.convert(CGPoint(x: 0, y: y), to: window).y
        }
        let before = try lineScreenY()
        let retainedViews = collection.visibleCells.compactMap { ($0 as? CoreTextChunkCollectionCell)?.drawView }
        for view in retainedViews { view.layer.displayIfNeeded() }
        let drawCounts = retainedViews.map(\.drawCount)
        await engine.start(initialChapter: 0, contentWidth: width, loadAdjacentChapters: false)
        collection.layoutIfNeeded()
        #expect(abs(try lineScreenY() - before) <= 1 / window.screen.scale + 0.001)
        #expect(controller.positionForPersistence() == position)
        #expect(controller.viewportCommitDiagnostics.insertions > 0)
        #expect(controller.viewportCommitDiagnostics.maximumScreenError <= 1 / window.screen.scale + 0.001)
        for (view, count) in zip(retainedViews, drawCounts) where view.window != nil {
            view.layer.displayIfNeeded()
            #expect(view.drawCount == count, "changing chapter spacing must not redraw unchanged text")
        }
    }
}

private struct RestoreContentProvider: BookContentProvider {
    let payloads: [ChapterContentPayload]
    var totalChapters: Int { payloads.count }
    func chapterTitle(at index: Int) -> String { payloads[index].title }
    func contentForChapter(index: Int) async throws -> ChapterContentPayload { payloads[index] }
}
