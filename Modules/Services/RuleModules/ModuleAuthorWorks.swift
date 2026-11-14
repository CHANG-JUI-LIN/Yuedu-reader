import Foundation

/// 作品詳情's 作者其他作品 from the modules (format 3.0.1): a module whose `search` says a keyword
/// may be an author's name (`searchesAuthors`) is searched for the work's first author, and the
/// results whose author is that author are that author's works.
///
/// Asked in the order 資料來源 lists the modules, each only while it is checked there and in use,
/// as reviews and the filler are: opening a work sends its author's name to the module's site.
/// One author is asked, the first the work names: each further one is a request more, per
/// module, at every opening.
@MainActor
enum ModuleAuthorWorks {
    /// 作品詳情 asks module after module: a site that hangs must not hold up the rest.
    nonisolated static let timeout: Duration = .seconds(20)

    typealias Search = @MainActor (RuleModule, String) async throws -> [CollectionEntry]

    static func load(authors: [String], limit: Int, library: RuleModuleLibrary = .shared,
                     order: MetadataFillOrderStore = .shared,
                     search: Search = { module, author in
                         let provider = ModuleProvider(module: module)
                         return try await LibrarySearch.within(ModuleAuthorWorks.timeout) {
                             try await provider.search(author)?.entries ?? []
                         }
                     }) async -> [CollectionEntry] {
        guard limit > 0, let author = WorkMatchKey.knownAuthors(authors).first else { return [] }
        await library.loadIfNeeded()
        let modules = Self.modules(in: library, order: order)
        guard !modules.isEmpty else { return [] }
        let started = SourcePerfTrace.now
        var works: [CollectionEntry] = []
        for module in modules where works.count < limit {
            guard !Task.isCancelled else { return [] }
            do {
                let found = try await search(module, author)
                works = AuthorWorks.appending(Self.byAuthor(found, author: author), to: works, excludingTitles: [], limit: limit)
            } catch is CancellationError {
                return []
            } catch {
                // The site's own failure: the next module is asked. Nothing is retried here.
                AppLogger.network("⟐ author works: module failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id])
            }
        }
        SourcePerfTrace.record("works.detail.authorWorks.modules", "modules=\(modules.count) works=\(works.count)",
                               since: started, thresholdMs: 0)
        return works
    }

    /// The modules that search by author and that 資料來源 has checked, in its order.
    static func modules(in library: RuleModuleLibrary, order: MetadataFillOrderStore) -> [RuleModule] {
        let filling = library.fillingModules
        return order.order(modules: filling.map(\.id)).entries.filter(\.isEnabled).compactMap { entry in
            guard case .module(let id) = entry.place else { return nil }
            return filling.first { $0.id == id && $0.search?.searchesAuthors == true }
        }
    }

    /// The results whose author is `author`: a search matches titles too.
    static func byAuthor(_ entries: [CollectionEntry], author: String) -> [CollectionEntry] {
        entries.filter { entry in
            guard case .item(let record, _, _) = entry else { return false }
            return WorkMatchKey.authorsCompatible([author], record.authors)
        }
    }
}
