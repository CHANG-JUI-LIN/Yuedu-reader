import Combine
import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BookStoreSyncEncodingTests {
    @Test func encodedMergePreservesLocalChaptersReadingRecordsAndDurability() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        var shelf = ReadingBook(title: "Local", contentFilename: "book.epub")
        shelf.onlineChapters = [OnlineChapterRef(index: 0, title: "Chapter", url: "https://example.com/1")]
        store.saveReadingBook(shelf)
        var unlisted = ReadingBook(title: "Reading only", contentFilename: "other.txt")
        unlisted.isInBookshelf = false
        unlisted.currentPosition = 0.34
        store.saveReadingBook(unlisted)
        var remote = shelf
        remote.title = "Remote edit"
        remote.currentPosition = 0.72
        remote.onlineChapters = nil
        let revision = store.mutationRevision
        let snapshot = try #require(store.snapshotForSync([remote], expectedMutationRevision: revision))
        var notifications = 0
        let token = store.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        let prepared = try await BookStore.encodeSyncSnapshot(snapshot)
        #expect(notifications == 0 && store.readingBook(id: shelf.id)?.title == "Local")
        #expect(store.applySyncSnapshot(prepared))
        #expect(notifications == 1 && store.mutationRevision == revision + 1)
        #expect(!store.applySyncSnapshot(prepared), "the same result cannot apply twice")
        #expect(notifications == 1)
        let reopened = BookStore(metadataFileURL: url)
        let restored = try #require(reopened.readingBook(id: shelf.id))
        #expect(restored.title == "Remote edit" && restored.currentPosition == 0.72)
        #expect(restored.onlineChapters?.first?.url == "https://example.com/1")
        #expect(reopened.readingBook(id: unlisted.id)?.currentPosition == 0.34)
        #expect(reopened.books.map(\.id) == [shelf.id])
    }

    @Test func lateEncodingCannotOverwriteSilentOrForcedProgress() async throws {
        for force in [false, true] {
            let url = try metadataURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = BookStore(metadataFileURL: url)
            let book = ReadingBook(title: "Reading", contentFilename: "book.txt")
            store.saveReadingBook(book)
            let revision = store.mutationRevision
            let snapshot = try #require(store.snapshotForSync([book], expectedMutationRevision: revision))
            // Deterministically interleave an edit between snapshot and completion.
            // No timing sleeps or race-dependent assertions.
            store.updatePosition(bookId: book.id, position: 0.6, forceSave: force, notifyLibraryViews: false)
            store.waitForQueuedWrites()
            let diskBeforeCompletion = try Data(contentsOf: url)
            let prepared = try await BookStore.encodeSyncSnapshot(snapshot)
            #expect(!store.applySyncSnapshot(prepared))
            #expect(store.snapshotForSync([book], expectedMutationRevision: revision) == nil)
            #expect(store.readingBook(id: book.id)?.currentPosition == 0.6)
            #expect(try Data(contentsOf: url) == diskBeforeCompletion)
            store.updatePosition(bookId: book.id, position: 0.6, forceSave: true, notifyLibraryViews: false)
            #expect(BookStore(metadataFileURL: url).readingBook(id: book.id)?.currentPosition == 0.6)
        }
    }

    @Test func lateEncodingCannotUndoNewRecordOrNewerMerge() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        let book = ReadingBook(title: "Original", contentFilename: "book.epub")
        store.saveReadingBook(book)
        let old = try #require(store.snapshotForSync([book]))
        var added = ReadingBook(title: "Added while encoding", contentFilename: "new.txt")
        added.isInBookshelf = false
        store.saveReadingBook(added)
        let oldPrepared = try await BookStore.encodeSyncSnapshot(old)
        #expect(!store.applySyncSnapshot(oldPrepared))
        var newer = book
        newer.title = "Newest remote"
        let newest = try #require(store.snapshotForSync([newer]))
        let prepared = try await BookStore.encodeSyncSnapshot(newest)
        #expect(store.applySyncSnapshot(prepared))
        #expect(!store.applySyncSnapshot(oldPrepared))
        let reopened = BookStore(metadataFileURL: url)
        #expect(reopened.readingBook(id: book.id)?.title == "Newest remote")
        #expect(reopened.readingBook(id: added.id)?.title == added.title)
    }

    /// Field trace, 3.0.0 (129) on an iPhone 11, a sync on the way to the background:
    /// `library.chapters.write 178ms bytes=20183991 main=true` inside `sync.apply.books`.
    /// Applying a merge waited on the main thread for the write queue, and so behind every
    /// write already queued — the scene's own flush is queued on the same trip — while the
    /// 10 s scene-update watchdog was counting.
    @Test func applyingAMergeDoesNotWaitForTheWriteQueue() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        let book = ReadingBook(title: "Local", contentFilename: "book.epub")
        store.saveReadingBook(book)
        store.waitForQueuedWrites()
        var remote = book
        remote.title = "Remote"
        let snapshot = try #require(store.snapshotForSync([remote], expectedMutationRevision: store.mutationRevision))
        let prepared = try await BookStore.encodeSyncSnapshot(snapshot)

        // A slow write already on the serial queue, released once the apply has returned.
        let release = DispatchSemaphore(value: 0)
        BookStore.persistQueue.async { _ = release.wait(timeout: .now() + 2) }
        let start = SourcePerfTrace.now
        #expect(store.applySyncSnapshot(prepared))
        let mainMs = (SourcePerfTrace.now - start) * 1000
        release.signal()
        print("[SyncApply] main thread held \(Int(mainMs)) ms behind a 2000 ms queued write")

        #expect(mainMs < 500, "the main thread waited \(Int(mainMs)) ms for the write queue")
        #expect(store.readingBook(id: book.id)?.title == "Remote")
        store.waitForQueuedWrites()
        #expect(BookStore(metadataFileURL: url).readingBook(id: book.id)?.title == "Remote")
    }

    @Test func largeMetadataEncodingLeavesOnlyApplicationOnMain() async throws {
        let url = try metadataURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: url)
        var book = ReadingBook(title: "Encoding fixture", contentFilename: "book.epub")
        book.onlineChapters = (0..<4_000).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://example.com/\($0)")
        }
        store.saveReadingBook(book)
        var oldMainMS: [Double] = [], newMainMS: [Double] = []
        // Alternating order, same JSON shape and actual changed values on every pass.
        // This measures main-thread work, not device FPS or async completion latency.
        for scoped in [false, true, true, false] {
            book.title += "x"
            let start = SourcePerfTrace.now
            if scoped {
                let snapshot = try #require(store.snapshotForSync([book]))
                let snapshotTime = SourcePerfTrace.now - start
                let prepared = try await BookStore.encodeSyncSnapshot(snapshot)
                let applyStart = SourcePerfTrace.now
                #expect(store.applySyncSnapshot(prepared))
                newMainMS.append((snapshotTime + SourcePerfTrace.now - applyStart) * 1000)
            } else {
                #expect(store.replaceBooksFromSync([book]))
                oldMainMS.append((SourcePerfTrace.now - start) * 1000)
            }
            SourcePerfTrace.record("test.sync.encoding", "background=\(scoped)", since: start, thresholdMs: 0)
        }
        print("[SyncEncoding] chapters=4000 oldMainMs=\(oldMainMS) preparedMainMs=\(newMainMS)")
        #expect(BookStore(metadataFileURL: url).readingBook(id: book.id)?.onlineChapters?.count == 4_000)
    }

    private func metadataURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncEncoding-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("books.json")
    }
}
