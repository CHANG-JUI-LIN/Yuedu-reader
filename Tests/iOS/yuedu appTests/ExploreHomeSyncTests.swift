import Foundation
import Testing
@testable import yuedu_app

/// Offline passes of the 探索 home's step of an iCloud sync (`ICloudSyncManager.mergeExploreHome`),
/// run through the same static functions `mergeType` runs, against real home files. What these
/// hold: the reader's 預設 is never lost to a new device's untouched defaults, whichever syncs
/// first; two changed 預設 both survive the first sync; each 首頁配置 follows the reader; and
/// once settled, a pass applies and uploads nothing.
@MainActor
@Suite("iCloud explore-home sync", .serialized)
struct ExploreHomeSyncTests {
    /// One device's side: its home file, its preferences and its merge shadows.
    final class Device {
        let name: String
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("explore-home-sync-\(UUID().uuidString)")
        let suite = "ExploreHomeSyncTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        private(set) var store: HomePageStore
        var shadow: [String: SyncShadowEntry] = [:]
        var selectionShadow: [String: SyncShadowEntry] = [:]
        var uploads = 0
        var applies = 0

        @MainActor init(_ name: String) throws {
            self.name = name
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"), defaults: defaults)
        }

        /// The home made, as opening 探索 makes it.
        @MainActor @discardableResult func open() -> HomePage {
            store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        }

        /// A relaunch: the home read back from its file.
        @MainActor func relaunch() {
            store.waitForPendingWritesForTesting()
            store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"), defaults: defaults)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    final class Cloud {
        var configurations: Data?
        var selection: Data?
    }

    /// One `mergeType` pass over one record, as `ICloudSyncManager` runs it.
    static func merge<T: Codable>(
        local: [T], blob: inout Data?, shadow: inout [String: SyncShadowEntry], uploads: inout Int,
        id: (T) -> String, now: Date, leavesAlone: ([T]) -> Bool = { _ in false }, apply: ([T]) throws -> Bool
    ) throws -> Bool {
        let hash: (T) -> String = { ICloudSyncManager.stableHash($0) }
        let remote: (records: [FirestoreSyncRecord<T>], payloadHash: String?) = try blob.map {
            try ICloudSyncManager.decodeCloudSyncBlob($0, recordName: "test", id: id, fallbackUpdatedAt: { _ in .distantPast })
        } ?? ([], nil)
        if leavesAlone(remote.records.compactMap(\.value)) { return false }
        let result = ICloudSyncManager.resolveMerge(
            local: local, remote: remote.records, shadow: shadow,
            id: id, hash: hash, fallbackUpdatedAt: { _ in .distantPast }, now: now
        )
        let records = ICloudSyncManager.cloudSyncRecords(values: result.values, shadow: result.shadow, id: id)
        if try ICloudSyncManager.shouldUploadCloudSyncRecords(records, remotePayloadHash: remote.payloadHash) {
            blob = try ICloudSyncManager.encodeCloudSyncRecords(records)
            uploads += 1
        }
        let applied = result.shouldApplyLocally ? try apply(result.values) : true
        let committed = ICloudSyncManager.shadowToCommit(
            previous: shadow, merge: result, local: local, appliedLocally: applied, id: id, hash: hash
        )
        shadow = try JSONDecoder().decode([String: SyncShadowEntry].self, from: JSONEncoder().encode(committed))
        return result.shouldApplyLocally && applied
    }

    /// The home's two records, as `mergeExploreHome` merges them. `during` runs between the
    /// read and the apply: what the reader does while the round trip is out.
    @discardableResult
    static func pass(_ device: Device, cloud: Cloud, now: Date, during: () -> Void = {}) throws -> Bool {
        guard let local = try device.store.syncItems() else { return false }
        let neverMerged = device.shadow[HomeConfigurationID.defaults.rawValue] == nil
        var refused = false
        let applied = try merge(
            local: local, blob: &cloud.configurations, shadow: &device.shadow, uploads: &device.uploads,
            id: { $0.id }, now: now, leavesAlone: { !HomePageStore.canRead($0) }
        ) { merged in
            during()
            let applied = try device.store.applyFromSync(merged, expecting: local, keepsDisplacedDefaults: neverMerged,
                                                         deviceName: device.name)
            refused = !applied
            return applied
        }
        if applied { device.applies += 1 }
        if let selection = device.store.syncSelection {
            let moved = try merge(
                local: [selection], blob: &cloud.selection, shadow: &device.selectionShadow, uploads: &device.uploads,
                id: { _ in "explore_home_selection" }, now: now
            ) { merged in
                if let record = merged.first { device.store.applySelectionFromSync(record) }
                return true
            }
            if moved { device.applies += 1 }
        }
        return !refused
    }

    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func names(_ device: Device) -> [String] { device.store.configurations.map(\.name) }
    private func titles(_ device: Device, _ id: HomeConfigurationID = .defaults) -> [String] {
        device.store.home?.sections(of: id).map(\.title) ?? []
    }

