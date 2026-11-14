import Combine
import Foundation

// Format 3.0.2 on 作品詳情: a module's book's own page (`detail`), its genre's books (`genre`,
// else `search`), and the works its site relates to it (`related`).

extension ModuleProvider {
    /// What the module's `detail` gives of its book at `url` (the record key's item): nil when
    /// the module has no `detail`. Throws what the request threw.
    func bookDetail(url: String) async throws -> RuleModuleBookDetail? {
        guard let detail = module.detail, !url.isEmpty else { return nil }
        do {
            return try await client.bookDetail(url: url, by: detail, in: module)
        } catch {
            let failure = try SourceFailure.classify(error)
            AppLogger.network("module book detail failed", error: SourceFailure.loggable(error), context: [
                "module": module.id, "failure": failure.kind.rawValue, "status": failure.status.map(String.init) ?? "",
            ])
            throw failure
        }
    }

    /// The module's books of `tag`, a page at a time: its `genre` list with `{{tag}}`, else what its
    /// `search` finds for the word (maintainer, 2026-11-14: a genre opens a page of its own, never
    /// the search screen). Nil when it has neither, or the word is too short for its search.
    func tagPage(_ tag: String, after cursor: CollectionCursor?) async throws -> CollectionPage? {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        if let genre = module.genre {
            let position = cursor.flatMap { Int($0.value) } ?? genre.firstPosition
            var values = genre.values([:], position: position, language: nil)
            values["tag"] = tag
            return try await page(of: genre, values: values, position: position)
        }
        guard let search = module.search, search.takes(keyword: tag) else { return nil }
        let position = cursor.flatMap { Int($0.value) } ?? search.firstPosition
        return try await page(of: search, values: search.values([:], position: position, keyword: tag, language: nil),
                              position: position)
    }

    /// Whether a genre of its books opens a page: it has a `genre` list or a `search`.
    var opensTags: Bool { module.genre != nil || module.search != nil }

