import Combine
import Foundation

/// A module row's 查看全部 (Phase 6f-2): the list and the section's values, frozen when the page
/// is pushed, as the search routes are (`Technotes/iOS17SearchWatchdogPostmortem.md`).
struct ModuleListRoute: Hashable, Sendable {
    let moduleID: String
    let entryID: String
    let title: String
    let parameters: [String: String]
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

    /// The installed module's provider, while it still has the list.
    private func provider() -> ModuleProvider? {
        guard let module = library.module(id: route.moduleID)?.module else { return nil }
        let provider = ModuleProvider(module: module, client: client)
        return provider.entry(route.entryID) == nil ? nil : provider
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
            append(try await provider.page(ofList: route.entryID, parameters: route.parameters, after: nil))
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
            append(try await provider.page(ofList: route.entryID, parameters: route.parameters, after: cursor))
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
