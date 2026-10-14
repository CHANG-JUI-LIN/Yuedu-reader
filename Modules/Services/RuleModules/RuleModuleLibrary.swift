import Combine
import Foundation

/// The installed modules, as the app shows them (Phase 6e): the one owner every screen reads —
/// 資源庫's 模組, a module's page, the name a module's book shows under. `RuleModuleStore` is
/// the disk; this is its published copy, read off the main actor and replaced after each write.
@MainActor
final class RuleModuleLibrary: ObservableObject {
    static let shared = RuleModuleLibrary()

    /// Oldest install first.
    @Published private(set) var modules: [InstalledRuleModule] = []
    /// Folders that could not be read: reported, never overwritten (6c).
    @Published private(set) var failures: [RuleModuleStore.Failure] = []
    @Published private(set) var isLoaded = false

    let store: RuleModuleStore
    private let appVersion: String
    /// The newest read wins: a read that finishes after a later one is dropped.
    private var generation = 0

    init(store: RuleModuleStore = RuleModuleStore(), appVersion: String = RuleModuleVersion.app) {
        self.store = store
        self.appVersion = appVersion
    }

    func module(id: String) -> InstalledRuleModule? {
        modules.first { $0.module.id == id }
    }

    /// Reads the disk again.
    func load() async {
        generation += 1
        let current = generation
        let store = store
        let appVersion = appVersion
        let started = SourcePerfTrace.now
        let listing = await Task.detached(priority: .userInitiated) { store.list(appVersion: appVersion) }.value
        SourcePerfTrace.record("modules.library.load", "modules=\(listing.modules.count) failures=\(listing.failures.count)",
                               since: started, thresholdMs: 0)
        guard current == generation else { return }
        modules = listing.modules
        failures = listing.failures
        isLoaded = true
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
