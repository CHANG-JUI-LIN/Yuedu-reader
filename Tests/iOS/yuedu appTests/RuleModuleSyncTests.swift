import Foundation
import Testing
@testable import yuedu_app

/// Offline passes of the 模組 step of an iCloud sync (`ICloudSyncManager.mergeRuleModules`),
/// run through the same static functions `mergeType` runs, against real module folders.
/// Until 2026-11-21 nothing of a module synced. What these hold: a module reaches the other
/// device and leaves it when removed, and a module the app does not list — turned off, or
/// one it cannot open — is never read as removed.
@Suite("iCloud module sync", .serialized)
struct RuleModuleSyncTests {
    /// One device's side: its modules folder and its merge shadow.
    final class Device {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModuleSync-\(UUID().uuidString)")
        var store: RuleModuleStore { RuleModuleStore(directory: folder) }
        var shadow: [String: SyncShadowEntry] = [:]
        var uploads = 0
        var applies = 0

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    final class Cloud {
        var blob: Data?
    }

    static func hash(_ item: RuleModuleSyncItem) -> String { ICloudSyncManager.stableHash(item) }

    /// One `mergeType` pass, with the arguments `mergeRuleModules` gives it. `during` runs
    /// between the read and the apply: what the reader does while the round trip is out.
    @discardableResult
    static func pass(_ device: Device, cloud: Cloud, now: Date, during: () throws -> Void = {}) throws -> Bool {
        let local = try device.store.syncItems()
        let remote: (records: [FirestoreSyncRecord<RuleModuleSyncItem>], payloadHash: String?) = try cloud.blob.map {
            try ICloudSyncManager.decodeCloudSyncBlob($0, recordName: "rule_modules_v1", id: { $0.id }, fallbackUpdatedAt: { $0.updatedAt })
        } ?? ([], nil)
        let result = ICloudSyncManager.resolveMerge(
            local: local, remote: remote.records, shadow: device.shadow,
            id: { $0.id }, hash: hash, fallbackUpdatedAt: { $0.updatedAt }, now: now
        )
        let records = ICloudSyncManager.cloudSyncRecords(values: result.values, shadow: result.shadow, id: { $0.id })
        if try ICloudSyncManager.shouldUploadCloudSyncRecords(records, remotePayloadHash: remote.payloadHash) {
            cloud.blob = try ICloudSyncManager.encodeCloudSyncRecords(records)
            device.uploads += 1
        }
        try during()
        var applied = true
        if result.shouldApplyLocally {
            applied = try device.store.applySync(result.values, expecting: local)
            if applied { device.applies += 1 }
        }
        let committed = ICloudSyncManager.shadowToCommit(
            previous: device.shadow, merge: result, local: local, appliedLocally: applied, id: { $0.id }, hash: hash
        )
        device.shadow = try JSONDecoder().decode([String: SyncShadowEntry].self, from: JSONEncoder().encode(committed))
        return applied
    }

