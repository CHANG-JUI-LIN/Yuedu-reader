import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Feedback #95/#96 (光遇聚合番茄, paged): on 第97章 the footer lost its N/M counter, one
/// forward turn showed 第96章 1/8, then a 載入中 page titled 第96章, and the book reopened on
/// 第96章. Two routes can put the reader one chapter back; each is pinned here.
@Suite("Shifted TOC and renumbered pages keep the chapter", .serialized)
@MainActor
struct ShiftedTOCChapterIdentityTests {

    // MARK: Chain A — a refreshed table of contents that moved by one entry

    private static func chapters(_ count: Int, insertingAt inserted: Int? = nil) -> [OnlineChapterRef] {
        var refs = (0..<count).map {
            OnlineChapterRef(index: $0, title: "第\($0 + 1)章", url: "https://example.com/c/\($0 + 1)")
        }
        if let inserted {
            refs.insert(OnlineChapterRef(index: 0, title: "作品相关", url: "https://example.com/extra"), at: inserted)
            for i in refs.indices { refs[i].index = i }
        }
        return refs
    }

    private func refresh(
        _ store: BookStore, bookId: UUID, sourceId: UUID, to chapters: [OnlineChapterRef],
        firstPageCount: Int? = nil, positions: any ReadingPositionStore
    ) async throws {
        _ = try await store.refreshOnlineBookMetadata(
            bookId: bookId,
            bookSourceFetcher: FixedTOCFetcher(package: TOCPackage(
                sourceId: sourceId, sourceName: "位移測試", tocURL: "https://example.com/toc",
                runtimeVariables: nil, chapters: chapters, rawHTMLFilename: nil, savedAt: Date()
            ), firstPage: firstPageCount.map { Array(chapters.prefix($0)) }),
            positionStore: positions
        )
        store.waitForQueuedWrites()
    }

