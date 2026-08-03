import Foundation
import Testing
@testable import yuedu_app

@Suite("BookStore metadata write budget", .serialized)
struct BookStoreMetadataWriteBudgetTests {
    @Test("tiny progress changes stay in memory until a forced save")
    @MainActor
    func tinyProgressChangesStayInMemoryUntilForcedSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)

        var book = ReadingBook(title: "Long Online Book", author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.onlineChapters = (0..<2_000).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://example.com/\($0)")
        }

        store.replaceBooksFromSync([book])
        let initialData = try Data(contentsOf: metadataURL)

        store.updatePosition(bookId: book.id, position: 0.0001)

        #expect(store.books.first?.currentPosition == 0.0001)
        #expect(try Data(contentsOf: metadataURL) == initialData)

        store.updatePosition(bookId: book.id, position: 0.0001, forceSave: true)

        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(saved.first?.currentPosition == 0.0001)
    }

    @Test("removing a download announces that the chapter cache is gone")
    @MainActor
    func clearingDownloadAnnouncesCacheClear() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        var book = ReadingBook(title: "已下載的線上書", author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "第一章", url: "https://example.com/1")
        ]
        store.replaceBooksFromSync([book])

        let roots = OfflineStorageRoots(
            textRoot: directory.appendingPathComponent("text", isDirectory: true),
            mangaRoot: directory.appendingPathComponent("manga", isDirectory: true)
        )

        // An open reader keeps `.ready` chapter states for the files this deletes. Without
        // the announcement nothing tells it, and it renders 資料不一致 over a chapter it
        // could just refetch — the reproducible 下載 → 暫停 → 移除 path.
        try await confirmation("cache clear announced") { announced in
            let observer = NotificationCenter.default.addObserver(
                forName: .onlineChapterCacheDidClear,
                object: nil,
                queue: .main
            ) { notification in
                if notification.userInfo?["bookId"] as? UUID == book.id {
                    announced()
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            try await store.clearOnlineDownload(
                bookId: book.id,
                offlineChapterStore: OfflineChapterStore(roots: roots)
            )
        }
    }

    @Test("completed offline download persists without waiting for debounce")
    @MainActor
    func completedOfflineDownloadPersistsImmediately() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)

        var book = ReadingBook(title: "Offline Book", author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "Chapter 1", url: "https://example.com/1")
        ]
        store.replaceBooksFromSync([book])

        let completedTask = BookOfflineDownloadTask(
            startChapterIndex: 0,
            endChapterIndex: 0,
            completedChapterCount: 1
        )
        store.setOfflineDownloadState(
            bookId: book.id,
            state: .available,
            downloadedChapterCount: 1,
            offlineDownloadTask: completedTask
        )

        let reloaded = BookStore(metadataFileURL: metadataURL)
        let persistedBook = try #require(reloaded.books.first)
        #expect(persistedBook.offlineDownloadState == .available)
        #expect(persistedBook.downloadedChapterCount == 1)
        #expect(persistedBook.offlineDownloadTask?.completedChapterCount == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreMetadataWriteBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
