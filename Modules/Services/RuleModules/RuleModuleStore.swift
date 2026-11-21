import Foundation

/// An installed module: the file as written, and where it came from.
struct InstalledRuleModule: Hashable, Sendable {
    let module: RuleModule
    /// Where 檢查更新 fetches it again; nil when it was imported from a file.
    let subscriptionURL: URL?
    let installedAt: Date
    let updatedAt: Date
    /// Bundled with the app (`OfficialRuleModules`): never removed, updated with the app.
    var isOfficial = false

    /// Shown in `language`; the file on disk is as written.
    func localized(for language: String) -> InstalledRuleModule {
        InstalledRuleModule(module: module.localized(for: language), subscriptionURL: subscriptionURL,
                            installedAt: installedAt, updatedAt: updatedAt, isOfficial: isOfficial)
    }
}

/// An imported module as the iCloud sync carries it: its file as written and its install
/// record. Official modules come with the app and are never among them.
struct RuleModuleSyncItem: Codable, Equatable, Sendable {
    /// The folder's name, which is the module's id.
    let id: String
    /// `module.json`, byte for byte.
    let module: Data
    let subscriptionURL: URL?
    let installedAt: Date
    let updatedAt: Date
}

enum RuleModuleStoreError: Error, Equatable, Sendable {
    case rejected(RuleModuleRejection)
    case alreadyInstalled(String)
    case notInstalled(String)
    /// An update must carry the module it updates.
    case differentModule(expected: String, offered: String)
    /// 已是最新版本.
    case notNewer(installed: String, offered: String)
    /// An official module's id (`OfficialRuleModules.reservedIDs`).
    case reservedID(String)
}

