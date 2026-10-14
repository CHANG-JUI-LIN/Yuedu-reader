import Foundation

/// An installed module: the file as written, and where it came from.
struct InstalledRuleModule: Hashable, Sendable {
    let module: RuleModule
    /// Where 檢查更新 fetches it again; nil when it was imported from a file.
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
}

/// The installed modules: `Application Support/Modules/<id>/` holds `module.json` (the bytes as
/// imported, so keys a newer app adds survive), `install.json`, and `cache/` for pages kept for
/// an entry's `cacheDuration`. Removing a module deletes its folder.
///
/// Nothing here is cached: each call reads the disk, so the folder is the one owner.
struct RuleModuleStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Modules", isDirectory: true)
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
    /// old rules.
    @discardableResult
    func update(id: String, with data: Data, appVersion: String = RuleModuleVersion.app,
                now: Date = .now) throws -> InstalledRuleModule {
        let installed = try read(folderNamed: id, appVersion: appVersion)
        let module = try validated(data, appVersion: appVersion)
        guard module.id == id else { throw RuleModuleStoreError.differentModule(expected: id, offered: module.id) }
        guard let offered = RuleModuleVersion(module.version), let current = RuleModuleVersion(installed.module.version),
              current < offered else {
            throw RuleModuleStoreError.notNewer(installed: installed.module.version, offered: module.version)
        }
        let folder = folder(for: id)
        let record = InstallRecord(subscriptionURL: installed.subscriptionURL, installedAt: installed.installedAt, updatedAt: now)
        try data.write(to: folder.appendingPathComponent("module.json"), options: .atomic)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("install.json"), options: .atomic)
        let cache = cacheDirectory(id: id)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        return InstalledRuleModule(module: module, subscriptionURL: installed.subscriptionURL,
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

    func cacheDirectory(id: String) -> URL {
        folder(for: id).appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: - Helpers

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
