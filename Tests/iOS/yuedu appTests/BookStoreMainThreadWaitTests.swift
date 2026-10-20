import Foundation
import Testing
@testable import yuedu_app

/// The main thread must not wait behind `BookStore.persistQueue`: every write already queued
/// — the scene's own flush on the way to the background among them — runs first, while the
/// 10 s scene-update watchdog is counting (field trace in
/// `BookStoreSyncEncodingTests.applyingAMergeDoesNotWaitForTheWriteQueue`).
/// Each test holds the shared queue for up to 2 s and measures how long the main thread is
/// kept from running again.
@Suite(.serialized)
@MainActor
struct BookStoreMainThreadWaitTests {
    /// 移除遠端書庫的書：the reading record is written before the shelf that no longer lists it.
    @Test func removingARemoteReferenceDoesNotWaitForTheWriteQueue() throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        var book = ReadingBook(title: "Remote", source: "local", contentFilename: "\(UUID().uuidString).epub")
        book.remoteSource = RemoteBookReference(
            connectionID: "test-connection", entryID: "1",
            format: RemoteLibraryFormat(url: URL(string: "https://example.com/1.epub")!,
                                        fileExtension: "epub", mimeType: "application/epub+zip")
        )
        store.saveReadingBook(book)
        store.waitForQueuedWrites()

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        BookStore.persistQueue.async { _ = release.wait(timeout: .now() + 2) }
        let start = SourcePerfTrace.now
        store.delete(bookId: book.id)
        let mainMs = (SourcePerfTrace.now - start) * 1000
        release.signal()
        print("[MainWait] remote reference removal: main thread held \(Int(mainMs)) ms behind a 2000 ms queued write")

        #expect(mainMs < 500, "the main thread waited \(Int(mainMs)) ms for the write queue")
        #expect(store.books.isEmpty)
        store.waitForQueuedWrites()
        let reopened = BookStore(metadataFileURL: url)
        #expect(reopened.books.isEmpty)
        #expect(reopened.readingBook(id: book.id)?.isInBookshelf == false, "the record stays as a reading record")
    }

    /// TXT 重新分章: the moved bookmarks are published only once the shelf holding them is on
    /// disk, and that wait must not hold the main thread.
    @Test func committingMovedTXTBookmarksDoesNotHoldTheMainThread() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        let original = [Bookmark(chapterIndex: 3, chapterTitle: "第三章", position: CoreTextReadingPosition(spineIndex: 3, charOffset: 10))]
        let migrated = [Bookmark(chapterIndex: 5, chapterTitle: "第三章", position: CoreTextReadingPosition(spineIndex: 5, charOffset: 10))]
        var book = ReadingBook(title: "TXT", contentFilename: "\(UUID().uuidString).txt")
        book.bookmarks = original
        store.saveReadingBook(book)
        store.waitForQueuedWrites()

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        BookStore.persistQueue.async { _ = release.wait(timeout: .now() + 2) }
        let start = SourcePerfTrace.now
        let commit = Task { try await store.commitTXTBookmarks(bookId: book.id, original: original, migrated: migrated) }
        await Task.yield()
        let mainMs = (SourcePerfTrace.now - start) * 1000
        // A save made while the write is in flight carries the moved bookmarks, not the old ones.
        store.updatePosition(bookId: book.id, position: 0.5, forceSave: true, notifyLibraryViews: false)
        release.signal()
        try await commit.value
        print("[MainWait] TXT bookmark commit: main thread held \(Int(mainMs)) ms behind a 2000 ms queued write")

        #expect(mainMs < 500, "the main thread waited \(Int(mainMs)) ms for the write queue")
        #expect(store.readingBook(id: book.id)?.bookmarks == migrated)
        store.waitForQueuedWrites()
        let reopened = try #require(BookStore(metadataFileURL: url).readingBook(id: book.id))
        #expect(reopened.bookmarks == migrated)
        #expect(reopened.currentPosition == 0.5)
    }

    /// iCloud／WebDAV 還原 replaces the shelf file and reloads it; a write still queued finishes
    /// first, without the main thread standing behind it.
    @Test func reloadingARestoredShelfDoesNotHoldTheMainThread() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        let book = ReadingBook(title: "Before restore", contentFilename: "\(UUID().uuidString).epub")
        store.saveReadingBook(book)
        store.waitForQueuedWrites()
        let restored = ReadingBook(title: "Restored", contentFilename: "\(UUID().uuidString).epub")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode([restored]).write(to: url, options: .atomic)

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        BookStore.persistQueue.async { _ = release.wait(timeout: .now() + 2) }
        let start = SourcePerfTrace.now
        let reload = Task { await store.reloadFromDisk() }
        await Task.yield()
        let mainMs = (SourcePerfTrace.now - start) * 1000
        release.signal()
        await reload.value
        print("[MainWait] restore reload: main thread held \(Int(mainMs)) ms behind a 2000 ms queued write")

        #expect(mainMs < 500, "the main thread waited \(Int(mainMs)) ms for the write queue")
        #expect(store.books.map(\.id) == [restored.id])
        store.waitForQueuedWrites()
        #expect(BookStore(metadataFileURL: url).books.map(\.id) == [restored.id])
    }

    private func metadataURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MainThreadWait-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("books.json")
    }
}