    /// nil: the list arrives in one piece. 121: the runtime fetch hands the whole list over as
    /// the first page, so the first-page commit moves the chapters. 30: a partial first page
    /// with the insertion inside it, merged over the stored tail before the rest arrives.
    @Test("a chapter keeps its identity, the reading place and its bookmarks when the refreshed TOC shifts it by one",
          arguments: [nil, 121, 30] as [Int?])
    func shiftedTOCKeepsChapterIdentityByURL(firstPageCount: Int?) async throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "位移測試")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([source])
        defer { BookSourceStore.shared.replaceSources(previousSources) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiftedTOC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var original = Self.chapters(120)
        for i in original.indices { original[i].cachedFilename = "cached-\(i).html" }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = store.addOnlineBook(
            name: "位移書", author: "作者", sourceId: source.id, bookInfoURL: "https://example.com/book",
            tocURL: "https://example.com/toc", runtimeVariables: nil, chapters: original
        )
        let before = try #require(store.chapters(for: book.id))
        let reading = before[96]  // 第97章, where the reader was
        let positions = InMemoryPositions()
        await positions.save(CoreTextReadingPosition(spineIndex: 96, charOffset: 1234), for: book.id.uuidString)
        let onReading = Bookmark(
            chapterIndex: 96, chapterTitle: reading.title,
            position: CoreTextReadingPosition(spineIndex: 96, charOffset: 800), excerpt: "第97章的書籤"
        )
        let beforeInsert = Bookmark(
            chapterIndex: 3, chapterTitle: before[3].title,
            position: CoreTextReadingPosition(spineIndex: 3, charOffset: 0), excerpt: "第4章的書籤"
        )
        store.addBookmark(bookId: book.id, bookmark: onReading)
        store.addBookmark(bookId: book.id, bookmark: beforeInsert)
        var announced: [ChapterRenumbering] = []
        let subscription = store.chapterRenumberings.sink { announced.append($0) }
        defer { subscription.cancel() }

        // The source answers with one extra entry ahead of the reader: every later chapter
        // moves up one index.
        try await refresh(store, bookId: book.id, sourceId: source.id,
                          to: Self.chapters(120, insertingAt: 10), firstPageCount: firstPageCount,
                          positions: positions)

        let after = try #require(store.chapters(for: book.id))
        let moved = try #require(after.first { $0.url == reading.url })
        #expect(moved.index == 97)
        #expect(moved.title == reading.title)
        // Identity follows the chapter, not the slot it used to sit in.
        #expect(moved.id == reading.id, "chapter id stayed with index 96 instead of moving with its URL")
        #expect(after[96].id != reading.id, "index 96 now holds 第96章 but carries 第97章's id")
        // A cached file is named by index, so it does not travel with the chapter.
        #expect(moved.cachedFilename == nil)
        #expect(after[3].cachedFilename == "cached-3.html")

        // The same text from the same source: the place inside the chapter is kept.
        #expect(positions.loadSync(for: book.id.uuidString) == CoreTextReadingPosition(spineIndex: 97, charOffset: 1234))
        let bookmarks = try #require(store.readingBook(id: book.id)?.bookmarks)
        let carried = try #require(bookmarks.first { $0.id == onReading.id })
        #expect(carried.chapterIndex == 97)
        #expect(carried.position == CoreTextReadingPosition(spineIndex: 97, charOffset: 800))
        #expect(carried.excerpt == onReading.excerpt)
        #expect(bookmarks.first { $0.id == beforeInsert.id }?.chapterIndex == 3)
        #expect(announced.contains { $0.moves[96] == 97 })
        let announcedBefore = announced.count

        // Refreshing to the same list again moves nothing and announces nothing.
        try await refresh(store, bookId: book.id, sourceId: source.id,
                          to: Self.chapters(120, insertingAt: 10), positions: positions)
        #expect(positions.loadSync(for: book.id.uuidString)?.spineIndex == 97)
        #expect(announced.count == announcedBefore)
    }

    @Test("an entry inserted at the top leaves an unopened comic unopened and moves an opened one")
    func insertionAtTopKeepsUnopenedImageReaderPlace() {
        let renumbering = ChapterRenumbering(bookId: UUID(), moves: [0: 1, 1: 2, 2: 3])
        var unopened = ReadingBook(title: "漫畫", author: "", source: "online", contentFilename: "")
        unopened.contentPipelineKind = .manga
        renumbering.applyToRecordPlaces(&unopened)
        #expect(unopened.mangaChapterIndex == 0)

        var opened = unopened
        opened.mangaChapterIndex = 2
        opened.mangaPage = 5
        renumbering.applyToRecordPlaces(&opened)
        #expect(opened.mangaChapterIndex == 3)
        #expect(opened.mangaPage == 5)

        var text = ReadingBook(title: "小說", author: "", source: "online", contentFilename: "")
        text.mangaChapterIndex = 0
        renumbering.applyToRecordPlaces(&text)
        #expect(text.mangaChapterIndex == 0 && text.audioChapterIndex == 0)
    }

    @Test("repeated and empty chapter URLs never give two chapters one identity")
    func repeatedAndEmptyURLsKeepIdentitiesDistinct() async throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "位移測試")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([source])
        defer { BookSourceStore.shared.replaceSources(previousSources) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiftedTOC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A 卷 header with no URL, and two chapters sharing one (a site that pages a chapter
        // under the same address).
        let list: (Bool) -> [OnlineChapterRef] = { inserted in
            var refs = [
                OnlineChapterRef(index: 0, title: "第一卷", url: "", isVolume: true),
                OnlineChapterRef(index: 0, title: "第1章", url: "https://example.com/c/1"),
                OnlineChapterRef(index: 0, title: "第2章（上）", url: "https://example.com/c/2"),
                OnlineChapterRef(index: 0, title: "第2章（下）", url: "https://example.com/c/2"),
                OnlineChapterRef(index: 0, title: "第二卷", url: "", isVolume: true),
                OnlineChapterRef(index: 0, title: "第3章", url: "https://example.com/c/3"),
            ]
            if inserted {
                refs.insert(OnlineChapterRef(index: 0, title: "作品相关", url: ""), at: 0)
            }
            for i in refs.indices { refs[i].index = i }
            return refs
        }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = store.addOnlineBook(
            name: "重複網址", author: "作者", sourceId: source.id, bookInfoURL: "https://example.com/book",
            tocURL: "https://example.com/toc", runtimeVariables: nil, chapters: list(false)
        )
        let before = try #require(store.chapters(for: book.id))
        let positions = InMemoryPositions()
        await positions.save(CoreTextReadingPosition(spineIndex: 3, charOffset: 50), for: book.id.uuidString)

        try await refresh(store, bookId: book.id, sourceId: source.id, to: list(true), positions: positions)

        let after = try #require(store.chapters(for: book.id))
        #expect(Set(after.map(\.id)).count == after.count, "two chapters share an id")
        // Both halves of 第2章 keep their own identity, in order.
        #expect(after[3].id == before[2].id)
        #expect(after[4].id == before[3].id)
        #expect(after[6].id == before[5].id)
        // 第2章（下）, where the reader was, moved with the list.
        #expect(positions.loadSync(for: book.id.uuidString) == CoreTextReadingPosition(spineIndex: 4, charOffset: 50))
    }

    // MARK: Chain B — a chapter laid out ahead of the visible one renumbers every page

    @Test("an earlier chapter landing renumbers pages without moving the visible page or the next turn")
    func earlierChapterLayoutKeepsVisiblePageAndNextTurnInItsChapter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: LazyOnlineLikeBuilder(chapterCount: 4),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        let reading = CoreTextReadingPosition.chapterStart(2)
        engine.updateReadingPosition(reading)
        _ = await engine.preloadChapter(at: 2)
        let chapterTwo = try #require(engine.layouts[2])
        try #require(chapterTwo.pageRanges.count > 3)
        // A page in the middle of chapter 2, as the user was on page ~5 of 第97章.
        let local = 2
        let middle = CoreTextReadingPosition(
            spineIndex: 2, charOffset: Int(chapterTwo.pageRanges[local].location)
        )
        engine.updateReadingPosition(middle)

        var boundPage = try #require(engine.pageIndex(for: middle))
        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .slide, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {},
            currentPage: Binding(get: { boundPage }, set: { boundPage = $0 }),
            onPageChanged: { page, _ in boundPage = page }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = pvc
        window.makeKeyAndVisible()
        // The initial stack, as `makeUIViewController` installs it.
        let initial = engine.pageViewController(at: boundPage)
        pvc.setViewControllers([initial], direction: .forward, animated: false)
        coordinator.captureStablePosition(from: initial)
        coordinator.bindEngineCallbacks(to: engine, pageViewController: pvc)

        // Chapters 0 and 1 land: each is longer than the one-page estimate a lazily scanned
        // online chapter starts with, so every page of chapter 2 is renumbered.
        _ = await engine.preloadChapter(at: 1)
        _ = await engine.preloadChapter(at: 0)
        await drainMainQueue()

        let visible = try #require(pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))
        let visiblePosition = engine.localPosition(for: visible.globalPageIndex)
        #expect(visiblePosition.spineIndex == 2, "the visible page's index now points into chapter \(visiblePosition.spineIndex)")
        #expect(visiblePosition.localPage == local)
        #expect(engine.chapterPagination(forSpine: visiblePosition.spineIndex, charOffset: middle.charOffset) != nil)

        // A tap or volume key turns from the reader's bound page, not from the screen.
        #expect(boundPage == visible.globalPageIndex, "bound page \(boundPage) ≠ visible \(visible.globalPageIndex)")
        let next = engine.localPosition(for: boundPage + 1)
        #expect(next.spineIndex == 2 && next.localPage == local + 1,
                "the next turn lands on chapter \(next.spineIndex) page \(next.localPage)")
    }

    private func drainMainQueue() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Online chapters open with a lazy byte scan: every chapter not yet laid out counts as one
