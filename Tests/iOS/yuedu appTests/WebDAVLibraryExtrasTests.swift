import Foundation
import Testing
@testable import yuedu_app

/// What a WebDAV backup holds beside the shelf (`WebDAVLibraryExtras`): made on one device's
/// stores and restored into another's, without a server. A restore replaces what the device
/// holds.
@MainActor
@Suite("WebDAV backup: modules, the explore home and its settings", .serialized)
struct WebDAVLibraryExtrasTests {
    /// One device's stores, in a folder and a preferences suite of their own.
    final class Device {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webdav-extras-\(UUID().uuidString)")
        let suite = "WebDAVLibraryExtrasTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let library: RuleModuleLibrary
        let repositories: RuleModuleRepositoryStore
        let home: HomePageStore
        let fillOrder: MetadataFillOrderStore
        let aggregation: AggregationSettingsStore

        @MainActor init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            let modules = folder.appendingPathComponent("Modules")
            library = RuleModuleLibrary(store: RuleModuleStore(directory: modules), officialFiles: { [] },
                                        availability: nil, preferences: defaults)
            repositories = RuleModuleRepositoryStore(file: modules.appendingPathComponent(".repositories.json"))
            home = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"), defaults: defaults)
            fillOrder = MetadataFillOrderStore(defaults: defaults)
            aggregation = AggregationSettingsStore(defaults: defaults)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func module(_ id: String) -> RuleModuleSyncItem {
        RuleModuleSyncItem(id: id, module: Data(#"{"id":"\#(id)"}"#.utf8), subscriptionURL: nil,
                           installedAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("modules, their settings and the repositories are restored in place of the device's own")
    func modules() async throws {
        let source = try Device(), target = try Device()
        #expect(try source.library.store.applySync([module("example.a"), module("example.b")], expecting: []))
        source.library.setEnabled(false, id: "example.b")
        let repository = RuleModuleRepositorySubscription(url: URL(string: "https://m.example/index.json")!, name: "Mine")
        try source.repositories.add(repository)
        // What the target had goes: a restore is the backup.
        #expect(try target.library.store.applySync([module("example.old")], expecting: []))
        target.library.setEnabled(false, id: "example.old")

        let data = try await WebDAVLibraryExtras.modulesData(library: source.library, repositories: source.repositories)
        try await WebDAVLibraryExtras.restoreModules(data, library: target.library, repositories: target.repositories)

        #expect(try target.library.store.syncItems() == source.library.store.syncItems())
        #expect(target.library.preferenceSyncItems == source.library.preferenceSyncItems)
        #expect(try target.repositories.syncList() == [repository])
    }

    @Test("the home and its photos are restored; a newer build's home is left alone")
    func home() async throws {
        let source = try Device(), target = try Device()
        #expect(try await WebDAVLibraryExtras.homeData(home: source.home) == nil, "no home made yet")
        let context = HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        _ = source.home.pageOrDefaults(mode: context.mode, publicLibrariesAvailable: true, languages: context.languages)
        source.home.createConfiguration(named: "通勤", from: .blank, defaults: context)
        try source.home.photos.replaceStoredPhoto(named: "default", with: Data([1, 2, 3]))
        _ = target.home.pageOrDefaults(mode: context.mode, publicLibrariesAvailable: true, languages: context.languages)
        try target.home.photos.replaceStoredPhoto(named: "default", with: Data([7]))

        let data = try #require(try await WebDAVLibraryExtras.homeData(home: source.home))
        let photos = try #require(try await WebDAVLibraryExtras.homePhotosData(home: source.home))
        #expect(try await WebDAVLibraryExtras.restoreHome(data, home: target.home))
        try await WebDAVLibraryExtras.restoreHomePhotos(photos, home: target.home)

        #expect(target.home.home == source.home.home)
        #expect(target.home.selectedConfiguration == source.home.selectedConfiguration)
        let restored = try target.home.photos.storedPhotos(named: ["default"])
        #expect(try restored.map { try Data(contentsOf: $0.url) } == [Data([1, 2, 3])])

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = HomePage.currentSchemaVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        let before = target.home.home
        #expect(try await !WebDAVLibraryExtras.restoreHome(newer, home: target.home))
        #expect(target.home.home == before)
    }

    @Test("自動補齊's order and 聚合設定 are restored; unset on the backup's device, they are left as they are")
    func settings() async throws {
        let source = try Device(), target = try Device()
        target.aggregation.setHidesRead(false)
        let empty = try await WebDAVLibraryExtras.settingsData(fillOrder: source.fillOrder, aggregation: source.aggregation)
        try await WebDAVLibraryExtras.restoreSettings(empty, fillOrder: target.fillOrder, aggregation: target.aggregation)
        #expect(target.aggregation.settings.hidesRead == false)

        source.fillOrder.applyFromSync(MetadataFillOrderSyncRecord(entries: [["place": "bookSources", "enabled": "0"]]))
        source.aggregation.setMetadataLanguage("ja")
        let data = try await WebDAVLibraryExtras.settingsData(fillOrder: source.fillOrder, aggregation: source.aggregation)
        try await WebDAVLibraryExtras.restoreSettings(data, fillOrder: target.fillOrder, aggregation: target.aggregation)
        #expect(target.fillOrder.stored.first?.isEnabled == false)
        #expect(target.aggregation.settings.metadataLanguage == "ja")
    }
}