    /// A module file. The sync carries bytes, so these need not be a module the app can open.
    static func file(_ id: String, version: String = "1.0.0") -> Data {
        Data(#"{"id":"\#(id)","version":"\#(version)","futureKey":{"kept":true}}"#.utf8)
    }

    /// Puts a module folder on a device as an install would leave it.
    static func put(_ id: String, version: String = "1.0.0", on device: Device, at date: Date) throws {
        let held = try device.store.syncItems()
        let item = RuleModuleSyncItem(id: id, module: file(id, version: version),
                                      subscriptionURL: URL(string: "https://example.com/\(id).json"),
                                      installedAt: date, updatedAt: date)
        #expect(try device.store.applySync(held.filter { $0.id != id } + [item], expecting: held))
    }

    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a module added on one device arrives on the other, byte for byte, and then nothing moves")
    func installArrives() throws {
        let cloud = Cloud(), a = Device(), b = Device()
        try Self.put("example.a", on: a, at: Self.day)
        try Self.pass(a, cloud: cloud, now: Self.day + 10)
        try Self.pass(b, cloud: cloud, now: Self.day + 20)
        #expect(try b.store.syncItems() == a.store.syncItems())
        #expect(try b.store.data(id: "example.a") == Self.file("example.a"))

        let (uploads, applies) = (a.uploads + b.uploads, a.applies + b.applies)
        try Self.pass(a, cloud: cloud, now: Self.day + 30)
        try Self.pass(b, cloud: cloud, now: Self.day + 40)
        #expect(a.uploads + b.uploads == uploads, "a settled pass uploads nothing")
        #expect(a.applies + b.applies == applies, "a settled pass applies nothing")
    }

    @Test("a module removed on one device leaves the other")
    func removalArrives() throws {
        let cloud = Cloud(), a = Device(), b = Device()
        try Self.put("example.a", on: a, at: Self.day)
        try Self.put("example.b", on: a, at: Self.day)
        try Self.pass(a, cloud: cloud, now: Self.day + 10)
        try Self.pass(b, cloud: cloud, now: Self.day + 20)

        try b.store.remove(id: "example.a")
        try Self.pass(b, cloud: cloud, now: Self.day + 30)
        try Self.pass(a, cloud: cloud, now: Self.day + 40)
        #expect(try a.store.syncItems().map(\.id) == ["example.b"])
        #expect(try b.store.syncItems().map(\.id) == ["example.b"])
    }

    @Test("an update replaces the older file on the other device and drops its cached pages")
    func updateArrives() throws {
        let cloud = Cloud(), a = Device(), b = Device()
        try Self.put("example.a", on: a, at: Self.day)
        try Self.pass(a, cloud: cloud, now: Self.day + 10)
        try Self.pass(b, cloud: cloud, now: Self.day + 20)
        let cache = b.store.cacheDirectory(id: "example.a")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        try Self.put("example.a", version: "1.1.0", on: a, at: Self.day + 100)
        try Self.pass(a, cloud: cloud, now: Self.day + 110)
        try Self.pass(b, cloud: cloud, now: Self.day + 120)
        #expect(try b.store.data(id: "example.a") == Self.file("example.a", version: "1.1.0"))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("a module this app cannot open is held on disk and stays on every device")
    func unopenableModuleIsNotRemoved() throws {
        let cloud = Cloud(), a = Device(), b = Device()
        try Self.put("example.future", on: a, at: Self.day)
        try Self.pass(a, cloud: cloud, now: Self.day + 10)
        try Self.pass(b, cloud: cloud, now: Self.day + 20)
        // Not a module the validator takes: the list leaves it out, the sync must not.
        #expect(b.store.list(appVersion: "3.0").modules.isEmpty)

        try Self.pass(b, cloud: cloud, now: Self.day + 30)
        try Self.pass(a, cloud: cloud, now: Self.day + 40)
        #expect(try a.store.syncItems().map(\.id) == ["example.future"])
        #expect(try b.store.syncItems().map(\.id) == ["example.future"])
    }

    @Test("a module added during the round trip is kept, and the merge waits for the next sync")
    func installDuringRoundTrip() throws {
        let cloud = Cloud(), a = Device(), b = Device()
        try Self.put("example.a", on: a, at: Self.day)
        try Self.pass(a, cloud: cloud, now: Self.day + 10)

        let applied = try Self.pass(b, cloud: cloud, now: Self.day + 20) {
            try Self.put("example.mine", on: b, at: Self.day + 15)
        }
        #expect(!applied)
        #expect(try b.store.syncItems().map(\.id) == ["example.mine"])

        try Self.pass(b, cloud: cloud, now: Self.day + 30)
        try Self.pass(a, cloud: cloud, now: Self.day + 40)
        #expect(try a.store.syncItems().map(\.id) == ["example.a", "example.mine"])
        #expect(try b.store.syncItems().map(\.id) == ["example.a", "example.mine"])
    }

    @Test("an id that cannot be a folder, or is an official module's, is never written")
    func unsafeIDIsSkipped() throws {
        let device = Device()
        let unsafe = RuleModuleSyncItem(id: "../outside", module: Self.file("x"), subscriptionURL: nil,
                                        installedAt: Self.day, updatedAt: Self.day)
        #expect(try device.store.applySync([unsafe], expecting: []))
        #expect(try device.store.syncItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: device.folder.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    @Test("a folder that cannot be read throws instead of reading as no modules")
    func unreadableFolderThrows() throws {
        let device = Device()
        try Self.put("example.a", on: device, at: Self.day)
        try FileManager.default.removeItem(at: device.folder.appendingPathComponent("example.a/install.json"))
        #expect(throws: (any Error).self) { try device.store.syncItems() }
    }

    @Test("停用, 在資源庫中展示 and global values follow the reader")
    @MainActor
    func preferencesRoundTrip() throws {
        let suite = "RuleModuleSync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder), officialFiles: { [] },
                                        availability: nil, preferences: defaults)
        #expect(library.preferenceSyncItems.isEmpty)

        let arrived = [
            RuleModulePreferenceSyncItem(id: "example.a", disabled: true, hiddenInLibrary: false, globalValues: [:]),
            RuleModulePreferenceSyncItem(id: "example.b", disabled: false, hiddenInLibrary: true, globalValues: ["region": "jp"]),
        ]
        library.applyPreferencesFromSync(arrived)
        #expect(!library.isEnabled("example.a"))
        #expect(!library.isShownInLibrary("example.b"))
        #expect(library.globalValues == ["example.b": ["region": "jp"]])
        #expect(library.preferenceSyncItems == arrived)

        // Read back as a relaunch reads them.
        let relaunched = RuleModuleLibrary(store: RuleModuleStore(directory: folder), officialFiles: { [] },
                                           availability: nil, preferences: defaults)
        #expect(relaunched.preferenceSyncItems == arrived)

        library.setEnabled(true, id: "example.a")
        #expect(library.preferenceSyncItems.map(\.id) == ["example.b"], "back as it came: a deletion the sync carries")
    }

    @Test("subscribed repositories merge in place, and an unreadable list throws")
    func repositories() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModuleSync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleModuleRepositoryStore(file: folder.appendingPathComponent(".repositories.json"))
        let mine = RuleModuleRepositorySubscription(url: URL(string: "https://m.example/index.json")!, name: "Mine")
        let theirs = RuleModuleRepositorySubscription(url: URL(string: "https://a.example/index.json")!, name: "Theirs")
        #expect(try store.syncList().isEmpty)
        try store.add(mine)

        #expect(try store.applySync([theirs, mine], expecting: [mine]))
        #expect(try store.syncList() == [mine, theirs], "those here keep their place")
        #expect(try !store.applySync([theirs], expecting: [mine]), "changed since the merge read it")
        #expect(try store.syncList() == [mine, theirs])

        try Data("not json".utf8).write(to: store.file)
        #expect(store.list().isEmpty)
        #expect(throws: (any Error).self) { try store.syncList() }
    }
}