/// page, so a chapter landing ahead of the reader shifts every page after it.
private actor LazyOnlineLikeBuilder: AttributedStringBuilding {
    nonisolated let chapterCount: Int
    init(chapterCount: Int) { self.chapterCount = chapterCount }
    nonisolated var prefersLazyByteScan: Bool { true }
    nonisolated func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }
    nonisolated private func text(_ index: Int) -> String {
        String(repeating: "第\(index + 1)章的正文，風穿過山林，江水映著月光。\n", count: 120)
    }
    func chapterDataSize(at index: Int) -> Int { 0 }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                      themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(attributedString: NSAttributedString(string: text(index), attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: themeTextColor,
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}

private final class InMemoryPositions: ReadingPositionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CoreTextReadingPosition] = [:]

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        lock.withLock { storage[bookId] = position }
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        lock.withLock { storage[bookId] }
    }

    func flush(for bookId: String) async {}
}

/// Answers a table-of-contents refresh with a fixed package in one go.
private struct FixedTOCFetcher: BookSourceFetching {
    let package: TOCPackage
    /// Handed to `onFirstPageReady` first, as the live fetcher does.
    var firstPage: [OnlineChapterRef]? = nil

    func fetchBookInfoPackage(
        url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "FixedTOCFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool
    ) async throws -> TOCPackage {
        if let firstPage { onFirstPageReady?(firstPage) }
        return package
    }

    func isChapterCached(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }
    func search(
        query: String, in source: BookSource, earlyFilter: ((String, String) -> Bool)?
    ) async throws -> [OnlineBook] { [] }
    func loadChapterPackageSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> String? { nil }
}
