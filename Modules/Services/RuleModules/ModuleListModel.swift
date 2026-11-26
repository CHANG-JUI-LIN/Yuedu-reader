import Combine
import Foundation

/// A module row's 查看全部 (Phase 6f-2): the list and the section's values, frozen when the page
/// is pushed, as the search routes are (`Technotes/iOS17SearchWatchdogPostmortem.md`).
struct ModuleListRoute: Hashable, Sendable {
    let moduleID: String
    let entryID: String
    let title: String
    let parameters: [String: String]
    /// A genre of a module's book (format 3.0.2): the module's `genre` list for the word, else
    /// what its `search` finds for it (`ModuleProvider.tagPage`); `entryID` is then unused.
    var tag: String? = nil
    /// What the reader searched for on the module's page in 資源庫: the module's `search`, page
    /// by page; `entryID` is then unused.
    var keyword: String? = nil

    /// A genre's page, from 作品詳情's genre link.
    static func tag(_ tag: String, moduleID: String) -> ModuleListRoute {
        ModuleListRoute(moduleID: moduleID, entryID: "", title: tag, parameters: [:], tag: tag)
    }

    /// The module's search for `keyword`, from its page's search field: titled with the keyword,
    /// as a genre's page is with the genre.
    static func search(_ keyword: String, moduleID: String) -> ModuleListRoute {
        ModuleListRoute(moduleID: moduleID, entryID: "", title: keyword, parameters: [:], keyword: keyword)
    }
}

/// The list page by page, each asked for by the reader (載入更多), through the module's
/// provider: the same requests, host gate and cache as its home row.
@MainActor
final class ModuleListModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
        /// The module was removed, or no longer has this list.
        case missing
    }

    @Published private(set) var state = State.loading
    @Published private(set) var entries: [CollectionEntry] = []
    @Published private(set) var isLoadingMore = false
    /// The next page failed; what was read stays.
    @Published private(set) var loadMoreError: String?
    @Published private var next: CollectionCursor?
    private(set) var hasStarted = false
    private var seen: Set<SourceItemKey> = []

    let route: ModuleListRoute
    private let library: RuleModuleLibrary
    private let client: RuleModuleClient

    init(route: ModuleListRoute, library: RuleModuleLibrary? = nil, client: RuleModuleClient = RuleModuleClient()) {
        self.route = route
        self.library = library ?? .shared
        self.client = client
    }

    var canLoadMore: Bool { next != nil }

    /// The installed module's provider, while it still has the list (or, for a genre, a list
    /// or search that opens one; for a search, its search).
    private func provider() -> ModuleProvider? {
        guard let module = library.module(id: route.moduleID)?.module else { return nil }
        let provider = ModuleProvider(module: module, client: client)
        if route.keyword != nil { return module.search == nil ? nil : provider }
        if route.tag != nil { return provider.opensTags ? provider : nil }
        return provider.entry(route.entryID) == nil ? nil : provider
    }

    /// The page after `cursor`: the list's, the search's or the genre's. A keyword or genre too
    /// short for the module's search has no page: nothing is listed.
    private func page(from provider: ModuleProvider, after cursor: CollectionCursor?) async throws -> CollectionPage {
        if let keyword = route.keyword {
            return try await provider.search(keyword, after: cursor) ?? CollectionPage(entries: [], next: nil)
        }
        guard let tag = route.tag else {
            return try await provider.page(ofList: route.entryID, parameters: route.parameters, after: cursor)
        }
        return try await provider.tagPage(tag, after: cursor) ?? CollectionPage(entries: [], next: nil)
    }

    /// The first page, again from the start.
    func load() async {
        hasStarted = true
        await library.loadIfNeeded()
        guard let provider = provider() else {
            state = .missing
            return
        }
        state = .loading
        entries = []
        seen = []
        next = nil
        loadMoreError = nil
        do {
            append(try await page(from: provider, after: nil))
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let cursor = next, !isLoadingMore else { return }
        guard let provider = provider() else {
            state = .missing
            return
        }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            append(try await page(from: provider, after: cursor))
        } catch is CancellationError {
            return
        } catch {
            loadMoreError = error.localizedDescription
        }
    }

    private func append(_ page: CollectionPage) {
        let fresh = page.entries.filter { entry in
            guard case .item(let record, _, _) = entry else { return true }
            return seen.insert(record.key).inserted
        }
        entries += fresh
        // A site that ignores the page parameter answers every page with the same books. A page
        // that brings no new book ends the list, rather than offering 載入更多 for ever and
        // drawing a card twice. It stays as long as module sites can ignore their paging.
        next = fresh.isEmpty ? nil : page.next
    }
}
