import Foundation
import Observation

/// 換源's 書庫與模組 (maintainer 2026-10-26: 「所有來源配置、WebDAV、Calibre、模組⋯都是相同地位」):
/// where else the work being read can be read from. First the versions 作品詳情 lists for it
/// (`ShelfProvider.versions`: the work index's library files, 青空文庫, Gutenberg), then what the
/// saved libraries and the installed modules find under its title (`LibrarySearch`,
/// `ModuleSearch`), the same work's only (`WorkOffers.found`).
///
/// Left to the sheet's other lists: a 來源配置's books (其他來源配置), and the copies already
/// read — the book itself and the versions kept beside it (已知的閱讀來源).
@Observable
@MainActor
final class ReaderVersionFinder {
    struct Found: Identifiable {
        let route: WorkDetailRoute
        /// The library's or module's name, 青空文庫 or Project Gutenberg.
        let place: String
        var id: SourceItemKey { route.nodeKey }
    }

    private(set) var found: [Found] = []
    private(set) var isSearching = false
    @ObservationIgnored private let makeSearches: @MainActor () -> [any SearchAnswering]
    @ObservationIgnored private var searches: [any SearchAnswering] = []
    @ObservationIgnored private var running: Task<Void, Never>?

    init(searches: @escaping @MainActor () -> [any SearchAnswering] = { [LibrarySearch(), ModuleSearch()] }) {
        makeSearches = searches
    }

    /// Finds the versions of shelf book `bookID`'s work, replacing what an earlier search found.
    func start(for bookID: UUID, store: BookStore) {
        stop()
        if !found.isEmpty { found = [] }
        guard let book = store.readingBook(id: bookID),
              let work = ShelfProvider(store: store).items([book]).first.flatMap(WorkDetailRoute.init) else { return }
        searches = makeSearches().filter(\.isAvailable)
        isSearching = true
        running = Task { [weak self] in
            let started = SourcePerfTrace.now
            let known = await ShelfProvider(store: store).versions(of: work, aozora: AozoraCatalogStore.shared.catalog)
            guard let self, !Task.isCancelled else { return }
            self.add(known, of: bookID, store: store)
            await withTaskGroup(of: Void.self) { group in
                for index in self.searches.indices {
                    let operation: @MainActor @Sendable () async -> Void = {
                        await self.searches[index].search(work.summary.title) { answer in
                            guard !Task.isCancelled, case .results = answer.outcome else { return }
                            self.add(WorkOffers.found(of: work, in: answer.entries.compactMap(WorkDetailRoute.init)),
                                     of: bookID, store: store)
                        }
                    }
                    group.addTask(operation: operation)
                }
            }
            guard !Task.isCancelled else { return }
            self.isSearching = false
            SourcePerfTrace.record("changeSource.versions", "known=\(known.count) found=\(self.found.count)",
                                   since: started, thresholdMs: 0)
        }
    }

    /// Stops asking; what was found stays listed (a switch that fails leaves the list to pick
    /// another from).
    func stop() {
        running?.cancel()
        running = nil
        isSearching = false
    }

    #if DEBUG
    func waitForTesting() async { await running?.value }
    #endif

    /// The readable versions among `routes` not listed yet, and not a copy already read here.
    private func add(_ routes: [WorkDetailRoute], of bookID: UUID, store: BookStore) {
        let read = Set([bookID] + store.keptVersions(of: bookID).map(\.id))
        let lookup = store.copyLookup()
        var listed = Set(found.map(\.route.record.key))
        for route in routes where VersionReadingCopy.isReadable(route) && listed.insert(route.record.key).inserted {
            guard !lookup.copies(for: route.record.key).contains(where: { read.contains($0.id) }),
                  let place = BookOriginName.of(route) else { continue }
            found.append(Found(route: route, place: place))
        }
    }
}