    /// The works `related` reads for `record`, as entries a row shows.
    func relatedEntries(_ items: [RuleListItem]) -> [CollectionEntry] {
        guard let related = module.related else { return [] }
        let entry = RuleModule.Entry(id: nil, title: nil, request: related.request, list: related.list)
        let hasURLRule = !(related.list.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return items.compactMap {
            Self.entry($0, of: entry, instance: instance, hasURLRule: hasURLRule, hosts: RuleModuleHosts(module.hosts),
                       isReadable: module.reading != nil)
        }
    }

    private func page(of entry: RuleModule.Entry, values: [String: String], position: Int) async throws -> CollectionPage {
        let items: [RuleListItem]
        do {
            items = try await client.page(of: entry, in: module, values: values).items
        } catch {
            let failure = try SourceFailure.classify(error)
            AppLogger.network("module tag page failed", error: SourceFailure.loggable(error), context: [
                "module": module.id, "failure": failure.kind.rawValue, "status": failure.status.map(String.init) ?? "",
            ])
            throw failure
        }
        let hasURLRule = !(entry.list.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let hosts = RuleModuleHosts(module.hosts)
        let readable = module.reading != nil
        let entries = items.compactMap {
            Self.entry($0, of: entry, instance: instance, hasURLRule: hasURLRule, hosts: hosts, isReadable: readable)
        }
        return CollectionPage(entries: entries,
                              next: entry.position(after: position, itemCount: items.count).map { CollectionCursor(value: String($0)) })
    }
}

// MARK: - 相關作品

/// What one module's site relates to a work.
struct WorkRelatedSet: Hashable, Sendable {
    var moduleID: String
    var moduleTitle: String
    var entries: [CollectionEntry]
}

/// 作品詳情's 相關作品 (format 3.0.2): the first module, in 資料來源's order, whose site relates
/// works to the work. The module's records of the work are found as its reviews' are
/// (`ModuleReviewProvider.records`): the page's own record, the ISBN's, the same work by title.
/// Nothing is drawn when no module gives any: none is made up.
@MainActor
enum WorkRelated {
    typealias Ask = @MainActor (RuleModule, WorkReviewQuery) async throws -> WorkRelatedSet?

    static func load(_ query: WorkReviewQuery, library: RuleModuleLibrary = .shared,
                     order: MetadataFillOrderStore = .shared,
                     ask: Ask = { module, query in try await related(of: query, in: ModuleProvider(module: module)) }) async -> WorkRelatedSet? {
        guard !query.title.isEmpty else { return nil }
        await library.loadIfNeeded()
        let filling = library.fillingModules
        let modules = order.order(modules: filling.map(\.id)).entries.filter(\.isEnabled).compactMap { entry -> RuleModule? in
            guard case .module(let id) = entry.place else { return nil }
            return filling.first { $0.id == id && $0.related != nil }
        }
        let started = SourcePerfTrace.now
        for module in modules {
            guard !Task.isCancelled else { return nil }
            do {
                if let found = try await ask(module, query), !found.entries.isEmpty {
                    SourcePerfTrace.record("works.detail.related", "module=\(module.id) works=\(found.entries.count)",
                                           since: started, thresholdMs: 0)
                    return found
                }
            } catch is CancellationError {
                return nil
            } catch {
                // The site's own failure: the next module is asked, and the row stays out.
                AppLogger.network("⟐ work related: module failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id])
            }
        }
        return nil
    }

    /// One module's related works of the work: its first record that has every key the request
    /// names, the work's own entry left out.
    static func related(of query: WorkReviewQuery, in provider: ModuleProvider,
                        client: RuleModuleClient = RuleModuleClient()) async throws -> WorkRelatedSet? {
        let module = provider.module
        guard let block = module.related else { return nil }
        let records = try await ModuleReviewProvider(provider: provider, client: client).records(for: query)
        guard let record = records.first(where: { RuleModuleClient.canAskRelated(of: $0, by: block) }) else { return nil }
        let items = try await LibrarySearch.within(ModuleReviewProvider.timeout) {
            try await client.related(of: record, by: block, in: module)
        }
        let own = record.bookUrl
        let entries = provider.relatedEntries(items.filter { own.isEmpty || $0.bookUrl != own })
        return WorkRelatedSet(moduleID: module.id, moduleTitle: module.title, entries: entries)
    }
}

/// One 作品詳情's 相關作品, loaded once per work shown; nothing published until it is read.
@MainActor
final class WorkRelatedModel: ObservableObject {
    @Published private(set) var related: WorkRelatedSet?
    private var loaded: WorkReviewQuery?
    private let read: @MainActor (WorkReviewQuery) async -> WorkRelatedSet?

    init(read: @escaping @MainActor (WorkReviewQuery) async -> WorkRelatedSet? = { await WorkRelated.load($0) }) {
        self.read = read
    }

    func load(_ query: WorkReviewQuery?) async {
        guard query != loaded || query == nil else { return }
        guard let query else {
            loaded = nil
            related = nil
            return
        }
        related = nil
        let found = await read(query)
        guard !Task.isCancelled else { return }
        related = found
        loaded = query
    }
}

// MARK: - A module book's own page

/// What 作品詳情 adds to a module's book from the module's `detail` (format 3.0.2): asked once
/// per book shown, for the page's own record only; nothing published until it is read, and
/// nothing when the module has no `detail` or the request fails (logged).
@MainActor
final class ModuleBookDetailModel: ObservableObject {
    @Published private(set) var detail: RuleModuleBookDetail?
    private var loaded: SourceItemKey?
    private let read: @MainActor (SourceItemKey) async -> RuleModuleBookDetail?

    init(read: @escaping @MainActor (SourceItemKey) async -> RuleModuleBookDetail? = { await ModuleBookDetailModel.read($0) }) {
        self.read = read
    }

    func load(_ record: SourceItemKey?) async {
        guard record != loaded || record == nil else { return }
        guard let record else {
            loaded = nil
            detail = nil
            return
        }
        detail = nil
        let found = await read(record)
        guard !Task.isCancelled else { return }
        detail = found
        loaded = record
    }

    static func read(_ record: SourceItemKey, library: RuleModuleLibrary = .shared) async -> RuleModuleBookDetail? {
        // A record whose list has no url rule is keyed by its title and author: no page to ask.
        guard record.instance.type == .module, safeURL(string: record.item) != nil else { return nil }
        await library.loadIfNeeded()
        guard let module = library.module(id: record.instance.id)?.module, module.detail != nil else { return nil }
        do {
            return try await ModuleProvider(module: module).bookDetail(url: record.item)
        } catch {
            return nil
        }
    }
}