    /// The reader's change to 預設: its first section named.
    private func rename(_ device: Device, to title: String) {
        device.store.edit { page in page.sections[0].title = title }
    }

    // MARK: 預設

    @Test("untouched defaults are never sent: a new device takes the reader's 預設, whichever syncs first")
    func untouchedDefaultsYield() throws {
        for freshFirst in [true, false] {
            let cloud = Cloud(), main = try Device("iPhone"), fresh = try Device("iPad")
            main.open()
            rename(main, to: "我的")
            fresh.open()
            #expect(try fresh.store.syncItems() == [], "its 預設 is the app's")

            let order = freshFirst ? [fresh, main, fresh] : [main, fresh, main]
            for (step, device) in order.enumerated() { try Self.pass(device, cloud: cloud, now: Self.day + Double(step) * 10) }
            #expect(titles(main).first == "我的")
            #expect(titles(fresh).first == "我的")
            #expect(names(main) == [localized("預設")])
            #expect(names(fresh) == [localized("預設")], "no copy: there was nothing of the reader's to keep")
        }
    }

    @Test("two changed 預設: the cloud's is 預設, and this device's is kept as one of the reader's own")
    func changedDefaultsBothSurvive() throws {
        let cloud = Cloud(), phone = try Device("iPhone"), pad = try Device("iPad")
        phone.open()
        rename(phone, to: "手機的")
        pad.open()
        rename(pad, to: "平板的")

        try Self.pass(phone, cloud: cloud, now: Self.day)
        try Self.pass(pad, cloud: cloud, now: Self.day + 10)
        try Self.pass(phone, cloud: cloud, now: Self.day + 20)
        // The copy is the pad's own addition: it goes up on the pad's next pass.
        try Self.pass(pad, cloud: cloud, now: Self.day + 30)
        try Self.pass(phone, cloud: cloud, now: Self.day + 35)

        for device in [phone, pad] {
            #expect(titles(device).first == "手機的")
            #expect(names(device) == [localized("預設"), "\(localized("預設")) – iPad"])
            let kept = try #require(device.store.home?.configurations.first)
            #expect(kept.sections.first?.title == "平板的")
        }
        // Once it has met the cloud's, a later change is an edit like any other: no second copy.
        rename(pad, to: "平板改的")
        try Self.pass(pad, cloud: cloud, now: Self.day + 40)
        try Self.pass(phone, cloud: cloud, now: Self.day + 50)
        #expect(titles(phone).first == "平板改的")
        #expect(names(phone).count == 2)
    }

