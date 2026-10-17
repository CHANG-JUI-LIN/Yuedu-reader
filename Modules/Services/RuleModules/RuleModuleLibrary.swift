import Combine
import Foundation

/// The installed modules, as the app shows them (Phase 6e): the one owner every screen reads —
/// 資源庫's 模組, a module's page, the name a module's book shows under. `RuleModuleStore` is
/// the disk; this is its published copy, read off the main actor and replaced after each write.
///
/// The official modules (`OfficialRuleModules`, M2) are read with it and listed first, so every
/// path that takes the installed modules — rows, search, fill, a section's form — takes them
/// too. Only 資源庫 tells them apart: 官方模組 and 匯入的模組.
///
/// 停用 (M6, maintainer 2026-10-17: 「加『停用』，一鍵全關」) takes a module out of `modules` —
/// and so out of every path above — while `official`, `imported` and `installed(id:)` still list
/// it for the 模組 page, where it is turned back on.
@MainActor
final class RuleModuleLibrary: ObservableObject {
    static let shared = RuleModuleLibrary()

    /// The official modules this storefront has, then the imported ones, oldest install first;
    /// a module turned off (停用) is left out.
    @Published private(set) var modules: [InstalledRuleModule] = []
    /// The imported ones alone: 匯入的模組.
    @Published private(set) var imported: [InstalledRuleModule] = []
    /// The official ones this storefront has: 官方模組.
    @Published private(set) var official: [InstalledRuleModule] = []
    /// Folders that could not be read: reported, never overwritten (6c).
    @Published private(set) var failures: [RuleModuleStore.Failure] = []
    @Published private(set) var isLoaded = false
    /// Turned off on the 模組 page (停用).
    @Published private(set) var disabled: Set<String>
    /// Turned off with 在資源庫中展示: on the 模組 page only, still in use everywhere else.
    @Published private(set) var hiddenInLibrary: Set<String>

    let store: RuleModuleStore
    private let appVersion: String
    /// The language its modules are shown in (`RuleModule.localized(for:)`).
    private let language: String
    private let officialFiles: @Sendable () -> [URL]
    /// Whether this storefront has the public libraries (`OfficialRuleModules.isAvailable`).
    private let librariesAvailable: () -> Bool
    /// Every bundled official module, whatever the storefront.
    private var bundled: [InstalledRuleModule] = []
    private var availabilityChange: AnyCancellable?
    /// The newest read wins: a read that finishes after a later one is dropped.
    private var generation = 0
    private let preferences: UserDefaults
    private static let disabledKey = "ruleModules.disabled"
    private static let hiddenInLibraryKey = "ruleModules.hiddenInLibrary"

    init(store: RuleModuleStore = RuleModuleStore(), appVersion: String = RuleModuleVersion.app,
         officialFiles: @escaping @Sendable () -> [URL] = { OfficialRuleModules.bundledFiles },
         availability: PublicLibraryAvailability? = .shared,
         language: String = Bundle.main.preferredLocalizations.first ?? "en", preferences: UserDefaults = .standard) {
        self.store = store
        self.preferences = preferences
        disabled = Set(preferences.stringArray(forKey: Self.disabledKey) ?? [])
        hiddenInLibrary = Set(preferences.stringArray(forKey: Self.hiddenInLibraryKey) ?? [])
        self.appVersion = appVersion
        self.language = language
        self.officialFiles = officialFiles
        librariesAvailable = { availability?.isAvailable ?? true }
        // The storefront is known after launch, and can change.
        availabilityChange = availability?.$countryCode.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    /// A module in use: nil when it is not installed, or is turned off.
    func module(id: String) -> InstalledRuleModule? {
        modules.first { $0.module.id == id }
    }

    /// Every installed module, those turned off included: the 模組 page.
    var installed: [InstalledRuleModule] { official + imported }

    /// An installed module, in use or not: its page, and the name its books show under.
    func installed(id: String) -> InstalledRuleModule? {
        installed.first { $0.module.id == id }
    }

    /// The file a module was read from, as its author wrote it: 匯出 (M6). An official module's
    /// is the bundled one.
    func file(of installed: InstalledRuleModule) -> URL? {
        guard installed.isOfficial else { return store.moduleFile(id: installed.module.id) }
        let name = OfficialRuleModules.filePrefix + installed.module.id + ".json"
        return officialFiles().first { $0.lastPathComponent == name }
    }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    /// 停用 and its undoing: every screen that reads `modules` follows at once.
    func setEnabled(_ enabled: Bool, id: String) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        preferences.set(disabled.sorted(), forKey: Self.disabledKey)
        publish()
    }

    /// Whether its card is in 資源庫: a module turned off never is.
    func isShownInLibrary(_ id: String) -> Bool { isEnabled(id) && !hiddenInLibrary.contains(id) }

    func setShownInLibrary(_ shown: Bool, id: String) {
        if shown { hiddenInLibrary.remove(id) } else { hiddenInLibrary.insert(id) }
        preferences.set(hiddenInLibrary.sorted(), forKey: Self.hiddenInLibraryKey)
    }

    /// The first read, for a screen that may open before 資源庫 has read it (the Explore home).
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await load()
    }

    /// Reads the disk again.
    func load() async {
        generation += 1
        let current = generation
        let store = store
        let appVersion = appVersion
        let officialFiles = officialFiles
        let language = language
        let started = SourcePerfTrace.now
        let (listing, bundled) = await Task.detached(priority: .userInitiated) {
            var listing = store.list(appVersion: appVersion)
            listing.modules = listing.modules.map { $0.localized(for: language) }
            return (listing, OfficialRuleModules.load(officialFiles(), appVersion: appVersion).map { $0.localized(for: language) })
        }.value
        SourcePerfTrace.record("modules.library.load",
                               "modules=\(listing.modules.count) official=\(bundled.count) failures=\(listing.failures.count)",
                               since: started, thresholdMs: 0)
        guard current == generation else { return }
        self.bundled = bundled
        imported = listing.modules
        failures = listing.failures
        publish()
        isLoaded = true
    }

    private func publish() {
        let available = librariesAvailable()
        let official = bundled.filter { OfficialRuleModules.isAvailable($0.module.id, librariesAvailable: available) }
        if self.official != official { self.official = official }
        let modules = (official + imported).filter { !disabled.contains($0.module.id) }
        if self.modules != modules { self.modules = modules }
    }

    /// Throws `RuleModuleStoreError`.
    @discardableResult
    func install(_ data: Data, from subscriptionURL: URL?) async throws -> InstalledRuleModule {
        let store = store
        let appVersion = appVersion
        let installed = try await Task.detached(priority: .userInitiated) {
            try store.install(data, from: subscriptionURL, appVersion: appVersion)
        }.value
        await load()
        return installed
    }

    @discardableResult
    func update(id: String, with data: Data, from subscriptionURL: URL? = nil) async throws -> InstalledRuleModule {
        let store = store
        let appVersion = appVersion
        let updated = try await Task.detached(priority: .userInitiated) {
            try store.update(id: id, with: data, from: subscriptionURL, appVersion: appVersion)
        }.value
        await load()
        return updated
    }

    /// Deletes the module's folder, cache included, and its 停用 and 在資源庫中展示: installed
    /// again, it starts on.
    func remove(id: String) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) { try store.remove(id: id) }.value
        if disabled.contains(id) { setEnabled(true, id: id) }
        if hiddenInLibrary.contains(id) { setShownInLibrary(true, id: id) }
        await load()
    }
}
