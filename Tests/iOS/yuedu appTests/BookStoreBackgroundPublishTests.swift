import Combine
import Foundation
import os
import Testing
@testable import yuedu_app

/// Background producers — the launch refresh, a download — must not publish the store to
/// every view on it per step: a 2000-chapter table-of-contents refresh used to publish
/// seven times and normalize every title on the main thread, and a download published
/// twice per chapter.
@Suite("BookStore publishes once per background change", .serialized)
struct BookStoreBackgroundPublishTests {
    private func makeStore() -> (store: BookStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreBackgroundPublishTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json")), directory)
    }

    private func chapters(_ count: Int, titlePrefix: String = "第") -> [OnlineChapterRef] {
        (0..<count).map {
            OnlineChapterRef(index: $0, title: "\(titlePrefix) \($0 + 1) 章", url: "https://example.com/c\($0 + 1)")
        }
    }

    @Test("marking a chapter cached does not publish the store")
    @MainActor
    func cacheMarkDoesNotPublish() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = store.addOnlineBook(
            name: "書", author: "作者", sourceId: UUID(), bookInfoURL: "https://example.com/book",
            tocURL: "https://example.com/toc", runtimeVariables: nil, chapters: chapters(5)
        )
        let publications = OSAllocatedUnfairLock(initialState: 0)
        let subscription = store.objectWillChange.sink { publications.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        store.updateCachedChapter(bookId: book.id, chapterIndex: 2, filename: "2.html")
        store.updateCachedChapter(bookId: book.id, chapterIndex: 2, filename: "2.html")

        #expect(publications.withLock { $0 } == 0)
        #expect(store.chapters(for: book.id)?[2].cachedFilename == "2.html")
        #expect(store.readingBook(id: book.id)?.onlineChapters?[2].cachedFilename == "2.html")
    }

    @Test("a table-of-contents refresh replaces the record once, and not at all when nothing changed")
    func refreshPublishesOnce() async throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "測試書源")
        let previousSources = await MainActor.run { BookSourceStore.shared.sources }
        await MainActor.run { BookSourceStore.shared.sources = [source] }
        defer { Task { @MainActor in BookSourceStore.shared.sources = previousSources } }

        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = chapters(3)
        let book = await MainActor.run {
            store.addOnlineBook(
                name: "測試書", author: "作者", sourceId: source.id, bookInfoURL: "https://example.com/book",
                tocURL: "https://example.com/toc", runtimeVariables: ["token": "final"], chapters: existing
            )
        }
        let publications = OSAllocatedUnfairLock(initialState: 0)
        let subscription = await MainActor.run {
            store.objectWillChange.sink { publications.withLock { $0 += 1 } }
        }
        defer { subscription.cancel() }

        func package(_ list: [OnlineChapterRef]) -> TOCPackage {
            TOCPackage(
                sourceId: source.id, sourceName: source.bookSourceName, tocURL: "https://example.com/toc",
                runtimeVariables: ["token": "final"], chapters: list, rawHTMLFilename: nil, savedAt: Date()
            )
        }

        // Same list again: nothing to publish.
        _ = try await store.refreshOnlineBookMetadata(
            bookId: book.id, bookSourceFetcher: ImmediateTOCFetcher(package: package(existing))
        )
        #expect(publications.withLock { $0 } == 0)

        // A new chapter: the record is replaced once, with the merged list and the badge.
        let refreshed = try await store.refreshOnlineBookMetadata(
            bookId: book.id, bookSourceFetcher: ImmediateTOCFetcher(package: package(chapters(4)))
        )
        #expect(refreshed.onlineChapters?.count == 4)
        #expect(refreshed.hasNewChapterUpdate == true)
        #expect(publications.withLock { $0 } == 1)
    }
}

/// Answers a table-of-contents refresh with a fixed package in one go, as a single-page
/// table of contents arrives.
private struct ImmediateTOCFetcher: BookSourceFetching {
    let package: TOCPackage

    func fetchBookInfoPackage(
        url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "ImmediateTOCFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool
    ) async throws -> TOCPackage {
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
