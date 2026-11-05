import Foundation
import Testing
@testable import yuedu_app

/// Feedback #6's other half: text readers restore only from the position store, which iCloud
/// never carried, so a book read to 15% on the iPhone opened at its first chapter on the iPad
/// however the shelf record merged. These run two devices' position folders through the merge
/// `ICloudSyncManager` runs on the "reading_positions_v1" record.
@Suite("Reading position sync", .serialized)
struct ReadingPositionSyncTests {
    private let lastSync = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Device {
        let folder: URL
        let store: JSONFileReadingPositionStore
        var shadow: [String: SyncShadowEntry] = [:]

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReadingPositionSyncTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = JSONFileReadingPositionStore(baseURL: folder)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        /// Saves as a reader does, at `date` on this device's clock.
        func read(_ bookId: String, to position: CoreTextReadingPosition, at date: Date) async throws {
            await store.save(position, for: bookId)
            try FileManager.default.setAttributes([.modificationDate: date],
                                                  ofItemAtPath: folder.appendingPathComponent("\(bookId).json").path)
        }
    }

    private func hash(_ item: ReadingPositionSyncItem) -> String { ICloudSyncManager.stableHash(item) }

    /// One device's sync against the cloud's records, as `mergeReadingPositions` runs it.
    private func sync(_ device: Device, cloud: inout [FirestoreSyncRecord<ReadingPositionSyncItem>], now: Date)
        -> (written: Int, shouldApply: Bool) {
        let saved = device.store.syncItems()
        let savedAt = Dictionary(saved.map { ($0.item.bookId, $0.savedAt) }, uniquingKeysWith: { max($0, $1) })
        let result = ICloudSyncManager.resolveMerge(
            local: saved.map(\.item),
            remote: cloud,
            shadow: device.shadow,
            id: { $0.bookId },
            hash: hash,
            fallbackUpdatedAt: { savedAt[$0.bookId] ?? .distantPast },
            now: now
        )
        let written = result.shouldApplyLocally ? device.store.applySyncItems(result.values) : 0
        device.shadow = result.shadow
        cloud = ICloudSyncManager.cloudSyncRecords(values: result.values, shadow: result.shadow, id: { $0.bookId })
            .map { FirestoreSyncRecord(id: $0.id, value: $0.value, updatedAt: $0.updatedAt, deleted: $0.deleted) }
        return (written, result.shouldApplyLocally)
    }

    @Test func aPositionReadOnOneDeviceOpensThereOnTheOther() async throws {
        let iPhone = try Device()
        let iPad = try Device()
        let bookId = UUID().uuidString
        try await iPad.read(bookId, to: .chapterStart(0), at: lastSync)
        let fifteenPercent = CoreTextReadingPosition(spineIndex: 7, charOffset: 1_204)
        try await iPhone.read(bookId, to: fifteenPercent, at: lastSync.addingTimeInterval(3_600))

        var cloud: [FirestoreSyncRecord<ReadingPositionSyncItem>] = []
        _ = sync(iPad, cloud: &cloud, now: lastSync.addingTimeInterval(60))
        _ = sync(iPhone, cloud: &cloud, now: lastSync.addingTimeInterval(4_000))
        let iPadBack = sync(iPad, cloud: &cloud, now: lastSync.addingTimeInterval(8_000))

        #expect(iPadBack.written == 1)
        #expect(iPad.store.loadSync(for: bookId) == fifteenPercent, "the iPad's reader restores the iPhone's place")
        #expect(iPad.store.countsPictures(for: bookId), "stamped as the iPhone saved it, so not moved again")

        // The next sync on either device finds nothing to apply: no ping-pong.
        #expect(!sync(iPad, cloud: &cloud, now: lastSync.addingTimeInterval(9_000)).shouldApply)
        #expect(!sync(iPhone, cloud: &cloud, now: lastSync.addingTimeInterval(9_500)).shouldApply)
        #expect(iPhone.store.loadSync(for: bookId) == fifteenPercent)
    }

    @Test func aPositionReadLaterHereStillWins() async throws {
        let iPhone = try Device()
        let iPad = try Device()
        let bookId = UUID().uuidString
        try await iPhone.read(bookId, to: CoreTextReadingPosition(spineIndex: 7, charOffset: 1_204),
                              at: lastSync.addingTimeInterval(3_600))
        var cloud: [FirestoreSyncRecord<ReadingPositionSyncItem>] = []
        _ = sync(iPhone, cloud: &cloud, now: lastSync.addingTimeInterval(3_700))
        _ = sync(iPad, cloud: &cloud, now: lastSync.addingTimeInterval(3_800))

        let further = CoreTextReadingPosition(spineIndex: 9, charOffset: 20)
        try await iPad.read(bookId, to: further, at: lastSync.addingTimeInterval(5_000))
        _ = sync(iPad, cloud: &cloud, now: lastSync.addingTimeInterval(5_100))
        _ = sync(iPhone, cloud: &cloud, now: lastSync.addingTimeInterval(5_200))
        #expect(iPhone.store.loadSync(for: bookId) == further)
        #expect(iPad.store.loadSync(for: bookId) == further)
    }

    @Test func onlyBookPositionFilesAreSynced() async throws {
        let device = try Device()
        let bookId = UUID().uuidString
        try await device.read(bookId, to: CoreTextReadingPosition(spineIndex: 2, charOffset: 5, translationOffset: 9), at: lastSync)
        try Data("{}".utf8).write(to: device.folder.appendingPathComponent("\(bookId).txt-reindex.json"))

        let items = device.store.syncItems()
        #expect(items.map(\.item) == [ReadingPositionSyncItem(
            bookId: bookId, position: CoreTextReadingPosition(spineIndex: 2, charOffset: 5, translationOffset: 9),
            countsPictures: true
        )])
        #expect(items.first?.savedAt == lastSync)
    }

    @Test func aPositionOfAnotherTextVersionIsKeptApart() async throws {
        let device = try Device()
        let bookId = UUID().uuidString
        let mine = ReadingPositionSyncItem(bookId: bookId, position: .chapterStart(3), countsPictures: true, textVersion: 2)
        #expect(device.store.applySyncItems([mine]) == 1)
        let other = ReadingPositionSyncItem(bookId: bookId, position: .chapterStart(8), countsPictures: true, textVersion: 1)
        #expect(device.store.applySyncItems([other]) == 0)
        #expect(device.store.syncItems().map(\.item) == [mine])
    }

    @Test func anUnstampedPositionArrivesUnstamped() throws {
        let device = try Device()
        let bookId = UUID().uuidString
        let unstamped = ReadingPositionSyncItem(bookId: bookId, position: CoreTextReadingPosition(spineIndex: 1, charOffset: 40))
        #expect(device.store.applySyncItems([unstamped]) == 1)
        #expect(!device.store.countsPictures(for: bookId), "moved once on this device, as on the one that saved it")
        #expect(device.store.applySyncItems([unstamped]) == 0, "already saved as it is")
    }
}
