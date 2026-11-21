import Foundation

/// What a WebDAV backup holds beside the shelf, 來源配置 and replace rules (2026-11-21): the
/// modules, 探索's home with its photos, and the settings that shape it. Each is one file under
/// `/yuedu/`, built from and restored through the same entries the iCloud sync uses
/// (`RuleModuleStore.syncItems`, `HomePageStore.backupData`, …), so there is one way in and out
/// of each store. `WebDAVManager` only moves the bytes.
///
/// A restore replaces what this device holds, as a restore of the shelf does. A backup made
/// before these files existed has none of them, and restores none.
enum WebDAVLibraryExtras {
    static let modulesPath = "/yuedu/modules.json"
    static let homePath = "/yuedu/explore_home.json"
    static let homePhotosPath = "/yuedu/explore_home_photos.json"
    static let settingsPath = "/yuedu/explore_settings.json"

    // MARK: Modules

    struct Modules: Codable {
        var modules: [RuleModuleSyncItem]
        var preferences: [RuleModulePreferenceSyncItem]
        var repositories: [RuleModuleRepositorySubscription]
    }

    static func modulesData(library: RuleModuleLibrary, repositories: RuleModuleRepositoryStore = RuleModuleRepositoryStore()) async throws -> Data {
        let store = library.store
        let backup = Modules(modules: try store.syncItems(), preferences: await library.preferenceSyncItems,
                             repositories: try repositories.syncList())
        return try encoder.encode(backup)
    }

    static func restoreModules(_ data: Data, library: RuleModuleLibrary,
                               repositories: RuleModuleRepositoryStore = RuleModuleRepositoryStore()) async throws {
        let backup = try JSONDecoder().decode(Modules.self, from: data)
        let store = library.store
        // Nothing else writes the folder between the read and the apply here; a module added
        // in that instant refuses the restore, which is then reported.
        guard try store.applySync(backup.modules, expecting: store.syncItems()),
              try repositories.applySync(backup.repositories, expecting: repositories.syncList()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        await library.load()
        await library.applyPreferencesFromSync(backup.preferences)
    }

    // MARK: The home

    /// Nil before the home is made, and for a home this launch only reads.
    static func homeData(home: HomePageStore) async throws -> Data? {
        try await home.backupData()
    }

    /// Returns whether the home was restored (`HomePageStore.restore`).
    @discardableResult
    static func restoreHome(_ data: Data, home: HomePageStore) async throws -> Bool {
        try await home.restore(fromBackup: data)
    }

    struct Photos: Codable {
        struct Photo: Codable {
            var kind: HomePhotoSyncItem.Kind
            var name: String
            /// The JPEG, as it is on disk.
            var data: Data
        }

        var photos: [Photo]
    }

    /// The home's photos, those of what it still holds; nil when there is no home to back up.
    static func homePhotosData(home: HomePageStore) async throws -> Data? {
        guard let scope = await home.photoNames else { return nil }
        let (configurationPhotos, cardPhotos) = await (home.photos, home.cardPhotos)
        let photos = try configurationPhotos.storedPhotos(named: scope.configurations).map {
            Photos.Photo(kind: .configuration, name: $0.name, data: try Data(contentsOf: $0.url))
        } + cardPhotos.storedPhotos(named: scope.cards).map {
            Photos.Photo(kind: .card, name: $0.name, data: try Data(contentsOf: $0.url))
        }
        return try encoder.encode(Photos(photos: photos))
    }

    /// After the home: the photos of what the restored home holds, in place of this device's.
    static func restoreHomePhotos(_ data: Data, home: HomePageStore) async throws {
        guard let scope = await home.photoNames else { return }
        let backup = try JSONDecoder().decode(Photos.self, from: data)
        let (configurationPhotos, cardPhotos) = await (home.photos, home.cardPhotos)
        let kept = Set(backup.photos.map { "\($0.kind.rawValue)/\($0.name)" })
        for photo in try configurationPhotos.storedPhotos(named: scope.configurations)
        where !kept.contains("\(HomePhotoSyncItem.Kind.configuration.rawValue)/\(photo.name)") {
            try configurationPhotos.replaceStoredPhoto(named: photo.name, with: nil)
        }
        for photo in try cardPhotos.storedPhotos(named: scope.cards)
        where !kept.contains("\(HomePhotoSyncItem.Kind.card.rawValue)/\(photo.name)") {
            try cardPhotos.replaceStoredPhoto(named: photo.name, with: nil)
        }
        for photo in backup.photos {
            switch photo.kind {
            case .configuration: try configurationPhotos.replaceStoredPhoto(named: photo.name, with: photo.data)
            case .card: try cardPhotos.replaceStoredPhoto(named: photo.name, with: photo.data)
            }
        }
        await MainActor.run {
            configurationPhotos.reloadFromDisk()
            cardPhotos.reloadFromDisk()
        }
    }

    // MARK: Settings

    struct Settings: Codable {
        /// 自動補齊's order; nil while the reader has set none.
        var fillOrder: MetadataFillOrderSyncRecord?
        /// 聚合設定; nil while what is stored cannot be read.
        var aggregation: [AggregationSettingSyncItem]?
    }

    static func settingsData(fillOrder: MetadataFillOrderStore, aggregation: AggregationSettingsStore) async throws -> Data {
        let backup = Settings(fillOrder: try await fillOrder.syncRecord(), aggregation: await aggregation.syncItems)
        return try encoder.encode(backup)
    }

    static func restoreSettings(_ data: Data, fillOrder: MetadataFillOrderStore, aggregation: AggregationSettingsStore) async throws {
        let backup = try JSONDecoder().decode(Settings.self, from: data)
        await MainActor.run {
            if let order = backup.fillOrder { fillOrder.applyFromSync(order) }
            if let settings = backup.aggregation { aggregation.applyFromSync(settings) }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
