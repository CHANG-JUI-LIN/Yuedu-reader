import Foundation
import Testing
@testable import yuedu_app

@Suite("Firestore sync merge", .serialized)
struct FirestoreSyncMergeTests {
    private struct Item: Codable, Equatable {
        var id: String
        var value: String
    }

    private func shadow(_ updatedAt: TimeInterval, hash: String, deleted: Bool = false) -> SyncShadowEntry {
        SyncShadowEntry(updatedAt: Date(timeIntervalSince1970: updatedAt), hash: hash, deleted: deleted)
    }

    @Test("remote value wins when newer")
    func remoteValueWinsWhenNewer() {
        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "same", value: "local")],
            remote: [FirestoreSyncRecord(id: "same", value: Item(id: "same", value: "remote"), updatedAt: Date(timeIntervalSince1970: 200), deleted: false)],
            shadow: ["same": shadow(100, hash: "local")],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values == [Item(id: "same", value: "remote")])
        #expect(result.shadow["same"]?.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(result.shadow["same"]?.deleted == false)
    }

    @Test("local value is retained when newer")
    func localValueIsRetainedWhenNewer() {
        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "same", value: "local")],
            remote: [FirestoreSyncRecord(id: "same", value: Item(id: "same", value: "remote"), updatedAt: Date(timeIntervalSince1970: 200), deleted: false)],
            shadow: ["same": shadow(300, hash: "local")],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values == [Item(id: "same", value: "local")])
        #expect(result.shadow["same"]?.updatedAt == Date(timeIntervalSince1970: 300))
    }

    @Test("new remote and new local entities are both retained")
    func newRemoteAndNewLocalEntitiesAreBothRetained() {
        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "local-only", value: "local")],
            remote: [FirestoreSyncRecord(id: "remote-only", value: Item(id: "remote-only", value: "remote"), updatedAt: Date(timeIntervalSince1970: 200), deleted: false)],
            shadow: [:],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values == [
            Item(id: "local-only", value: "local"),
            Item(id: "remote-only", value: "remote")
        ])
        #expect(result.shadow["remote-only"]?.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("remote tombstone deletes a local item")
    func remoteTombstoneDeletesLocalItem() {
        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "gone", value: "local")],
            remote: [FirestoreSyncRecord<Item>(id: "gone", value: nil, updatedAt: Date(timeIntervalSince1970: 200), deleted: true)],
            shadow: ["gone": shadow(100, hash: "local")],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values.isEmpty)
        #expect(result.shadow["gone"]?.deleted == true)
    }

    @Test("local edit newer than remote tombstone is retained")
    func localEditNewerThanTombstoneIsRetained() {
        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "kept", value: "local")],
            remote: [FirestoreSyncRecord<Item>(id: "kept", value: nil, updatedAt: Date(timeIntervalSince1970: 200), deleted: true)],
            shadow: ["kept": shadow(300, hash: "local")],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values == [Item(id: "kept", value: "local")])
        #expect(result.shadow["kept"]?.deleted == false)
    }

    @Test("local deletion is remembered so remote item does not resurrect")
    func localDeletionPreventsResurrection() {
        // The item was deleted locally (tombstone in shadow, absent from local),
        // but the remote still has an older live copy. It must stay deleted.
        let result = FirestoreSyncMerge.merge(
            local: [],
            remote: [FirestoreSyncRecord(id: "deleted-here", value: Item(id: "deleted-here", value: "remote"), updatedAt: Date(timeIntervalSince1970: 150), deleted: false)],
            shadow: ["deleted-here": shadow(200, hash: "", deleted: true)],
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in .distantPast }
        )

        #expect(result.values.isEmpty)
        #expect(result.shadow["deleted-here"]?.deleted == true)
    }

    @Test("iCloud metadata upload skips unchanged canonical payloads")
    func iCloudMetadataUploadSkipsUnchangedCanonicalPayloads() throws {
        let records = [
            CloudSyncRecord(
                id: "b",
                value: Item(id: "b", value: "second"),
                updatedAt: Date(timeIntervalSince1970: 200),
                deleted: false
            ),
            CloudSyncRecord(
                id: "a",
                value: Item(id: "a", value: "first"),
                updatedAt: Date(timeIntervalSince1970: 100),
                deleted: false
            )
        ]
        let sameRecordsDifferentOrder = [records[1], records[0]]
        let remoteHash = try ICloudSyncManager.cloudSyncPayloadHash(sameRecordsDifferentOrder)

        #expect(try ICloudSyncManager.cloudSyncPayloadHash(records) == remoteHash)
        #expect(try ICloudSyncManager.shouldUploadCloudSyncRecords(records, remotePayloadHash: remoteHash) == false)
        #expect(try ICloudSyncManager.shouldUploadCloudSyncRecords(records, remotePayloadHash: nil) == true)
    }
}
