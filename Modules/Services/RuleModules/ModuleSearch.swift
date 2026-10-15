import Foundation

/// The installed modules in 搜索 (Phase 6g): each module with a `search` is asked on submit,
/// never as you type, beside the saved libraries and against its own timeout, so one module
/// failing marks only its own status line. Its books are data only (`ModuleProvider.entry`),
/// merged into works with everything else by `SearchWorkResolver`.
@MainActor
final class ModuleSearch: SearchAnswering {
    static let timeout: Duration = .seconds(20)

    private let providers: @MainActor () -> [ModuleProvider]
    private let timeout: Duration

    private let shown: @MainActor (SourceInstanceKey) -> Bool

    init(providers: (@MainActor () -> [ModuleProvider])? = nil, timeout: Duration = ModuleSearch.timeout,
         shown: (@MainActor (SourceInstanceKey) -> Bool)? = nil) {
        self.providers = providers ?? { SourceProviderRegistry.moduleProviders(in: .shared) }
        self.timeout = timeout
        self.shown = shown ?? { AggregationSettingsStore.shared.isShownInSearch($0) }
    }

    /// The modules a search asks: those with a search that 搜尋來源 keeps checked (search 9d).
    private var searching: [ModuleProvider] { providers().filter { $0.module.search != nil && shown($0.instance) } }

    var isAvailable: Bool { !searching.isEmpty }

    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let modules = searching
        guard !query.isEmpty, !modules.isEmpty else { return }
        let timeout = timeout
        await withTaskGroup(of: LibrarySearchAnswer?.self) { group in
            for module in modules {
                group.addTask { await Self.answer(module, query: query, timeout: timeout) }
            }
            for await answer in group {
                guard !Task.isCancelled else { return }
                if let answer { onAnswer(answer) }
            }
        }
    }

    /// Nil when the search was cancelled: it was replaced or cleared, and nobody reads it.
    private static func answer(_ module: ModuleProvider, query: String, timeout: Duration) async -> LibrarySearchAnswer? {
        let started = SourcePerfTrace.now
        func finish(_ outcome: LibrarySearchAnswer.Outcome, _ entries: [CollectionEntry] = []) -> LibrarySearchAnswer {
            let label: String = switch outcome {
            case .results: "results"
            case .empty: "empty"
            case .noSearch: "noSearch"
            case .failed: "failed"
            }
            SourcePerfTrace.record("search.module", "module=\(module.module.id) outcome=\(label) items=\(entries.count)",
                                   since: started, thresholdMs: 0)
            // Prefixed: the same answers as the saved connections, whose ids are their own.
            return LibrarySearchAnswer(connectionID: "module:\(module.module.id)", name: module.displayName,
                                       outcome: outcome, entries: entries)
        }
        do {
            let page = try await LibrarySearch.within(timeout) { try await module.search(query) }
            guard let page else { return finish(.noSearch) }
            let items = page.entries.filter { if case .item = $0 { true } else { false } }
            return finish(items.isEmpty ? .empty : .results, items)
        } catch {
            let failure: SourceFailure
            do { failure = try SourceFailure.classify(error) } catch { return nil }
            // `ModuleProvider` logs its own request failures; a timeout is this search's.
            if failure.kind == .timeout {
                AppLogger.network("module search timed out", error: SourceFailure.loggable(error),
                                  context: ["module": module.module.id])
            }
            return finish(.failed(failure.localizedDescription))
        }
    }
}
