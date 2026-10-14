import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified search 4c-1's cost on the main actor: the same 2,000 results merged under 換源's
/// rule (the pre-4c-1 path, unchanged) and under 搜索's work rule. Run with
/// `TEST_RUNNER_YUEDU_SEARCH_BENCHMARK=1`; read the ⏱ `search.presentation.mainMerge` and
/// `search.presentation.workKeys` lines and the `bench` lines. Asserts nothing about time.
@MainActor
@Suite("Search work merge benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_SEARCH_BENCHMARK"] == "1"))
struct SearchWorkMergeBenchmarkTests {
    @Test("2,000 results from two sources, 換源's rule then the work rule, 3 runs each")
    func mergeCost() async throws {
        for run in 1...3 {
            for origin in [SearchOrigin.changeSource, .searchTab] {
                let tag = "bench-\(origin.rawValue)-\(run)"
                let sources = [makeSource("\(tag)-a"), makeSource("\(tag)-b")]
                let batches = sources.map { source in
                    (source, (0..<1_000).map { i in
                        // Half Traditional, half Simplified titles, as aggregate sources mix them.
                        book(i.isMultiple(of: 2) ? "三體第\(i)部" : "三体第\(i)部", "作者\(i % 50)", in: source, path: "\(i)")
                    })
                }
                let clock = ContinuousClock()
                let started = clock.now
                let rows = try await search("三體", batches, origin: origin)
                let elapsed = clock.now - started
                let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                print("⏱ bench search.merge origin=\(origin.rawValue) run=\(run) rows=\(rows) total=\(Int(ms))ms")
            }
        }
    }

    @Test("the resolver over 1,000 source rows, 50 library books and 20 Open Library works, 3 runs")
    func resolverCost() {
        let rows = (0..<1_000).map { i in
            let keys = SearchWorkKeys(name: i.isMultiple(of: 2) ? "三體第\(i % 300)部" : "三体第\(i % 300)部", author: "作者\(i % 50)")
            return SearchCandidate(id: .bookSourceRow(UUID()), kind: .bookSource, title: "三體第\(i % 300)部", titleKey: keys.title,
                                   authorKeys: [keys.author], contentKind: .text, language: nil, identifiers: [],
                                   itemKeys: [SourceItemKey(instance: SourceInstanceKey(type: .bookSource, id: "s\(i % 7)"), item: "\(i)")],
                                   isReadable: true, sourceCount: 1 + i % 3)
        }
        let others = (0..<70).map { i in
            let title = "三體第\(i)部"
            return SearchCandidate(id: .item(SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: "\(i)")),
                                   kind: i < 50 ? .library : .bibliographic, title: title, titleKey: WorkMatchKey.title(title),
                                   authorKeys: [WorkMatchKey.author("作者\(i % 50)")], contentKind: .text, language: nil,
                                   identifiers: [], itemKeys: [SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: "\(i)")],
                                   isReadable: i < 50, sourceCount: 1)
        }
        for run in 1...3 {
            let clock = ContinuousClock()
            let started = clock.now
            let works = SearchWorkResolver.resolve(rows + others, query: "三體")
            let elapsed = clock.now - started
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print("⏱ bench search.resolve run=\(run) candidates=\(rows.count + others.count) works=\(works.count) total=\(String(format: "%.1f", ms))ms")
        }
    }

    @Test("搜索's one list over 1,000 source rows: main-actor candidates, the merge, the iOS 17 rows; 3 runs")
    func unifiedUpdateCost() async {
        // As the aggregator publishes them: keys folded off the main actor when the book arrived.
        let rows = (0..<1_000).map { i in
            let name = i.isMultiple(of: 2) ? "三體第\(i % 300)部" : "三体第\(i % 300)部"
            let origins = (0...(i % 3)).map { o in
                BookOrigin(sourceId: UUID(), sourceName: "S\(o)", bookUrl: "https://bench.test/\(i)/\(o)", tocUrl: "",
                           coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
            }
            return SearchBook(name: name, author: "作者\(i % 50)", workKeys: SearchWorkKeys(name: name, author: "作者\(i % 50)"),
                              preparedOrigins: SearchResultPresentationBuilder.prepareOrigins(origins, sourceStore: .shared))
        }
        let model = UnifiedSearchModel(sourceURL: { "https://source.test/\($0.uuidString)" })
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> String {
            String(format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        for run in 1...3 {
            let started = clock.now
            await model.update(UnifiedSearchParts(sources: rows), query: "三體")
            let updated = clock.now
            let table = model.rows.map { IOS17SearchResultTableRow(unified: $0, colorScheme: .light, filledCover: { _ in nil }) }
            print("⏱ bench search.unified run=\(run) rows=\(rows.count) works=\(model.rows.count) update=\(ms(updated - started))ms iOS17Rows=\(table.count) \(ms(clock.now - updated))ms")
        }
    }

    // MARK: - Helpers (as `SearchAggregatorCharacterizationTests`)

    private func search(_ query: String, _ batches: [(BookSource, [OnlineBook])], origin: SearchOrigin) async throws -> Int {
        let settings = GlobalSettings.shared
        let savedCacheDays = settings.searchCacheDays
        settings.searchCacheDays = 1
        let cache = SearchResultCache.shared
        for (source, books) in batches {
            cache.store(books: books, query: query, source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()
        let aggregator = SearchAggregator()
        defer {
            aggregator.cancelAndClear()
            for (source, _) in batches { cache.clear(query: query, source: source) }
            settings.searchCacheDays = savedCacheDays
        }
        aggregator.search(query: query, sources: batches.map(\.0), origin: origin)
        // Polls the published flag, as the characterization tests do: the test owns no
        // completion signal of the aggregator's.
        let deadline = Date().addingTimeInterval(60)
        while aggregator.isSearching, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!aggregator.isSearching)
        return aggregator.results.count
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Bench \(name)"
        source.bookSourceUrl = "https://bench-search.test/\(name)"
        source.searchUrl = "https://bench-search.test/\(name)/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func book(_ name: String, _ author: String, in source: BookSource, path: String) -> OnlineBook {
        OnlineBook(name: name, author: author, intro: "", coverUrl: "",
                   bookUrl: "\(source.bookSourceUrl)/\(path)", tocUrl: "\(source.bookSourceUrl)/\(path)/toc",
                   wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName)
    }
}
