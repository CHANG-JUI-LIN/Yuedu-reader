import Foundation
import Testing
@testable import yuedu_app

/// 15.trace and 16.trace (2026-09-22/23): the one reading hitch left in each was
/// the launch sync applying the shelf — `objectWillChange` re-rendered the reader
/// and the bookshelf behind it mid-scroll. Nothing had changed: the sync hash came
/// from an encoding whose key order differs on every call (and sets encoded in
/// storage order), so every item looked edited and every merge was applied.
@Suite("iCloud sync change detection")
struct ICloudSyncChangeDetectionTests {
    private let synced = Date(timeIntervalSince1970: 1_700_000_000)

    /// A shelf record as the device holds it: decoded from its own file.
    private func localBook(runtimeVariables: [String: String]? = ["token": "t-1", "uid": "42", "cookie": "c=1", "page": "3"],
                           downloading: Bool = true) throws -> ReadingBook {
        var book = ReadingBook(title: "書源小說", author: "作者", source: "https://example.com/book/1", contentFilename: "")
        book.isOnline = true
        book.runtimeVariables = runtimeVariables
        book.lastOpenedDate = synced
        if downloading {
            var task = BookOfflineDownloadTask(requestedIndices: Set(0..<40), now: synced)
            task.completedIndices = Set(0..<25)
            task.pendingIndices = Set(25..<40)
            book.offlineDownloadTask = task
        }
        return try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book))
    }

    /// The copy the next sync downloads: the uploaded blob, decoded again.
    private func cloudCopy(of book: ReadingBook) throws -> ReadingBook {
        let data = try ICloudSyncManager.encodeCloudSyncRecords([
            CloudSyncRecord(id: book.id.uuidString, value: book, updatedAt: synced, deleted: false)
        ])
        let records = try JSONDecoder().decode([CloudSyncRecord<ReadingBook>].self, from: data)
        return try #require(records.first?.value)
    }

    private func hash(_ book: ReadingBook) -> String {
        ICloudSyncManager.stableHash(book.strippedForSync())
    }

    /// The shadow hash the last sync wrote, from the record as it was then.
    private func lastSyncHash(_ book: ReadingBook) throws -> String {
        hash(try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book)))
    }

    private func merge(local: ReadingBook, remote: ReadingBook, remoteUpdatedAt: Date? = nil,
                       shadowHash: String, now: Date = Date())
        -> (values: [ReadingBook], shadow: [String: SyncShadowEntry], shouldApplyLocally: Bool) {
        let key = local.id.uuidString
        return ICloudSyncManager.resolveMerge(
            local: [local],
            remote: [FirestoreSyncRecord(id: key, value: remote, updatedAt: remoteUpdatedAt ?? synced, deleted: false)],
            shadow: [key: SyncShadowEntry(updatedAt: synced, hash: shadowHash, deleted: false)],
            id: { $0.id.uuidString },
            hash: hash,
            fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
            now: now
        )
    }

    @Test func aBookBackFromTheCloudHashesLikeTheBookItCameFrom() throws {
        let book = try localBook()
        for round in 0..<20 {
            let copy = try cloudCopy(of: book)
            #expect(hash(copy) == hash(book), "round \(round)")
        }
    }

    /// The decision that re-rendered the reader: an unchanged shelf merged with
    /// its own last upload must not be applied.
    @Test func anUnchangedShelfIsNotAppliedAfterItsOwnRoundTrip() throws {
        let book = try localBook()
        for round in 0..<20 {
            let copy = try cloudCopy(of: book)
            let result = merge(local: book, remote: copy, shadowHash: hash(book))
            #expect(!result.shouldApplyLocally, "round \(round)")
        }
    }

    @Test func equalDownloadTasksEncodeIdentically() throws {
        let task = try #require(try localBook().offlineDownloadTask)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(task)
        for round in 0..<20 {
            let copy = try JSONDecoder().decode(BookOfflineDownloadTask.self, from: JSONEncoder().encode(task))
            #expect(try encoder.encode(copy) == original, "round \(round)")
        }
    }

    /// Before the fix the unedited local book looked edited, was stamped `now`
    /// and won, so another device's newer progress never arrived.
    @Test func aNewerEditFromAnotherDeviceIsApplied() throws {
        let book = try localBook()
        var edited = try cloudCopy(of: book)
        edited.currentPosition = 0.62
        let later = synced.addingTimeInterval(3_600)
        edited.lastOpenedDate = later
        let result = merge(local: book, remote: edited, remoteUpdatedAt: later,
                           shadowHash: try lastSyncHash(book), now: later.addingTimeInterval(3_600))
        #expect(result.values.map(\.currentPosition) == [0.62], "the other device's progress wins")
        #expect(result.shouldApplyLocally)
        #expect(result.shadow[book.id.uuidString]?.hash == hash(edited))
    }

    /// A real local edit still wins over the copy it was made from, and the shelf
    /// that already shows it is not re-applied.
    @Test func aLocalEditStillWins() throws {
        let book = try localBook()
        var edited = book
        edited.title = "改過的書名"
        let now = synced.addingTimeInterval(60)
        let copy = try cloudCopy(of: book)
        let result = merge(local: edited, remote: copy, shadowHash: try lastSyncHash(book), now: now)
        #expect(result.values.map(\.title) == ["改過的書名"])
        #expect(!result.shouldApplyLocally)
        #expect(result.shadow[book.id.uuidString]?.updatedAt == now)
    }

    /// Feedback #6 asked whether a sync stamps books nobody touched `now`, which would let a
    /// stale copy beat progress read elsewhere. It does not: an unchanged hash leaves the
    /// shadow entry, and its stamp, as the last sync left them, however late the sync runs.
    @Test func anUntouchedBookIsNotStampedNow() {
        let entry = SyncShadowEntry(updatedAt: synced, hash: "unchanged", deleted: false)
        let dayLater = synced.addingTimeInterval(86_400)
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: entry, currentHash: "unchanged", fallbackUpdatedAt: synced, now: dayLater
        ) == nil)
    }

    /// The order feedback #6 feared: the iPad, only suspended and untouched, syncs on its way
    /// to the background before the iPhone has uploaded the 15% it read. The iPad's upload
    /// carries the last sync's stamp, so the iPhone's progress still wins when it uploads, and
    /// reaches the iPad when it comes back.
    @Test func anUntouchedCopyUploadedFirstDoesNotBeatProgressReadElsewhere() throws {
        let book = try localBook()
        let key = book.id.uuidString
        let shadowHash = try lastSyncHash(book)

        let iPadLeaves = synced.addingTimeInterval(86_400)
        let iPad = merge(local: book, remote: try cloudCopy(of: book), shadowHash: shadowHash, now: iPadLeaves)
        let iPadStamp = try #require(iPad.shadow[key]?.updatedAt)
        #expect(iPadStamp == synced, "the untouched copy keeps the last sync's stamp")
        let iPadUpload = try #require(iPad.values.first)

        var read = book
        read.currentPosition = 0.15
        read.lastOpenedDate = synced.addingTimeInterval(3_600)
        let iPhone = ICloudSyncManager.resolveMerge(
            local: [read],
            remote: [FirestoreSyncRecord(id: key, value: iPadUpload, updatedAt: iPadStamp, deleted: false)],
            shadow: [key: SyncShadowEntry(updatedAt: synced, hash: shadowHash, deleted: false)],
            id: { $0.id.uuidString },
            hash: hash,
            fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
            now: iPadLeaves.addingTimeInterval(60)
        )
        #expect(iPhone.values.map(\.currentPosition) == [0.15], "the iPhone keeps what it read")
        let iPhoneStamp = try #require(iPhone.shadow[key]?.updatedAt)
        let iPhoneUpload = try #require(iPhone.values.first)

        let iPadBack = merge(local: book, remote: iPhoneUpload, remoteUpdatedAt: iPhoneStamp,
                             shadowHash: shadowHash, now: iPhoneStamp.addingTimeInterval(60))
        #expect(iPadBack.values.map(\.currentPosition) == [0.15], "the 15% reaches the iPad")
        #expect(iPadBack.shouldApplyLocally)
    }
}
