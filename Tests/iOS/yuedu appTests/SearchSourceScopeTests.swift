import Foundation
import Testing
@testable import yuedu_app

@Suite("Search source scope", .serialized)
struct SearchSourceScopeTests {
    @Test("default scope resolves every enabled source")
    func defaultScopeResolvesEnabledSources() {
        let enabled = makeSource(name: "Enabled", url: "https://enabled.test")
        let disabled = makeSource(
            name: "Disabled",
            url: "https://disabled.test",
            enabled: false
        )

        #expect(
            SearchSourceScope.all
                .resolvedSources(from: [enabled, disabled])
                .map(\.id) == [enabled.id]
        )
    }

    @Test("custom scope resolves only selected enabled source URLs")
    func customScopeFiltersSources() {
        let first = makeSource(name: "First", url: "https://first.test")
        let second = makeSource(name: "Second", url: "https://second.test")
        let disabled = makeSource(
            name: "Disabled",
            url: "https://disabled.test",
            enabled: false
        )
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: [second.bookSourceUrl, disabled.bookSourceUrl]
        )

        #expect(
            scope.resolvedSources(from: [first, second, disabled]).map(\.id)
                == [second.id]
        )
    }

    @Test("source URL keeps custom selection stable across a new UUID")
    func sourceURLSurvivesIdentityChange() {
        let original = makeSource(name: "Original", url: "https://stable.test")
        var reimported = original
        reimported.id = UUID()
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: [original.bookSourceUrl]
        )

        #expect(scope.resolvedSources(from: [reimported]).map(\.id) == [reimported.id])
        #expect(reimported.id != original.id)
    }

    @Test("unavailable custom selection does not fall back to all sources")
    func unavailableSelectionDoesNotFallback() {
        let available = makeSource(name: "Available", url: "https://available.test")
        let scope = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://deleted.test"]
        )

        #expect(scope.resolvedSources(from: [available]).isEmpty)
    }

    @MainActor
    @Test("custom scope round-trips through UserDefaults")
    func customScopePersists() throws {
        let suiteName = "SearchSourceScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://one.test", "https://two.test"]
        )

        let store = SearchSourceScopeStore(defaults: defaults)
        #expect(store.scope == .all)
        store.save(saved)
        let reloaded = SearchSourceScopeStore(defaults: defaults)

        #expect(reloaded.scope == saved)
    }

    private func makeSource(
        name: String,
        url: String,
        enabled: Bool = true
    ) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.enabled = enabled
        return source
    }
}
