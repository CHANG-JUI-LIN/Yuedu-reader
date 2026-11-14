import Combine
import Foundation

/// Discovery 7b-2 (maintainer, 2026-10-13): 作品詳情's 「尋找可用來源」. When the page opens
/// (maintainer, 2026-10-17: 「點進去自動尋找並列出可用來源」), and again when its row is tapped,
/// it searches the enabled sources for the work's title, as 換源 does (`SearchAggregator`), and
/// keeps the books found of the work — its title and a compatible author, one per source
/// (`WorkOffers.books`). The page lists them among its versions for as long as it is open;
/// nothing is stored.
@MainActor
final class WorkSourceFinder: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        /// `more`: the search paused itself (網路設定's 自動暫停) with sources left to ask.
        case done(more: Bool)
        /// No source answered: every one asked failed or timed out, which is not 「沒有找到」.
        case failed
        case noSources
    }

    @Published private(set) var state: State = .idle
    /// The work's books found so far, in the search's order.
    @Published private(set) var found: [WorkDetailRoute] = []
    /// The work in its other form, found by the same search: a book's audiobooks, an
    /// audiobook's books (maintainer, 2026-11-14: 「文字和有聲書互相顯示」, 作品詳情's 檢視有聲書).
    /// Never among `found`: another form is not a version of the work.
    @Published private(set) var otherForm: [WorkDetailRoute] = []
    /// Whether the search's books of the work's own kind are kept (`found`). A book source's
    /// page searches for the other form alone: its 換源 finds its versions itself.
    private(set) var keepsVersions = true

    private let aggregator = SearchAggregator()
    private var work: WorkDetailRoute?
    private var sources: [UUID: BookSource] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    /// Set once the page's own search started: the page coming back from one it pushed keeps
    /// what that search found instead of searching again.
    private var searchedOnOpen = false

    init() {
        // The aggregator publishes its results through `objectWillChange` alone; read them once
        // the change has landed.
        aggregator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    /// Searches `sources`' enabled ones for `work` — again from the start when it was searched.
    func find(_ work: WorkDetailRoute, sources: [BookSource], keepsVersions: Bool = true) {
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else {
            state = .noSources
            return
        }
        self.work = work
        self.keepsVersions = keepsVersions
        self.sources = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        found = []
        otherForm = []
        state = .searching
        aggregator.search(query: work.summary.title, sources: enabled, origin: .changeSource)
    }

    /// The page's own search, once: none when no source is enabled, so a reader without sources
    /// is not told to enable them on every page they open (the row's tap still says so).
    /// Leaving the page ends the search: the aggregator goes with this finder, and its fan-out
    /// stops at the next answer (`SearchAggregator.runSearch`).
    func findOnOpen(_ work: WorkDetailRoute, sources: [BookSource], keepsVersions: Bool = true) {
        guard !searchedOnOpen else { return }
        searchedOnOpen = true
        guard sources.contains(where: \.enabled) else { return }
        // A work with no other form (a comic, a video) has nothing to find for its source's page.
        guard keepsVersions || work.record.contentKind.otherForm != nil else { return }
        find(work, sources: sources, keepsVersions: keepsVersions)
    }

    /// Asks the sources a paused search had not reached.
    func resume() {
        guard state == .done(more: true) else { return }
        state = .searching
        aggregator.resume()
    }

    /// An inactive scene is never handed results (`SearchAggregator.setResultPresentationActive`).
    func setPresentationActive(_ active: Bool) {
        aggregator.setResultPresentationActive(active)
    }

    func cancel() {
        guard state == .searching else { return }
        aggregator.cancel()
        state = .idle
    }

    private func update() {
        guard state == .searching, let work else { return }
        // The results' books once, for both readings of them.
        let books = Self.books(in: aggregator.results)
        let versions = keepsVersions ? WorkOffers.books(of: work, in: books, sources: sources) : []
        if versions != found { found = versions }
        let others = work.record.contentKind.otherForm
            .map { WorkOffers.books(of: work, in: books, sources: sources, kind: $0) } ?? []
        if others != otherForm { otherForm = others }
        guard !aggregator.isSearching else { return }
        state = Self.outcome(paused: aggregator.isPaused, progress: aggregator.progress)
        AppLogger.info("works.findSources done state=\(state) found=\(found.count) otherForm=\(otherForm.count) "
                       + "completed=\(aggregator.progress.completed) failedAsEmpty=\(aggregator.progress.failedAsEmpty) "
                       + "failed=\(aggregator.progress.failed) timedOut=\(aggregator.progress.timedOut)")
    }

    /// The search's books of `work`: each origin as its source's own version, kept by
    /// `WorkOffers.books`' rule.
    /// `kind`: the work's own unless given; its other form's for 檢視有聲書.
    static func matches(of work: WorkDetailRoute, in results: [SearchBook], sources: [UUID: BookSource],
                        kind: ContentKind? = nil) -> [WorkDetailRoute] {
        WorkOffers.books(of: work, in: books(in: results), sources: sources, kind: kind)
    }

    /// Each origin of each result as its source's own book.
    private static func books(in results: [SearchBook]) -> [OnlineBook] {
        results.flatMap { result in result.origins.map { OnlineBook(detailOrigin: $0, in: result) } }
    }

    /// `listed` and, after them, each found book whose source none of them is from: a source
    /// offers one version, the one already listed — a shelf copy read from it, or the book its
    /// home's categories listed (7b-1).
    static func joined(_ listed: [WorkDetailRoute], found: [WorkDetailRoute]) -> [WorkDetailRoute] {
        guard !found.isEmpty else { return listed }
        var sources = Set(listed.map(\.record.key.instance).filter { $0.type == .bookSource })
        return listed + found.filter { sources.insert($0.record.key.instance).inserted }
    }

    /// The version 作品詳情 takes on as the search finds books (maintainer, 2026-10-24: 「有可用的
    /// 閱讀來源立馬就先換上」): the first readable one, while nothing listed reads and no version
    /// was picked. The page is then pinned to it: later answers reorder `found`, and each reorder
    /// would otherwise remount the source's page under the reader.
    static func shownOnFinding(listed: [WorkDetailRoute], found: [WorkDetailRoute],
                               chosen: SourceItemKey?) -> SourceItemKey? {
        guard chosen == nil, WorkVersions.primary(in: listed) == nil else { return nil }
        return WorkVersions.primary(in: joined(listed, found: found))?.nodeKey
    }

    /// How a search that stopped ended.
    static func outcome(paused: Bool, progress: SearchAggregator.SearchProgress) -> State {
        if paused { return .done(more: true) }
        let answered = progress.completed - progress.failedAsEmpty
        if answered == 0, progress.failed + progress.timedOut + progress.failedAsEmpty > 0 { return .failed }
        return .done(more: false)
    }
}
