import Foundation

/// The app's own modules (module ecosystem plan, M2; maintainer, 2026-10-17: 「這些 api 和公有
/// 書庫都算是官方模塊」): module files bundled with the app, in the format readers import and read
/// through the same validator, so whatever an official module can do, a reader's module can.
///
/// They update with the app, cannot be removed, and no import may take their ids. Each is
/// turned off where every module is: its search in 搜尋來源, its fill in 資料來源, its rows by
/// not adding them.
enum OfficialRuleModules {
    /// Bundled, or planned and reserved so that an import cannot take the id first. Listed in
    /// this order.
    static let ids = ["bangumi", "anilist", "openbd", "openlibrary", "narou", "rakuten-books"]
    static let reservedIDs = Set(ids)
    /// Open Library, which replaced the app's own Open Library search and fill (OL3).
    nonisolated static let openLibraryID = "openlibrary"

    /// `Resources/Assets/official-module-<id>.json`.
    static let filePrefix = "official-module-"

    /// Storefront policy, the app's and never a manifest's: なろう is hidden where Gutenberg and
    /// 青空文庫 are (`PublicLibraryAvailability`).
    static func isAvailable(_ id: String, librariesAvailable: Bool) -> Bool {
        id != "narou" || librariesAvailable
    }

    /// The bundled files. The resources folder is flattened into the bundle, so they are found by
    /// name; `Assets` is looked in too, as `BrowserView` does for its scripts.
    static var bundledFiles: [URL] {
        #if DEBUG
        // UI-test hooks, compiled out of Release: `-no-official-modules` keeps tests off the
        // official modules' sites; `-official-modules-dir <path>` reads them from a fixture folder.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-no-official-modules") { return [] }
        if let index = arguments.firstIndex(of: "-official-modules-dir"), arguments.indices.contains(index + 1) {
            return files(in: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        #endif
        let found = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Assets") ?? [])
        return found.filter { $0.lastPathComponent.hasPrefix(filePrefix) }
    }

    static func files(in folder: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(filePrefix) }
        } catch {
            AppLogger.error("Official modules folder unreadable", error: error, context: ["path": folder.path], level: .error)
            return []
        }
    }

    /// The files that pass the validator, each once, in `ids` order. A file that fails is a bug
    /// in this app: it is logged and left out, never shown as a module that cannot be read.
    static func load(_ files: [URL], appVersion: String) -> [InstalledRuleModule] {
        var modules: [String: InstalledRuleModule] = [:]
        for file in files {
            do {
                let module = try RuleModuleValidator.validate(Data(contentsOf: file), appVersion: appVersion)
                guard reservedIDs.contains(module.id), file.lastPathComponent == "\(filePrefix)\(module.id).json" else {
                    AppLogger.error("Official module file misnamed", context: ["file": file.lastPathComponent, "id": module.id],
                                    level: .error)
                    continue
                }
                modules[module.id] = InstalledRuleModule(module: module, subscriptionURL: nil, installedAt: .distantPast,
                                                         updatedAt: .distantPast, isOfficial: true)
            } catch {
                AppLogger.error("Official module refused", error: error, context: ["file": file.lastPathComponent], level: .error)
            }
        }
        return ids.compactMap { modules[$0] }
    }
}