/// The installed modules: `Application Support/Modules/<id>/` holds `module.json` (the bytes as
/// imported, so keys a newer app adds survive), `install.json`, and `cache/` for pages kept for
/// an entry's `cacheDuration`. Removing a module deletes its folder.
///
/// Nothing here is cached: each call reads the disk, so the folder is the one owner.
struct RuleModuleStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        #if DEBUG
        // UI-test hook: `-rule-module-store-dir <path>` points every store (the library and each
        // module's page cache) at a scratch folder. Compiled out of Release.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-rule-module-store-dir"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("Modules", isDirectory: true)
    }

    init(directory: URL = RuleModuleStore.defaultDirectory) {
        self.directory = directory
    }

    /// A folder that could not be read, reported and left as it is.
    struct Failure: Hashable, Sendable {
        let folder: String
        let reason: String
    }

    struct Listing: Sendable {
        /// Oldest install first.
        var modules: [InstalledRuleModule]
        var failures: [Failure]
    }

    private struct InstallRecord: Codable {
        var subscriptionURL: URL?
        var installedAt: Date
        var updatedAt: Date
    }

    // MARK: - Writes

    /// A module not installed yet. The folder appears whole or not at all: it is written beside
    /// the others under a hidden name and moved into place.
    @discardableResult
    func install(_ data: Data, from subscriptionURL: URL?, appVersion: String = RuleModuleVersion.app,
                 now: Date = .now) throws -> InstalledRuleModule {
        let module = try validated(data, appVersion: appVersion)
        guard !OfficialRuleModules.reservedIDs.contains(module.id) else { throw RuleModuleStoreError.reservedID(module.id) }
        let folder = folder(for: module.id)
        // A folder that is there but unreadable is never overwritten: it is reported by `list()`.
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw RuleModuleStoreError.alreadyInstalled(module.id)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let record = InstallRecord(subscriptionURL: subscriptionURL, installedAt: now, updatedAt: now)
        do {
            try data.write(to: staging.appendingPathComponent("module.json"), options: .atomic)
            try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("install.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            removeStaging(staging)
            throw error
        }
        return InstalledRuleModule(module: module, subscriptionURL: subscriptionURL, installedAt: now, updatedAt: now)
    }

    /// A newer version of an installed module, replacing its file. Its cached pages go with the
    /// old rules. `subscriptionURL`, when given, is where the update came from — a repository's
    /// address for the module (M6) — and becomes the address 檢查更新 reads; nil keeps the old one.
    @discardableResult
    func update(id: String, with data: Data, from subscriptionURL: URL? = nil, appVersion: String = RuleModuleVersion.app,
                now: Date = .now) throws -> InstalledRuleModule {
        let installed = try read(folderNamed: id, appVersion: appVersion)
        let module = try validated(data, appVersion: appVersion)
        guard module.id == id else { throw RuleModuleStoreError.differentModule(expected: id, offered: module.id) }
        guard let offered = RuleModuleVersion(module.version), let current = RuleModuleVersion(installed.module.version),
              current < offered else {
            throw RuleModuleStoreError.notNewer(installed: installed.module.version, offered: module.version)
        }
        let folder = folder(for: id)
        let subscriptionURL = subscriptionURL ?? installed.subscriptionURL
        let record = InstallRecord(subscriptionURL: subscriptionURL, installedAt: installed.installedAt, updatedAt: now)
        try data.write(to: folder.appendingPathComponent("module.json"), options: .atomic)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("install.json"), options: .atomic)
        let cache = cacheDirectory(id: id)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        return InstalledRuleModule(module: module, subscriptionURL: subscriptionURL,
                                   installedAt: installed.installedAt, updatedAt: now)
    }

    /// Deletes the module's folder, cache included.
    func remove(id: String) throws {
        guard RuleModuleValidator.isFileSafe(id) else { throw RuleModuleStoreError.notInstalled(id) }
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw RuleModuleStoreError.notInstalled(id) }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Reads

    func list(appVersion: String = RuleModuleVersion.app) -> Listing {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])
        } catch CocoaError.fileReadNoSuchFile {
            return Listing(modules: [], failures: [])
        } catch {
            AppLogger.error("Modules folder unreadable", error: error, context: ["path": directory.path], level: .error)
            return Listing(modules: [], failures: [])
        }
        var listing = Listing(modules: [], failures: [])
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do {
                listing.modules.append(try read(folderNamed: folder.lastPathComponent, appVersion: appVersion))
            } catch {
                AppLogger.error("Module skipped", error: error, context: ["folder": folder.lastPathComponent], level: .error)
                listing.failures.append(Failure(folder: folder.lastPathComponent, reason: String(describing: error)))
            }
        }
        listing.modules.sort { ($0.installedAt, $0.module.id) < ($1.installedAt, $1.module.id) }
        return listing
    }

    /// The bytes as installed.
    func data(id: String) throws -> Data {
        guard RuleModuleValidator.isFileSafe(id) else { throw RuleModuleStoreError.notInstalled(id) }
        return try Data(contentsOf: folder(for: id).appendingPathComponent("module.json"))
    }

    /// An official module has no folder of its own: its pages are kept under a hidden one,
    /// which `list()` skips, so its cache is never read as a module that cannot be opened.
    func cacheDirectory(id: String) -> URL {
        guard OfficialRuleModules.reservedIDs.contains(id) else {
            return folder(for: id).appendingPathComponent("cache", isDirectory: true)
        }
        return directory.appendingPathComponent(".official", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true).appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: - Sync

    /// Every module folder as it is on disk, for the iCloud sync: the bytes, never the parsed
    /// module, so one this app cannot open (it asks for a newer app) is still held — a folder
    /// left out here would be read as a module removed on this device and deleted on the others.
    /// Only a folder that is not there yet is empty; any other failure to read throws, for the
    /// same reason.
    func syncItems() throws -> [RuleModuleSyncItem] {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var items: [RuleModuleSyncItem] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let data = try Data(contentsOf: folder.appendingPathComponent("module.json"))
            let record = try JSONDecoder().decode(InstallRecord.self,
                                                  from: try Data(contentsOf: folder.appendingPathComponent("install.json")))
            items.append(RuleModuleSyncItem(id: folder.lastPathComponent, module: data, subscriptionURL: record.subscriptionURL,
                                            installedAt: record.installedAt, updatedAt: record.updatedAt))
        }
        return items
    }

    /// Makes the folder what a sync merged: writes each module that is new or different (its
    /// cached pages go with the old file), and removes each that is no longer among them.
    /// Returns false, changing nothing, when the folder is not `local` any more — a module
    /// installed, updated or removed during the round trip, which the merge never saw and the
    /// next sync carries.
    func applySync(_ items: [RuleModuleSyncItem], expecting local: [RuleModuleSyncItem]) throws -> Bool {
        let current = try syncItems()
        guard current == local else { return false }
        let held = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items where held[item.id] != item {
            // The id becomes a folder name: one that is not a safe name, or is an official
            // module's, is never written, whatever the cloud holds.
            guard RuleModuleValidator.isFileSafe(item.id), !OfficialRuleModules.reservedIDs.contains(item.id) else {
                AppLogger.sync("⟐ synced module skipped, its id cannot be a folder: \(item.id)", level: .error)
                continue
            }
            try write(item)
        }
        let wanted = Set(items.map(\.id))
        for item in current where !wanted.contains(item.id) {
            try FileManager.default.removeItem(at: folder(for: item.id))
        }
        return true
    }

    private func write(_ item: RuleModuleSyncItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let record = InstallRecord(subscriptionURL: item.subscriptionURL, installedAt: item.installedAt, updatedAt: item.updatedAt)
        let folder = folder(for: item.id)
        do {
            try item.module.write(to: staging.appendingPathComponent("module.json"), options: .atomic)
            try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("install.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            removeStaging(staging)
            throw error
        }
    }

    // MARK: - Helpers

    /// The module's file as it was installed: 匯出 on its page (M6).
    func moduleFile(id: String) -> URL {
        folder(for: id).appendingPathComponent("module.json")
    }

    private func folder(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    private func validated(_ data: Data, appVersion: String) throws -> RuleModule {
        do {
            return try RuleModuleValidator.validate(data, appVersion: appVersion)
        } catch {
            throw RuleModuleStoreError.rejected(error)
        }
    }

    /// The module in a folder, checked as it was at import; the folder must be named for it.
    private func read(folderNamed name: String, appVersion: String) throws -> InstalledRuleModule {
        guard RuleModuleValidator.isFileSafe(name) else { throw RuleModuleStoreError.notInstalled(name) }
        let folder = folder(for: name)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw RuleModuleStoreError.notInstalled(name) }
        let module = try validated(try Data(contentsOf: folder.appendingPathComponent("module.json")), appVersion: appVersion)
        guard module.id == name else { throw RuleModuleStoreError.differentModule(expected: name, offered: module.id) }
        let record = try JSONDecoder().decode(InstallRecord.self,
                                              from: try Data(contentsOf: folder.appendingPathComponent("install.json")))
        return InstalledRuleModule(module: module, subscriptionURL: record.subscriptionURL,
                                   installedAt: record.installedAt, updatedAt: record.updatedAt)
    }

    private func removeStaging(_ staging: URL) {
        do { try FileManager.default.removeItem(at: staging) } catch {
            AppLogger.error("Module staging folder left behind", error: error, context: ["path": staging.path], level: .warning)
        }
    }
}