    @Test("an older file's 預設 is looked at once: still the defaults, it is the app's; changed, it is the reader's")
    func olderFileIsLookedAt() throws {
        let device = try Device("iPhone")
        device.open()
        // As a build before the sync saved it: nothing says whose 預設 it is.
        func forget() throws {
            device.store.waitForPendingWritesForTesting()
            let file = device.folder.appendingPathComponent("explore_home.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["defaultsUntouched"] = nil
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            device.relaunch()
        }
        try forget()
        #expect(try device.store.syncItems() == nil, "left alone until the home has looked")
        device.open()
        #expect(try device.store.syncItems() == [])

        rename(device, to: "我的")
        try forget()
        device.open()
        #expect(try device.store.syncItems()?.map(\.id) == [HomeConfigurationID.defaults.rawValue])
    }

    // MARK: The reader's own

    @Test("首頁配置 made on each device are all on both; one deleted leaves both; the one shown follows")
    func ownConfigurations() throws {
        let cloud = Cloud(), phone = try Device("iPhone"), pad = try Device("iPad")
        phone.open()
        pad.open()
        let context = HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        phone.store.createConfiguration(named: "通勤", from: .blank, defaults: context)
        pad.store.createConfiguration(named: "睡前", from: .defaults, defaults: context)
        pad.store.select(.defaults)

        try Self.pass(phone, cloud: cloud, now: Self.day)
        try Self.pass(pad, cloud: cloud, now: Self.day + 10)
        try Self.pass(phone, cloud: cloud, now: Self.day + 20)
        #expect(Set(names(phone)) == [localized("預設"), "通勤", "睡前"])
        #expect(Set(names(pad)) == [localized("預設"), "通勤", "睡前"])
        let commute = try #require(phone.store.configurations.first { $0.name == "通勤" }?.id)
        #expect(pad.store.selectedConfiguration == commute, "the one the phone shows")

        pad.store.renameConfiguration(commute, to: "通勤路上")
        let bedtime = try #require(pad.store.configurations.first { $0.name == "睡前" }?.id)
        pad.store.deleteConfiguration(bedtime)
        try Self.pass(pad, cloud: cloud, now: Self.day + 30)
        try Self.pass(phone, cloud: cloud, now: Self.day + 40)
        #expect(Set(names(phone)) == [localized("預設"), "通勤路上"])

        // Settled, and read back from the file as a relaunch reads it: nothing moves.
        try Self.pass(pad, cloud: cloud, now: Self.day + 50)
        phone.relaunch()
        pad.relaunch()
        let (uploads, applies) = (phone.uploads + pad.uploads, phone.applies + pad.applies)
        try Self.pass(phone, cloud: cloud, now: Self.day + 60)
        try Self.pass(pad, cloud: cloud, now: Self.day + 70)
        #expect(phone.uploads + pad.uploads == uploads, "a settled pass uploads nothing")
        #expect(phone.applies + pad.applies == applies, "a settled pass applies nothing")
    }

    @Test("an edit during the round trip is kept, and the merge waits for the next sync")
    func editDuringRoundTrip() throws {
        let cloud = Cloud(), phone = try Device("iPhone"), pad = try Device("iPad")
        phone.open()
        rename(phone, to: "手機的")
        try Self.pass(phone, cloud: cloud, now: Self.day)
        pad.open()

        let context = HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        let applied = try Self.pass(pad, cloud: cloud, now: Self.day + 10) {
            pad.store.createConfiguration(named: "剛建的", from: .blank, defaults: context)
        }
        #expect(!applied)
        #expect(names(pad).contains("剛建的"))
        #expect(titles(pad).first != "手機的")

        try Self.pass(pad, cloud: cloud, now: Self.day + 20)
        try Self.pass(phone, cloud: cloud, now: Self.day + 30)
        #expect(titles(pad).first == "手機的")
        #expect(names(phone).contains("剛建的"))
    }

    @Test("a home not made yet, and a newer build's 首頁配置 in the cloud, are left alone")
    func leftAlone() throws {
        let device = try Device("iPhone")
        #expect(try device.store.syncItems() == nil)
        #expect(device.store.syncSelection == nil)

        let mine = try HomeConfigurationSyncItem(id: .defaults, name: "", sections: [])
        #expect(HomePageStore.canRead([mine]))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(mine)) as? [String: Any])
        object["schemaVersion"] = HomePage.currentSchemaVersion + 1
        let newer = try JSONDecoder().decode(HomeConfigurationSyncItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!HomePageStore.canRead([mine, newer]))
    }

    // MARK: Settings

    @Test("自動補齊's order goes as stored, unknown places included; unset sends nothing; a broken value throws")
    func fillOrder() throws {
        let suite = "ExploreHomeSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataFillOrderStore(defaults: defaults)
        #expect(try store.syncRecord() == nil)

        let arrived = MetadataFillOrderSyncRecord(entries: [
            ["place": "module:example.a", "enabled": "0"], ["place": "bookSources", "enabled": "1"],
            ["place": "somethingNewer", "enabled": "1"],
        ])
        store.applyFromSync(arrived)
        #expect(store.stored.map(\.place) == [.module("example.a"), .bookSources])
        #expect(store.stored.first?.isEnabled == false)
        #expect(try store.syncRecord() == arrived, "the place this build cannot name goes on to the next device")
        #expect(try MetadataFillOrderStore(defaults: defaults).syncRecord() == arrived)

        defaults.set(["not an entry"], forKey: MetadataFillOrderStore.defaultsKey)
        #expect(throws: (any Error).self) { try store.syncRecord() }
    }

    @Test("聚合設定 goes a setting an item; unreadable stored settings send nothing")
    func aggregation() throws {
        let suite = "ExploreHomeSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AggregationSettingsStore(defaults: defaults)
        #expect(store.syncItems == [])

        let module = SourceInstanceKey(type: .module, id: "example.a")
        let other = SourceInstanceKey(type: .module, id: "example.b")
        store.setShownInSearch(false, for: module)
        store.setHidesRead(false)
        let mine = try #require(store.syncItems)
        #expect(Set(mine.map(\.id)) == ["hidesRead", "hiddenFromSearch/module/example.a"])

        // What another device set, merged with this one's.
        store.applyFromSync(mine + [
            AggregationSettingSyncItem(kind: .hiddenFromSearch, key: other),
            AggregationSettingSyncItem(kind: .metadataLanguage, text: "ja"),
        ])
        #expect(!store.isShownInSearch(module))
        #expect(!store.isShownInSearch(other))
        #expect(store.settings.metadataLanguage == "ja")
        #expect(store.settings.hidesRead == false)
        #expect(store.settings.hiddenFromLatest == nil, "a list no device set stays unset")
        #expect(AggregationSettingsStore(defaults: defaults).syncItems?.count == 4)

        defaults.set(Data("not json".utf8), forKey: AggregationSettingsStore.defaultsKey)
        #expect(AggregationSettingsStore(defaults: defaults).syncItems == nil)
    }
}
