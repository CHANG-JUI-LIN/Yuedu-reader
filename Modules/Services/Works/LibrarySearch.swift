import Foundation

/// A part of 搜索 that answers on submit, one answer per place it asks: the saved libraries
/// (4b-2), Open Library (4b-3). `LibrarySearchModel` draws either.
@MainActor
protocol SearchAnswering: AnyObject {
    /// Whether a search would ask anyone.
    var isAvailable: Bool { get }
    /// Asks every place; `onAnswer` gets each answer as it arrives. Returns when all have
    /// answered or the calling task is cancelled.
    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async
}

/// One place's answer to a search: a saved OPDS or Calibre connection (unified search 4b-2),
/// or Open Library (4b-3).
struct LibrarySearchAnswer: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case results
        /// The library answered and has no such book.
        case empty
        /// The library advertises no search; it was not asked.
        case noSearch
        /// The library could not answer: the error's own text, shown on its status line.
        case failed(String)
    }

    let connectionID: String
    let name: String
    let outcome: Outcome
    /// Its items, as `CollectionEntry.item`s.
    let entries: [CollectionEntry]

    var id: String { connectionID }
}

/// Searches every saved OPDS and Calibre connection, and Project Gutenberg where the public
/// libraries are offered (search 9b), at once, each against its own timeout (unified search
/// 4b-2, design §12.2): one library failing marks only its own answer. Asked on submit, never
/// as you type, which is also Gutenberg's terms (`PublicLibraries.md`).
///
/// A catalog searches what its root feed advertises (OpenSearch). The root is fetched once
/// per connection for the life of this object, so a second search sends one request per
/// library, as `OPDSBrowseModel` does after its first load. Gutenberg's search address is
/// known without its root, so it is asked for its first page alone.
@MainActor
final class LibrarySearch: SearchAnswering {
    static let timeout: Duration = .seconds(20)

    private let providers: @MainActor () -> [any OPDSFeedProviding]
    private let timeout: Duration
    /// What each connection's root advertised; nil when it advertises no search.
    private var advertised: [String: OPDSSearch?] = [:]

    init(providers: (@MainActor () -> [any OPDSFeedProviding])? = nil, timeout: Duration = LibrarySearch.timeout) {
        self.providers = providers ?? {
            Self.libraries(catalogs: OPDSCatalogStore.shared.catalogs, gutenberg: SourceProviderRegistry.shared.gutenberg,
                           shown: AggregationSettingsStore.shared.isShownInSearch) {
                SourceProviderRegistry.shared.opdsProvider(catalogID: $0.id)
            }
        }
        self.timeout = timeout
    }

    /// The libraries a search asks: the saved OPDS and Calibre connections (never WebDAV, which
    /// has no search), then Gutenberg where it is offered; each only while 聚合設定's 搜尋來源
    /// keeps it checked (`shown`, search 9d).
    static func libraries(catalogs: [OPDSCatalog], gutenberg: GutenbergProvider,
                          shown: (SourceInstanceKey) -> Bool = { _ in true },
                          provider: (OPDSCatalog) -> (any OPDSFeedProviding)?) -> [any OPDSFeedProviding] {
        let saved = catalogs.compactMap { connection -> (any OPDSFeedProviding)? in
            guard connection.kind != .webDAV, connection.id != PublicLibraryID.gutenberg.rawValue else { return nil }
            return provider(connection)
        }
        return (saved + (gutenberg.availability == .available ? [gutenberg] : [])).filter { shown($0.instance) }
    }

    /// Whether any library would be asked.
    var isAvailable: Bool { !providers().isEmpty }

    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraries = providers()
        guard !query.isEmpty, !libraries.isEmpty else { return }
        let timeout = timeout
        await withTaskGroup(of: LibrarySearchAnswer.self) { group in
            for library in libraries {
                group.addTask { await self.answer(library, query: query, timeout: timeout) }
            }
            for await answer in group {
                guard !Task.isCancelled else { return }
                onAnswer(answer)
            }
        }
    }

    private func answer(_ library: any OPDSFeedProviding, query: String, timeout: Duration) async -> LibrarySearchAnswer {
        let id = library.instance.id
        let name = library.displayName
        let started = SourcePerfTrace.now
        func finish(_ outcome: LibrarySearchAnswer.Outcome, _ entries: [CollectionEntry] = []) -> LibrarySearchAnswer {
            let label: String = switch outcome {
            case .results: "results"
            case .empty: "empty"
            case .noSearch: "noSearch"
            case .failed: "failed"
            }
            SourcePerfTrace.record("search.library", "kind=\(library.instance.type.rawValue) outcome=\(label) items=\(entries.count)",
                                   since: started, thresholdMs: 0)
            return LibrarySearchAnswer(connectionID: id, name: name, outcome: outcome, entries: entries)
        }
        do {
            let page = try await Self.within(timeout) { [self] in
                try await self.page(of: library, query: query)
            }
            guard let page else { return finish(.noSearch) }
            let items = page.entries.filter { if case .item = $0 { true } else { false } }
            return finish(items.isEmpty ? .empty : .results, items)
        } catch {
            let failure: SourceFailure
            do { failure = try SourceFailure.classify(error) } catch {
                // Cancelled: the search was replaced or cleared, and nobody reads this answer.
                return finish(.failed(error.localizedDescription))
            }
            AppLogger.network("library search failed", error: SourceFailure.loggable(error),
                              context: ["kind": library.instance.type.rawValue, "failure": failure.kind.rawValue])
            return finish(.failed(failure.localizedDescription))
        }
    }

    /// The search's first page; nil when the library advertises no search.
    private func page(of library: any OPDSFeedProviding, query: String) async throws -> CollectionPage? {
        let id = library.instance.id
        guard let url = try await searchURL(of: library, query: query) else { return nil }
        let feed = try await library.feed(url, isSearch: true)
        return await OPDSProvider.page(from: feed, connectionID: id, record: library.makeRecord, opening: library.makeOpening)
    }

    /// Where `query` is searched. A library that needs nothing from its root (Gutenberg) says so
    /// without it; the others search what their root advertised.
    private func searchURL(of library: any OPDSFeedProviding, query: String) async throws -> URL? {
        if let direct = try await library.searchURL(query: query, search: nil) { return direct }
        let id = library.instance.id
        let search: OPDSSearch?
        if let known = advertised[id] {
            search = known
        } else {
            guard let root = library.rootURL else { throw SourceFailure(kind: .invalidAddress, underlying: OPDSError.invalidURL) }
            search = try await library.feed(root, isSearch: false).search
            advertised[id] = search
        }
        guard let search else { return nil }
        return try await library.searchURL(query: query, search: search)
    }

    /// `operation`, or a `SourceFailure` of kind `.timeout` when it takes longer than `limit`.
    static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SourceFailure(kind: .timeout, underlying: URLError(.timedOut))
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
