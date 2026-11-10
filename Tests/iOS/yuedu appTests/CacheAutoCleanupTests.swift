import Foundation
import Testing
@testable import yuedu_app

/// Automatic cache cleanup (feedback #47, #129): least recently used first under a size cap,
/// never a downloaded shelf book, an open book, an imported book or a reading position.
@Suite("Cache auto cleanup", .serialized)
struct CacheAutoCleanupTests {
    // MARK: - Policy

    @Test("caches within the cap lose nothing")
    func withinCapKeepsEverything() {
        let candidates = [candidate("a", bytes: 400, age: 300), candidate("b", bytes: 600, age: 100)]
        #expect(CacheEvictionPolicy.victims(of: candidates, limit: 1_000).isEmpty)
    }

    @Test("over the cap, the least recently used go first, down to four fifths")
    func overCapTrimsOldestFirst() {
        let candidates = [
            candidate("new", bytes: 400, age: 100),
            candidate("old", bytes: 400, age: 300),
            candidate("middle", bytes: 400, age: 200),
        ]
        // 1 200 over a 1 000 cap trims to 800: only the oldest goes.
        #expect(CacheEvictionPolicy.victims(of: candidates, limit: 1_000).map(\.name) == ["old"])
        // 1 200 over a 500 cap trims to 400: all but the newest.
        #expect(CacheEvictionPolicy.victims(of: candidates, limit: 500).map(\.name) == ["old", "middle"])
    }

    // MARK: - What the service lists and deletes

    @Test("a downloaded shelf book's chapters stay, however old; an unkept one goes")
    @MainActor
    func keptBooksAreNeverEvicted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloaded = UUID()
        let previewed = UUID()
        let downloadedDir = try fixture.bookDirectory(fixture.roots.chapters, downloaded, bytes: 600, age: 10_000)
        let previewedDir = try fixture.bookDirectory(fixture.roots.chapters, previewed, bytes: 600, age: 100)
        let service = fixture.service(retention: CacheRetention(keptBooks: [downloaded], lastOpened: [:]))

        let report = await service.trimAutomaticCaches(toLimit: 500, reason: "test")

