import Foundation
import Testing
@testable import yuedu_app

@Suite("Firestore sync merge", .serialized)
struct FirestoreSyncMergeTests {
    private struct Item: Equatable {
        var id: String
        var value: String
    }

    @Test("remote value wins when newer")
    func remoteValueWinsWhenNewer() {
        let localDate = Date(timeIntervalSince1970: 100)
        let remoteDate = Date(timeIntervalSince1970: 200)

        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "same", value: "local")],
            remote: [FirestoreSyncRecord(id: "same", value: Item(id: "same", value: "remote"), updatedAt: remoteDate)],
            id: { $0.id },
            localUpdatedAt: { _ in localDate }
        )

        #expect(result.values == [Item(id: "same", value: "remote")])
        #expect(result.timestamps["same"] == remoteDate)
    }

    @Test("local value is retained when newer")
    func localValueIsRetainedWhenNewer() {
        let localDate = Date(timeIntervalSince1970: 300)
        let remoteDate = Date(timeIntervalSince1970: 200)

        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "same", value: "local")],
            remote: [FirestoreSyncRecord(id: "same", value: Item(id: "same", value: "remote"), updatedAt: remoteDate)],
            id: { $0.id },
            localUpdatedAt: { _ in localDate }
        )

        #expect(result.values == [Item(id: "same", value: "local")])
        #expect(result.timestamps["same"] == localDate)
    }

    @Test("new remote and new local entities are both retained")
    func newRemoteAndNewLocalEntitiesAreBothRetained() {
        let remoteDate = Date(timeIntervalSince1970: 200)

        let result = FirestoreSyncMerge.merge(
            local: [Item(id: "local-only", value: "local")],
            remote: [FirestoreSyncRecord(id: "remote-only", value: Item(id: "remote-only", value: "remote"), updatedAt: remoteDate)],
            id: { $0.id },
            localUpdatedAt: { _ in nil }
        )

        #expect(result.values == [
            Item(id: "local-only", value: "local"),
            Item(id: "remote-only", value: "remote")
        ])
        #expect(result.timestamps["remote-only"] == remoteDate)
    }
}
