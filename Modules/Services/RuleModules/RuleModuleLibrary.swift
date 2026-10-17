import Combine
import Foundation

/// The installed modules, as the app shows them (Phase 6e): the one owner every screen reads —
/// 資源庫's 模組, a module's page, the name a module's book shows under. `RuleModuleStore` is
/// the disk; this is its published copy, read off the main actor and replaced after each write.
///
/// The official modules (`OfficialRuleModules`, M2) are read with it and listed first, so every
/// path that takes the installed modules — rows, search, fill, a section's form — takes them
/// too. Only 資源庫 tells them apart: 官方模組 and 匯入的模組.
@MainActor
final class RuleModuleLibrary: ObservableObject {
    static let shared = RuleModuleLibrary()

    /// The official modules this storefront has, then the imported ones, oldest install first.
    @Published private(set) var modules: [InstalledRuleModule] = []
    /// The imported ones alone: 匯入的模組.
    @Published private(set) var imported: [InstalledRuleModule] = []
    /// The official ones this storefront has: 官方模組.
    @Published private(set) var official: [InstalledRuleModule] = []
    /// Folders that could not be read: reported, never overwritten (6c).
    @Published private(set) var failures: [RuleModuleStore.Failure] = []
    @Published private(set) var isLoaded = false

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

    init(store: RuleModuleStore = RuleModuleStore(), appVersion: String = RuleModuleVersion.app,
         officialFiles: @escaping @Sendable () -> [URL] = { OfficialRuleModules.bundledFiles },
         availability: PublicLibraryAvailability? = .shared,
         language: String = Bundle.main.preferredLocalizations.first ?? "en") {
        self.store = store
        self.appVersion = appVersion
        self.language = language
        self.officialFiles = officialFiles
        librariesAvailable = { availability?.isAvailable ?? true }
        // The storefront is known after launch, and can change.
        availabilityChange = availability?.$countryCode.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    func module(id: String) -> InstalledRuleModule? {
        modules.first { $0.module.id == id }
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
        let modules = official + imported
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
    func update(id: String, with data: Data) async throws -> InstalledRuleModule {
        let store = store
        let appVersion = appVersion
        let updated = try await Task.detached(priority: .userInitiated) {
            try store.update(id: id, with: data, appVersion: appVersion)
        }.value
        await load()
        return updated
    }

    /// Deletes the module's folder, cache included.
    func remove(id: String) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) { try store.remove(id: id) }.value
        await load()
    }
}
