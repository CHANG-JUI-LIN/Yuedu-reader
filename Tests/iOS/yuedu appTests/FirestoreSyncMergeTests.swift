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

    private static let bubbleSelectionID = "comment_bubble_selection"

    private func selectionMerge(
        local: [ReaderCommentBubbleSyncSelection],
        remote: [FirestoreSyncRecord<ReaderCommentBubbleSyncSelection>],
        shadow: [String: SyncShadowEntry]
    ) -> (values: [ReaderCommentBubbleSyncSelection], shadow: [String: SyncShadowEntry]) {
        FirestoreSyncMerge.merge(
            local: local,
            remote: remote,
            shadow: shadow,
            id: { _ in Self.bubbleSelectionID },
            hash: { $0.selectedCustomStyleID?.uuidString ?? "" },
            fallbackUpdatedAt: { $0.modifiedAt ?? .distantPast }
        )
    }

    @Test("bubble selection record merges last-write-wins by its clock")
    func bubbleSelectionMergesLastWriteWins() {
        let older = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 300)
        )

        let result = selectionMerge(
            local: [older],
            remote: [FirestoreSyncRecord(
                id: Self.bubbleSelectionID,
                value: newer,
                updatedAt: Date(timeIntervalSince1970: 300),
                deleted: false
            )],
            shadow: [Self.bubbleSelectionID: shadow(100, hash: older.selectedCustomStyleID!.uuidString)]
        )

        #expect(result.values == [newer])
        #expect(result.shadow[Self.bubbleSelectionID]?.deleted == false)
    }

    @Test("a device with no selection adopts the remote bubble selection")
    func bubbleSelectionAdoptedFromRemote() {
        let remote = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let result = selectionMerge(
            local: [],
            remote: [FirestoreSyncRecord(
                id: Self.bubbleSelectionID,
                value: remote,
                updatedAt: Date(timeIntervalSince1970: 200),
                deleted: false
            )],
            shadow: [:]
        )

        #expect(result.values == [remote])
    }

    @Test("a cleared selection stays cleared while a newer remote pick wins")
    func bubbleSelectionNeverTreatsNilAsLocalDeletion() {
        // Local record represents "cleared" as a value (nil + old clock), not as
        // an absent record — so the merge never tombstones the constant id and
        // a newer remote pick survives.
        let cleared = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: nil,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let newerRemotePick = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 300)
        )

        let result = selectionMerge(
            local: [cleared],
            remote: [FirestoreSyncRecord(
                id: Self.bubbleSelectionID,
                value: newerRemotePick,
                updatedAt: Date(timeIntervalSince1970: 300),
                deleted: false
            )],
            shadow: [Self.bubbleSelectionID: shadow(100, hash: "cleared")]
        )

        #expect(result.values == [newerRemotePick])
        #expect(result.shadow[Self.bubbleSelectionID]?.deleted == false)
    }

    @Test("bubble selection tombstone clears a newer-picked style only when newer")
    func bubbleSelectionTombstoneRespectsClock() {
        let staleLocalPick = ReaderCommentBubbleSyncSelection(
            selectedCustomStyleID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )

        let cleared = selectionMerge(
            local: [staleLocalPick],
            remote: [FirestoreSyncRecord<ReaderCommentBubbleSyncSelection>(
                id: Self.bubbleSelectionID,
                value: nil,
                updatedAt: Date(timeIntervalSince1970: 200),
                deleted: true
            )],
            shadow: [Self.bubbleSelectionID: shadow(100, hash: staleLocalPick.selectedCustomStyleID!.uuidString)]
        )

        #expect(cleared.values.isEmpty)
        #expect(cleared.shadow[Self.bubbleSelectionID]?.deleted == true)
    }

    @Test("shadow entry advances on a local edit")
    func shadowEntryAdvancesOnLocalEdit() {
        let advanced = ICloudSyncManager.updatedShadowEntry(
            existing: shadow(100, hash: "old"),
            currentHash: "new",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 300),
            now: Date(timeIntervalSince1970: 250)
        )

        #expect(advanced?.updatedAt == Date(timeIntervalSince1970: 300))
        #expect(advanced?.hash == "new")
        #expect(advanced?.deleted == false)
    }

    @Test("shadow entry advances past the last sync when the item's own clock stood still")
    func shadowEntryAdvancesWhenDomainClockStoodStill() {
        // 換封面 changes the book record but not its `lastOpenedDate`, so the
        // fallback clock is still the timestamp the last sync uploaded.
        let advanced = ICloudSyncManager.updatedShadowEntry(
            existing: shadow(100, hash: "source-cover"),
            currentHash: "custom-cover",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 500)
        )

        #expect(advanced?.updatedAt == Date(timeIntervalSince1970: 500))
        #expect(advanced?.hash == "custom-cover")
    }

    @Test("an edit that does not move the item's own clock survives the next merge")
    func editWithUnchangedDomainClockSurvivesMerge() {
        // The 換封面 revert, end to end: the shadow and the remote record both
        // carry the book's `lastOpenedDate`, so before the shadow advanced past
        // it the merge's `record.updatedAt >= localEntry.updatedAt` handed the
        // pre-edit cloud copy back and the custom cover disappeared on relaunch.
        let lastOpened = Date(timeIntervalSince1970: 1_000)
        let synced = Item(id: "book", value: "source-cover")
        let edited = Item(id: "book", value: "custom-cover")

        var shadowStore = ["book": shadow(1_000, hash: synced.value)]
        shadowStore["book"] = ICloudSyncManager.updatedShadowEntry(
            existing: shadowStore["book"],
            currentHash: edited.value,
            fallbackUpdatedAt: lastOpened,
            now: Date(timeIntervalSince1970: 5_000)
        )

        let result = FirestoreSyncMerge.merge(
            local: [edited],
            remote: [FirestoreSyncRecord(id: "book", value: synced, updatedAt: lastOpened, deleted: false)],
            shadow: shadowStore,
            id: { $0.id },
            hash: { $0.value },
            fallbackUpdatedAt: { _ in lastOpened }
        )

        #expect(result.values == [edited])
        #expect(result.shadow["book"]?.updatedAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test("shadow entry stays untouched when nothing changed")
    func shadowEntryUntouchedWhenUnchanged() {
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: shadow(100, hash: "same"),
            currentHash: "same",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 300)
        ) == nil)
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: nil,
            currentHash: "new",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 300)
        ) == nil)
    }

    @Test("shadow entry revives a re-creation that is newer than the tombstone")
    func shadowEntryRevivesNewerRecreation() {
        let revived = ICloudSyncManager.updatedShadowEntry(
            existing: shadow(200, hash: "", deleted: true),
            currentHash: "repicked",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 400)
        )

        #expect(revived?.updatedAt == Date(timeIntervalSince1970: 400))
        #expect(revived?.hash == "repicked")
        #expect(revived?.deleted == false)
    }

    @Test("shadow entry keeps the tombstone when the re-creation is older")
    func shadowEntryKeepsTombstoneWhenRecreationOlder() {
        #expect(ICloudSyncManager.updatedShadowEntry(
            existing: shadow(200, hash: "", deleted: true),
            currentHash: "repicked",
            fallbackUpdatedAt: Date(timeIntervalSince1970: 100)
        ) == nil)
    }
}
