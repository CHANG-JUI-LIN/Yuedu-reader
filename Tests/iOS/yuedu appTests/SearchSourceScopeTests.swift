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

    @MainActor
    @Test("cancel and clear resets aggregate search state")
    func cancelAndClearResetsSearchState() {
        var source = makeSource(name: "Pending", url: "https://pending.invalid")
        source.searchUrl = "https://pending.invalid/search?q={{key}}"
        source.ruleSearch.bookList = ".book"
        source.ruleSearch.name = ".name"
        source.ruleSearch.bookUrl = "a@href"
        let aggregator = SearchAggregator()

        aggregator.search(query: "scope", sources: [source])
        #expect(aggregator.isSearching)
        #expect(aggregator.progress.total == 1)
        aggregator.pause()
        #expect(aggregator.isPaused)

        aggregator.cancelAndClear()

        #expect(!aggregator.isSearching)
        #expect(!aggregator.isPaused)
        #expect(aggregator.results.isEmpty)
        #expect(!aggregator.hasMoreResults)
        #expect(aggregator.progress.total == 0)
        #expect(aggregator.progress.completed == 0)
        #expect(aggregator.progress.failed == 0)
        #expect(aggregator.progress.timedOut == 0)
        #expect(aggregator.progress.skipped == 0)
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
