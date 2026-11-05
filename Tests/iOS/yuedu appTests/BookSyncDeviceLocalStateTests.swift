import Foundation
import Testing
@testable import yuedu_app

/// Feedback #6: read to 15% on the iPhone, and the iPad, untouched, still showed the start.
/// A field the iPad set on its own — a launch refresh's new-chapter badge, a download, a
/// remote file revalidated — changed its book's sync hash, the merge stamped that copy `now`,
/// and its stale progress won over the iPhone's. These drive the merge as two devices would.
@Suite("Book sync keeps device-local state out of the hash", .serialized)
struct BookSyncDeviceLocalStateTests {
    private let lastSync = Date(timeIntervalSince1970: 1_700_000_000)

    private func hash(_ book: ReadingBook) -> String {
        ICloudSyncManager.stableHash(book.strippedForSync())
    }

    /// A book as the record file holds it: decoded from its own encoding.
    private func roundTripped(_ book: ReadingBook) throws -> ReadingBook {
        try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book))
    }

    private func sharedBook() throws -> ReadingBook {
        var book = ReadingBook(title: "書源小說", author: "作者", source: "https://example.com/book/1", contentFilename: "")
        book.isOnline = true
        book.currentPosition = 0
        book.lastOpenedDate = lastSync
        book.addedDate = lastSync.addingTimeInterval(-86_400)
        return try roundTripped(book)
    }

    private func remoteLibraryBook() throws -> ReadingBook {
        var book = ReadingBook(title: "遠端書庫的書", author: "作者", source: "local_epub", contentFilename: "")
        book.remoteSource = RemoteBookReference(
            connectionID: "connection", entryID: "entry",
            format: RemoteLibraryFormat(url: try #require(URL(string: "https://example.com/book.epub")),
                                        fileExtension: "epub", mimeType: "application/epub+zip"),
            offlineFilename: "offline.epub"
        )
        book.contentFilename = "offline.epub"
        book.lastOpenedDate = lastSync
        book.addedDate = lastSync.addingTimeInterval(-86_400)
        return try roundTripped(book)
    }

    /// Each change a device makes to a book without the reader doing anything with it.
    private static let deviceLocalChanges: [(String, @Sendable (inout ReadingBook) -> Void)] = [
        ("new-chapter badge from a launch refresh", { $0.hasNewChapterUpdate = true }),
        ("download state", { $0.offlineDownloadState = .partial }),
        ("downloaded chapter count", { $0.downloadedChapterCount = 25 }),
        ("download task", {
            var task = BookOfflineDownloadTask(requestedIndices: Set(0..<40), now: Date(timeIntervalSince1970: 1_700_000_500))
            task.completedIndices = Set(0..<25)
            $0.offlineDownloadTask = task
        }),
        ("automatic quarantine", { $0.compatibilityState = .quarantined }),
    ]

    private func merge(local: ReadingBook, remote: ReadingBook, remoteUpdatedAt: Date,
                       shadowHash: String, now: Date)
        -> (values: [ReadingBook], shadow: [String: SyncShadowEntry], shouldApplyLocally: Bool) {
        let key = local.id.uuidString
        return ICloudSyncManager.resolveMerge(
            local: [local],
            remote: [FirestoreSyncRecord(id: key, value: remote, updatedAt: remoteUpdatedAt, deleted: false)],
            shadow: [key: SyncShadowEntry(updatedAt: lastSync, hash: shadowHash, deleted: false)],
            id: { $0.id.uuidString },
            hash: hash,
            fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
            now: now
        )
    }

    /// The iPhone reads to 15% and syncs; the iPad changes only its own state, opens nothing,
    /// and syncs later. The iPad ends with 15%, and keeps its own state.
    @Test(arguments: 0..<deviceLocalChanges.count)
    func progressReadElsewhereBeatsADeviceLocalChange(change: Int) throws {
        let (name, apply) = Self.deviceLocalChanges[change]
        let book = try sharedBook()
        let shadowHash = hash(book)

        var iPhone = book
        iPhone.currentPosition = 0.15
        let readAt = lastSync.addingTimeInterval(3_600)
        iPhone.lastOpenedDate = readAt
        let uploaded = iPhone.strippedForSync()

        var iPad = book
        apply(&iPad)
        let iPadSyncs = readAt.addingTimeInterval(3_600)
        let result = merge(local: iPad, remote: uploaded, remoteUpdatedAt: readAt,
                           shadowHash: shadowHash, now: iPadSyncs)

        #expect(result.values.map(\.currentPosition) == [0.15], "\(name)")
        #expect(result.shouldApplyLocally, "\(name)")

        // The same sync hashed as builds before 2026-11-05 hashed: the iPad's copy wins.
        let key = book.id.uuidString
        let before = ICloudSyncManager.resolveMerge(
            local: [iPad],
            remote: [FirestoreSyncRecord(id: key, value: iPhone, updatedAt: readAt, deleted: false)],
            shadow: [key: SyncShadowEntry(updatedAt: lastSync, hash: oldHash(book), deleted: false)],
            id: { $0.id.uuidString },
            hash: oldHash,
            fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
            now: iPadSyncs
        )
        #expect(before.values.map(\.currentPosition) == [0], "the old hash reproduces feedback #6: \(name)")

        let applied = try #require(result.values.first).withDeviceLocalState(of: iPad)
        #expect(applied.currentPosition == 0.15, "\(name)")
        #expect(applied.strippedForSync() == uploaded, "\(name)")
        #expect(applied.hasNewChapterUpdate == iPad.hasNewChapterUpdate, "\(name)")
        #expect(applied.offlineDownloadState == iPad.offlineDownloadState, "\(name)")
        #expect(applied.downloadedChapterCount == iPad.downloadedChapterCount, "\(name)")
        #expect(applied.offlineDownloadTask == iPad.offlineDownloadTask, "\(name)")
        #expect(applied.compatibilityState == iPad.compatibilityState, "\(name)")
    }

    /// A remote library's file revalidated on the iPad is the iPad's cache, not an edit.
    @Test func aRevalidatedRemoteFileDoesNotBeatProgressReadElsewhere() throws {
        let book = try remoteLibraryBook()
        let shadowHash = hash(book)

        var iPhone = book
        iPhone.currentPosition = 0.15
        let readAt = lastSync.addingTimeInterval(3_600)
        iPhone.lastOpenedDate = readAt

        var iPad = book
        iPad.remoteSource?.version = "v2"
        iPad.remoteSource?.entityTag = "\"etag-2\""
        iPad.remoteSource?.lastModified = "Wed, 05 Nov 2026 08:00:00 GMT"
        iPad.remoteSource?.contentLength = 1_234
        iPad.remoteSource?.cachedFilename = "remote-cache.epub"
        iPad.contentFilename = "remote-cache.epub"

        let result = merge(local: iPad, remote: iPhone.strippedForSync(), remoteUpdatedAt: readAt,
                           shadowHash: shadowHash, now: readAt.addingTimeInterval(3_600))
        #expect(result.values.map(\.currentPosition) == [0.15])
        let applied = try #require(result.values.first).withDeviceLocalState(of: iPad)
        #expect(applied.contentFilename == "remote-cache.epub")
        #expect(applied.remoteSource == iPad.remoteSource)
    }

    /// The reverse: progress really read on the iPad, after the iPhone's, still wins.
    @Test func progressReadLaterOnThisDeviceStillWins() throws {
        let book = try sharedBook()
        let shadowHash = hash(book)

        var iPhone = book
        iPhone.currentPosition = 0.15
        let iPhoneRead = lastSync.addingTimeInterval(3_600)
        iPhone.lastOpenedDate = iPhoneRead

        var iPad = book
        iPad.hasNewChapterUpdate = true
        iPad.currentPosition = 0.30
        let iPadRead = iPhoneRead.addingTimeInterval(600)
        iPad.lastOpenedDate = iPadRead

        let result = merge(local: iPad, remote: iPhone.strippedForSync(), remoteUpdatedAt: iPhoneRead,
                           shadowHash: shadowHash, now: iPadRead.addingTimeInterval(60))
        #expect(result.values.map(\.currentPosition) == [0.30])
        #expect(try #require(result.shadow[book.id.uuidString]).updatedAt > iPhoneRead)
    }

    /// What leaves a device carries none of its own state.
    @Test func theUploadedBookCarriesNoDeviceLocalState() throws {
        let untouched = try remoteLibraryBook()
        var book = untouched
        for (_, apply) in Self.deviceLocalChanges { apply(&book) }
        book.remoteSource?.cachedFilename = "remote-cache.epub"
        book.remoteSource?.version = "v2"
        book.contentFilename = "remote-cache.epub"

        let uploaded = book.strippedForSync()
        #expect(!uploaded.hasNewChapterUpdate)
        #expect(uploaded.offlineDownloadState == .none)
        #expect(uploaded.downloadedChapterCount == 0)
        #expect(uploaded.offlineDownloadTask == nil)
        #expect(uploaded.compatibilityState == .defaultWeb)
        #expect(uploaded.remoteSource?.cachedFilename == nil)
        #expect(uploaded.remoteSource?.version == nil)
        #expect(uploaded.remoteSource?.offlineFilename == "offline.epub")
        #expect(uploaded.contentFilename == "offline.epub")
        #expect(hash(uploaded) == hash(untouched))
    }

    /// A choice that is not automatic still syncs.
    @Test func aChosenRendererStateStillSyncs() throws {
        var book = try sharedBook()
        book.compatibilityState = .forcedLegacy
        #expect(book.strippedForSync().compatibilityState == .forcedLegacy)
        #expect(hash(book) != hash(try sharedBook()))
    }

    /// A book with none of that state hashes exactly as builds before this one hashed it, so
    /// most shadows need no migration at all.
    @Test func aBookWithoutDeviceLocalStateHashesAsBefore() throws {
        for book in [try sharedBook(), try remoteLibraryBook()] {
            #expect(ICloudSyncManager.stableHash(BookSyncHashMigration.legacyHashedBook(book)) == hash(book))
        }
    }

    // MARK: Shadow rehash

    private func oldHash(_ book: ReadingBook) -> String {
        ICloudSyncManager.stableHash(BookSyncHashMigration.legacyHashedBook(book))
    }

    /// The first sync after the update: the iPad's shadow holds the old hash of its book with a
    /// download in it. Moved to the new hash with its stamp, the iPhone's 15% still wins.
    @Test func theShadowRehashLetsProgressReadElsewhereWinOnTheFirstSyncAfterTheUpdate() throws {
        var iPad = try sharedBook()
        Self.deviceLocalChanges[3].1(&iPad)
        let key = iPad.id.uuidString
        let oldShadow = [key: SyncShadowEntry(updatedAt: lastSync, hash: oldHash(iPad), deleted: false)]

        let migrated = BookSyncHashMigration.rehashed(oldShadow, local: [iPad], oldHash: oldHash, newHash: hash)
        #expect(migrated.moved == 1)
        #expect(migrated.shadow[key] == SyncShadowEntry(updatedAt: lastSync, hash: hash(iPad), deleted: false))

        var iPhone = iPad
        iPhone.currentPosition = 0.15
        let readAt = lastSync.addingTimeInterval(3_600)
        iPhone.lastOpenedDate = readAt
        let result = ICloudSyncManager.resolveMerge(
            local: [iPad.strippedForSync()],
            remote: [FirestoreSyncRecord(id: key, value: iPhone.strippedForSync(), updatedAt: readAt, deleted: false)],
            shadow: migrated.shadow,
            id: { $0.id.uuidString },
            hash: hash,
            fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
            now: readAt.addingTimeInterval(3_600)
        )
        #expect(result.values.map(\.currentPosition) == [0.15])
    }

    /// Without the rehash, the same first sync is the overwrite the change removes.
    @Test func withoutTheShadowRehashTheFirstSyncWouldStampTheStaleCopy() throws {
        var iPad = try sharedBook()
        Self.deviceLocalChanges[3].1(&iPad)
        let entry = SyncShadowEntry(updatedAt: lastSync, hash: oldHash(iPad), deleted: false)
        let now = lastSync.addingTimeInterval(7_200)
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: entry, currentHash: hash(iPad), fallbackUpdatedAt: lastSync, now: now
        )?.updatedAt == now)
    }

    /// A book edited since the last sync is not made to look unchanged: its entry stays, and
    /// the merge still stamps the edit.
    @Test func theShadowRehashLeavesAnEditNotSyncedYet() throws {
        let synced = try sharedBook()
        var edited = synced
        edited.title = "改過的書名"
        let key = synced.id.uuidString
        let oldShadow = [key: SyncShadowEntry(updatedAt: lastSync, hash: oldHash(synced), deleted: false)]

        let migrated = BookSyncHashMigration.rehashed(oldShadow, local: [edited], oldHash: oldHash, newHash: hash)
        #expect(migrated.moved == 0)
        #expect(migrated.left == 1)
        #expect(migrated.shadow == oldShadow)
        let now = lastSync.addingTimeInterval(60)
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: try #require(migrated.shadow[key]), currentHash: hash(edited), fallbackUpdatedAt: lastSync, now: now
        )?.updatedAt == now)
    }

    /// It runs once per shadow: a later run leaves the shadow as the merges since left it.
    @Test func theShadowRehashRunsOnce() throws {
        let suite = "BookSyncDeviceLocalStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = try sharedBook()
        Self.deviceLocalChanges[1].1(&book)
        let key = book.id.uuidString
        let shadowKey = "test_books"
        SyncShadowStore.save(shadowKey, [key: SyncShadowEntry(updatedAt: lastSync, hash: oldHash(book), deleted: false)],
                             defaults: defaults)

        BookSyncHashMigration.runOnce(shadowKey: shadowKey, local: [book], oldHash: oldHash, newHash: hash, defaults: defaults)
        #expect(SyncShadowStore.load(shadowKey, defaults: defaults)[key]?.hash == hash(book))

        let later = [key: SyncShadowEntry(updatedAt: lastSync, hash: oldHash(book), deleted: false)]
        SyncShadowStore.save(shadowKey, later, defaults: defaults)
        BookSyncHashMigration.runOnce(shadowKey: shadowKey, local: [book], oldHash: oldHash, newHash: hash, defaults: defaults)
        #expect(SyncShadowStore.load(shadowKey, defaults: defaults) == later)
    }
}