        #expect(FileManager.default.fileExists(atPath: downloadedDir.path))
        #expect(!FileManager.default.fileExists(atPath: previewedDir.path))
        // The kept book is not even counted against the cap.
        #expect(report.candidateBytes == 600)
        #expect(report.removedCount == 1)
    }

    @Test("a book opened recently outlives one with newer files")
    @MainActor
    func lastOpenedCountsAsUse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rereading = UUID()
        let other = UUID()
        let rereadDir = try fixture.bookDirectory(fixture.roots.chapters, rereading, bytes: 400, age: 10_000)
        let otherDir = try fixture.bookDirectory(fixture.roots.chapters, other, bytes: 400, age: 500)
        let service = fixture.service(retention: CacheRetention(
            keptBooks: [],
            lastOpened: [rereading: Date().addingTimeInterval(-10)]
        ))

        await service.trimAutomaticCaches(toLimit: 700, reason: "test")

        #expect(FileManager.default.fileExists(atPath: rereadDir.path))
        #expect(!FileManager.default.fileExists(atPath: otherDir.path))
    }

    @Test("with the shelf unknown, no book's cache is touched but covers still trim")
    @MainActor
    func unknownShelfKeepsBookCaches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let book = try fixture.bookDirectory(fixture.roots.chapters, UUID(), bytes: 900, age: 10_000)
        let manga = try fixture.bookDirectory(fixture.roots.mangaImages, UUID(), bytes: 900, age: 10_000)
        let oldCover = try fixture.file(fixture.roots.networkCovers, "old", bytes: 400, age: 300)
        let newCover = try fixture.file(fixture.roots.networkCovers, "new", bytes: 400, age: 100)
        let service = fixture.service(retention: nil)

        let report = await service.trimAutomaticCaches(toLimit: 500, reason: "test")

        #expect(!report.consideredBooks)
        #expect(FileManager.default.fileExists(atPath: book.path))
        #expect(FileManager.default.fileExists(atPath: manga.path))
        #expect(!FileManager.default.fileExists(atPath: oldCover.path))
        #expect(FileManager.default.fileExists(atPath: newCover.path))
    }

    @Test("a remote book being read keeps its cached file")
    @MainActor
    func activeRemoteBookIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = RemoteLibraryCache(root: fixture.roots.remoteBooks)
        let active = UUID()
        let idle = UUID()
        let activeDir = try fixture.bookDirectory(fixture.roots.remoteBooks, active, bytes: 600, age: 10_000)
        let idleDir = try fixture.bookDirectory(fixture.roots.remoteBooks, idle, bytes: 600, age: 100)
        cache.retain(active)
        defer { cache.release(active) }
        let service = fixture.service(retention: CacheRetention(keptBooks: [], lastOpened: [:]), remote: cache)

        await service.trimAutomaticCaches(toLimit: 500, reason: "test")

        #expect(FileManager.default.fileExists(atPath: activeDir.path))
        #expect(!FileManager.default.fileExists(atPath: idleDir.path))
    }

    @Test("a cached table of contents goes with its fingerprint, as one")
    @MainActor
    func tableOfContentsFilesGoTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldList = try fixture.file(fixture.roots.tableOfContents, "aaa.json", bytes: 300, age: 300)
        let oldPrint = try fixture.file(fixture.roots.tableOfContents, "aaa.sha256", bytes: 100, age: 300)
        let newList = try fixture.file(fixture.roots.tableOfContents, "bbb.json", bytes: 300, age: 100)
        let newPrint = try fixture.file(fixture.roots.tableOfContents, "bbb.sha256", bytes: 100, age: 100)
        let service = fixture.service(retention: CacheRetention(keptBooks: [], lastOpened: [:]))

        let candidates = service.automaticCleanupCandidates(retention: CacheRetention(keptBooks: [], lastOpened: [:]))
        #expect(candidates.count == 2)
        await service.trimAutomaticCaches(toLimit: 700, reason: "test")

        #expect(!FileManager.default.fileExists(atPath: oldList.path))
        #expect(!FileManager.default.fileExists(atPath: oldPrint.path))
        #expect(FileManager.default.fileExists(atPath: newList.path))
        #expect(FileManager.default.fileExists(atPath: newPrint.path))
    }

    @Test("imported books, saved covers, reading positions and diagnostics are never candidates")
    @MainActor
    func ownedFilesAreOutsideCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let imported = try fixture.file(fixture.documents, "book.epub", bytes: 5_000, age: 10_000)
        let position = try fixture.file(fixture.readingPositions, "\(UUID().uuidString).json", bytes: 5_000, age: 10_000)
        let shelfCover = try fixture.file(fixture.roots.covers, "cover.jpg", bytes: 5_000, age: 10_000)
        let log = try fixture.file(fixture.roots.diagnostics, "log.txt", bytes: 5_000, age: 10_000)
        let cached = try fixture.bookDirectory(fixture.roots.chapters, UUID(), bytes: 600, age: 100)
        let service = fixture.service(retention: CacheRetention(keptBooks: [], lastOpened: [:]))

        let report = await service.trimAutomaticCaches(toLimit: 1, reason: "test")

        #expect(report.candidateBytes == 600)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        for kept in [imported, position, shelfCover, log] {
            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
    }

    // MARK: - What the shelf keeps

    @Test("the shelf keeps downloaded books and open books, not books it only read online")
    @MainActor
    func bookStoreRetention() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheAutoCleanupTests-shelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        func online(_ title: String) -> ReadingBook {
            var book = ReadingBook(title: title, author: "A", contentFilename: "")
            book.isOnline = true
            book.contentPipelineKind = .html
            return book
        }
        let downloaded = online("Downloaded")
        let readOnline = online("Read online")
        var opened = online("Open in reader")
        opened.lastOpenedDate = Date(timeIntervalSince1970: 1_000)
        store.replaceBooksFromSync([downloaded, readOnline, opened])
        store.setOfflineDownloadState(bookId: downloaded.id, state: .available, downloadedChapterCount: 3)
        let previewID = UUID()
        let owner = UUID()
        ReadingResourceUsage.shared.retain(bookID: previewID, ownerID: owner)
        defer { ReadingResourceUsage.shared.release(bookID: previewID, ownerID: owner) }

        let retention = try #require(store.cacheRetention())

        #expect(retention.keptBooks.contains(downloaded.id))
        #expect(retention.keptBooks.contains(previewID))
        #expect(!retention.keptBooks.contains(readOnline.id))
        #expect(retention.lastOpened[opened.id] == Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - When checks run

    @Test("writes start a check only once they add up to the interval")
    @MainActor
    func writesTriggerChecksAtTheInterval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = try fixture.bookDirectory(fixture.roots.chapters, UUID(), bytes: 600, age: 10_000)
        let fresh = try fixture.bookDirectory(fixture.roots.chapters, UUID(), bytes: 600, age: 100)
        let cleaner = CacheAutoCleaner(limitBytes: { 1_000 })
        cleaner.bind(fixture.service(retention: CacheRetention(keptBooks: [], lastOpened: [:])))
        // Bound only now: the first check of a run is the launch one.
        await cleaner.requestCheck(reason: "launch")?.value
        #expect(!FileManager.default.fileExists(atPath: stale.path))

        try fixture.bookDirectory(fixture.roots.chapters, UUID(), bytes: 600, age: 50)
        #expect(cleaner.noteWrite(bytes: Int(CacheAutoCleaner.checkInterval) - 1) == nil)
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        let check = try #require(cleaner.noteWrite(bytes: 1))
        await check.value
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Fixture

    private func candidate(_ name: String, bytes: Int64, age: TimeInterval) -> CacheEvictionCandidate {
        CacheEvictionCandidate(
            items: [URL(fileURLWithPath: "/cache/\(name)")],
            bytes: bytes,
            lastUsed: Date().addingTimeInterval(-age)
        )
    }

    private struct Fixture {
        let container: URL
        let roots: CacheStorageRoots
        let documents: URL
        let readingPositions: URL

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("CacheAutoCleanupTests-\(UUID().uuidString)", isDirectory: true)
            roots = CacheStorageRoots(
                chapters: container.appendingPathComponent("online_cache", isDirectory: true),
                ttsAudio: container.appendingPathComponent("tts", isDirectory: true),
                mangaImages: container.appendingPathComponent("manga", isDirectory: true),
                covers: container.appendingPathComponent("Covers", isDirectory: true),
                diagnostics: container.appendingPathComponent("diagnostics", isDirectory: true)
            )
            documents = container.appendingPathComponent("Documents", isDirectory: true)
            readingPositions = container.appendingPathComponent("reading_position", isDirectory: true)
            for directory in CacheCategory.allCases.map({ roots[$0] })
                + [roots.networkCovers, roots.homeFeeds, roots.tableOfContents, roots.bookInfo, documents, readingPositions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }

        @MainActor
        func service(retention: CacheRetention?, remote: RemoteLibraryCache? = nil) -> CacheManagementService {
            CacheManagementService(
                coverOwner: SavedCoverOwnerStub(),
                retentionOwner: CacheRetentionStub(retention),
                roots: roots,
                diagnosticLog: nil,
                remoteLibraryCache: remote ?? RemoteLibraryCache(root: roots.remoteBooks)
            )
        }

        /// A file of `bytes` last modified `age` seconds ago.
        @discardableResult
        func file(_ directory: URL, _ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 7, count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
            )
            return url
        }

        /// A book's directory holding one chapter, everything in it `age` seconds old.
        @discardableResult
        func bookDirectory(_ root: URL, _ id: UUID, bytes: Int, age: TimeInterval) throws -> URL {
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try file(directory, "0.txt", bytes: bytes, age: age)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: directory.path
            )
            return directory
        }
    }
}

private extension CacheEvictionCandidate {
    var name: String { items.first?.lastPathComponent ?? "" }
}
