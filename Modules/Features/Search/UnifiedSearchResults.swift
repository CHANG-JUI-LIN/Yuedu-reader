import SwiftUI

// Unified search 4c-3: the 搜索 tab's root as one list of works. Every part's finds (the
// shelf, the saved libraries, 青空文庫, the book sources, Open Library) are merged by
// `SearchWorkResolver`; each row is a work, opening 作品詳情 with all its members as versions.

/// One part's find, frozen when found: what its row draws and what opening it needs.
enum UnifiedSearchPayload {
    case shelf(ShelfSearchMatch)
    /// A saved library's book, or Open Library's (`ItemOpening.bibliographic`).
    case library(LibrarySearchMatch)
    /// A 青空文庫 work.
    case publicLibrary(WorkDetailRoute)
    /// A row of the book sources' results: its publication snapshot.
    case bookSource(SearchBook)

    /// What the resolver compares it by.
    /// - Parameter sourceURL: a source's `bookSourceUrl` by id.
    @MainActor
    func candidate(sourceURL: (UUID) -> String?) -> SearchCandidate {
        switch self {
        case .shelf(let match):
            SearchCandidate(route: match.route, kind: .shelf, identifiers: match.identifiers, language: match.language)
        case .library(let match):
            SearchCandidate(route: match.route, kind: match.route.opening == .bibliographic ? .bibliographic : .library)
        case .publicLibrary(let route):
            SearchCandidate(route: route, kind: .publicLibrary)
        case .bookSource(let row):
            SearchCandidate(bookSourceRow: row, sourceURL: sourceURL)
        }
    }

    var title: String {
        switch self {
        case .shelf(let match): match.book.title
        case .library(let match): match.card.title
        case .publicLibrary(let route): route.summary.title
        case .bookSource(let row): row.displayName
        }
    }

    var author: String {
        switch self {
        case .shelf(let match): match.book.author
        case .library(let match): match.card.author
        case .publicLibrary(let route): route.summary.authors.joined(separator: "、")
        case .bookSource(let row): row.author
        }
    }

    /// The version it is in 作品詳情, with a book-source row's result for its page's 換源; nil
    /// for a row whose source is gone (logged by `WorkDetailRoute(searchResult:)`).
    @MainActor
    fileprivate func version(sources: BookSourceStore) -> (route: WorkDetailRoute, result: SearchBook?)? {
        switch self {
        case .shelf(let match): (match.route, nil)
        case .library(let match): (match.route, nil)
        case .publicLibrary(let route): (route, nil)
        case .bookSource(let row): WorkDetailRoute(searchResult: row, sources: sources).map { ($0, row) }
        }
    }
}

/// What a row opens, frozen at the tap (postmortem guardrail 1): the member that leads, then
/// the others.
struct UnifiedSearchSelection {
    let lead: UnifiedSearchPayload
    let others: [UnifiedSearchPayload]

    /// 作品詳情's route, its other versions, and each book-source version's result. A lead whose
    /// source is gone gives way to the next member; nil when none is left.
    @MainActor
    func destination(sources: BookSourceStore = .shared) -> UnifiedSearchDestinationParts? {
        let versions = ([lead] + others).compactMap { $0.version(sources: sources) }
        guard let first = versions.first else { return nil }
        var results: [SourceItemKey: SearchBook] = [:]
        for version in versions {
            if let result = version.result { results[version.route.nodeKey] = result }
        }
        return UnifiedSearchDestinationParts(route: first.route, versions: versions.dropFirst().map(\.route),
                                             searchResults: results)
    }
}

struct UnifiedSearchDestinationParts {
    let route: WorkDetailRoute
    let versions: [WorkDetailRoute]
    let searchResults: [SourceItemKey: SearchBook]
}

/// The route a row pushes: its selection, equal by the row's id.
typealias UnifiedSearchResultRoute = SearchResultRoute<UnifiedSearchSelection>

/// One row of the list: a work, drawn from its lead.
struct UnifiedSearchRow: Identifiable {
    /// Kept while the work stays on screen for the same query, so the lists diff in place.
    let id: UUID
    let work: UnifiedSearchResult
    let selection: UnifiedSearchSelection
    let content: SearchBookListRowContent

    var lead: UnifiedSearchPayload { selection.lead }
    var members: [UnifiedSearchPayload] { [selection.lead] + selection.others }
}

/// Each part's finds at one moment.
struct UnifiedSearchParts {
    var shelf: [ShelfSearchMatch] = []
    var libraries: [LibrarySearchMatch] = []
    var publicLibrary: [WorkDetailRoute] = []
    var bibliographic: [LibrarySearchMatch] = []
    var sources: [SearchBook] = []
    /// 青空文庫's whole list when more matched than the list takes.
    var publicLibraryOverflow: PublicLibraryRoute? = nil

    init(shelf: [ShelfSearchMatch] = [], libraries: [LibrarySearchMatch] = [], publicLibrary: [WorkDetailRoute] = [],
         bibliographic: [LibrarySearchMatch] = [], sources: [SearchBook] = []) {
        self.shelf = shelf
        self.libraries = libraries
        self.publicLibrary = publicLibrary
        self.bibliographic = bibliographic
        self.sources = sources
    }

    /// In the order the parts are found in, the resolver's last tie-break.
    var payloads: [UnifiedSearchPayload] {
        shelf.map(UnifiedSearchPayload.shelf) + libraries.map(UnifiedSearchPayload.library)
            + publicLibrary.map(UnifiedSearchPayload.publicLibrary) + sources.map(UnifiedSearchPayload.bookSource)
            + bibliographic.map(UnifiedSearchPayload.library)
    }
}

/// 搜索's one list. Owned by the search page and read only by the views that draw it
/// (postmortem guardrail 13). Candidates are made on the main actor, merged off it.
@Observable
@MainActor
final class UnifiedSearchModel {
    private(set) var rows: [UnifiedSearchRow] = []
    private(set) var publicLibraryOverflow: PublicLibraryRoute?
    /// A merge is running for finds not yet on screen.
    private(set) var isResolving = false
    @ObservationIgnored private let sourceURL: (UUID) -> String?
    /// Each member's row id for `rowIDsQuery`, so a row keeps its id as its work grows.
    @ObservationIgnored private var rowIDs: [SearchCandidate.ID: UUID] = [:]
    @ObservationIgnored private var rowIDsQuery: String?

    init(sourceURL: ((UUID) -> String?)? = nil) {
        self.sourceURL = sourceURL ?? { BookSourceStore.shared.source(id: $0)?.bookSourceUrl }
    }

    /// Merges `parts` into the rows. A newer update cancels this one's task (`task(id:)`); a
    /// cancelled merge publishes nothing.
    func update(_ parts: UnifiedSearchParts, query: String) async {
        let payloads = parts.payloads
        guard !payloads.isEmpty else {
            publish([], overflow: parts.publicLibraryOverflow, query: query)
            return
        }
        let started = SourcePerfTrace.now
        var urls: [UUID: String?] = [:]
        let candidates = payloads.map { payload in
            payload.candidate { id in
                if let known = urls[id] { return known }
                let url = sourceURL(id)
                urls[id] = url
                return url
            }
        }
        SourcePerfTrace.record("search.unified.candidates", "candidates=\(candidates.count)", since: started, thresholdMs: 0)
        isResolving = true
        let works = await Task.detached(priority: .userInitiated) {
            SearchWorkResolver.resolve(candidates, query: query)
        }.value
        guard !Task.isCancelled else { return }
        let byID = Dictionary(zip(candidates.map(\.id), payloads), uniquingKeysWith: { first, _ in first })
        publish(works.compactMap { work in
            let members = work.members.compactMap { byID[$0.id] }
            guard let lead = members.first else { return nil }
            return (work, UnifiedSearchSelection(lead: lead, others: Array(members.dropFirst())))
        }, overflow: parts.publicLibraryOverflow, query: query)
        SourcePerfTrace.record("search.unified.resolve", "candidates=\(candidates.count) works=\(works.count)",
                               since: started, thresholdMs: 0)
    }

    func clear() {
        isResolving = false
        rowIDs = [:]
        rowIDsQuery = nil
        if !rows.isEmpty { rows = [] }
        if publicLibraryOverflow != nil { publicLibraryOverflow = nil }
    }

    private func publish(_ works: [(UnifiedSearchResult, UnifiedSearchSelection)], overflow: PublicLibraryRoute?,
                         query: String) {
        if rowIDsQuery != query {
            rowIDs = [:]
            rowIDsQuery = query
        }
        var used = Set<UUID>()
        rows = works.map { work, selection in
            let memberIDs = work.members.map(\.id)
            let id = memberIDs.lazy.compactMap { self.rowIDs[$0] }.first { !used.contains($0) } ?? UUID()
            used.insert(id)
            for member in memberIDs { rowIDs[member] = id }
            return UnifiedSearchRow(id: id, work: work, selection: selection,
                                    content: SearchBookListRowContent(work: work, lead: selection.lead))
        }
        publicLibraryOverflow = overflow
        isResolving = false
    }
}

extension SearchBookListRowContent {
    /// A work of 搜索's one list: its lead's title and author, then whether it is on the shelf,
    /// readable or data only, and how many places it can be read from — 「在書架上 · 3 源」.
    /// VoiceOver hears the same parts as pauses (§16 item 7).
    init(work: UnifiedSearchResult, lead: UnifiedSearchPayload) {
        let availability = switch work.availability {
        case .onShelf: localized("在書架上")
        case .readable: localized("可閱讀")
        case .dataOnly: localized("只有資料")
        }
        let parts = [availability] + (work.sourceCount > 0 ? [String(format: localized("%d 源"), work.sourceCount)] : [])
        self.init(title: lead.title, titleTag: work.lead.contentKind == .audio ? localized("有聲書") : nil,
                  author: lead.author, detail: parts.joined(separator: " · "), spokenDetail: parts.joined(separator: "，"))
    }
}

/// What the list says besides its works: above them while there is none (searching, paused,
/// or the one empty state once every part has answered), and under them each place that
/// could not answer, after 「搜索中…」 while a library is still asked.
struct UnifiedSearchStatus: Equatable {
    var leading: String?
    var trailing: [String] = []

    init() {}

    /// - Parameters:
    ///   - isSearching: the sources are still asked, or the finds are being merged.
    ///   - othersSearching: a saved library or Open Library is still asked.
    ///   - submittedQuery: the query submitted, when it is still the one in the field.
    init(hasRows: Bool, isSearching: Bool, isPaused: Bool, othersSearching: Bool, submittedQuery: String?,
         failures: [LibrarySearchFailure]) {
        if !hasRows {
            if isSearching || othersSearching {
                leading = localized("搜索中…")
            } else if isPaused {
                leading = localized("已暫停")
            } else if let submittedQuery {
                leading = String(format: localized("沒有找到「%@」"), submittedQuery)
            }
        }
        trailing = (hasRows && othersSearching ? [localized("搜索中…")] : []) + failures.map(\.line)
    }
}

/// Feeds the list: reads every part and merges them again whenever one changes. A view of
/// its own, so the search page never reads the parts' changing finds (guardrail 13).
struct UnifiedSearchFeed: View {
    /// Empty when the list is not shown.
    let query: String
    let shelf: ShelfSearchModel
    let libraries: LibrarySearchModel
    let bibliographic: LibrarySearchModel
    @ObservedObject var aggregator: SearchAggregator
    let offersPublicLibraries: Bool
    let model: UnifiedSearchModel
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    /// 青空文庫's matches the list takes; the rest are behind 顯示全部.
    static let publicLibraryLimit = 50

    /// What the list is made from, compared cheaply: a source row that gained origins keeps its
    /// id, so the sources' part counts its publications.
    private struct Trigger: Equatable {
        let query: String
        let shelf: [ShelfSearchMatch]
        let libraries: [UUID]
        let bibliographic: [UUID]
        let publicLibrary: Bool
        let sources: Int
    }

    private var trigger: Trigger {
        Trigger(query: query, shelf: shelf.matches, libraries: libraries.matches.map(\.id),
                bibliographic: bibliographic.matches.map(\.id),
                publicLibrary: offersPublicLibraries && aozora.catalog != nil, sources: aggregator.publicationRevision)
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: trigger) {
                guard !query.isEmpty else {
                    model.clear()
                    return
                }
                var parts = UnifiedSearchParts(shelf: shelf.matches, libraries: libraries.matches,
                                               bibliographic: bibliographic.matches, sources: aggregator.results)
                if offersPublicLibraries, let index = aozora.catalog {
                    let matches = index.search(query)
                    parts.publicLibrary = matches.prefix(Self.publicLibraryLimit)
                        .compactMap { WorkDetailRoute(.aozora($0, index: index)) }
                    if matches.count > Self.publicLibraryLimit {
                        parts.publicLibraryOverflow = .aozoraWorks(title: query, works: matches, index: index)
                    }
                }
                await model.update(parts, query: query)
            }
    }
}

/// A work's cover in the list, drawn as its lead's part draws it.
struct UnifiedSearchCover: View {
    let payload: UnifiedSearchPayload
    @Environment(\.colorScheme) private var colorScheme

    private var size: CGSize { CGSize(width: DSLayout.searchListCoverWidth, height: DSLayout.searchListCoverHeight) }

    var body: some View {
        switch payload {
        case .shelf(let match):
            BookshelfCoverStyle.artwork(for: match.book, colorScheme: colorScheme, displaySize: size)
        case .library(let match):
            HomeCoverArtwork(cover: match.card.cover, title: match.card.title, author: match.card.author, size: size)
        case .publicLibrary(let route):
            BookCoverImage(coverURL: "", title: route.summary.title, author: payload.author)
        case .bookSource(let row):
            BookCoverImage(coverURL: row.coverUrl, title: row.displayName, author: row.author)
        }
    }
}

/// The list's rows on iOS 18 and later, inside the page's `List`: the leading status line,
/// the works, 載入更多, 青空文庫's full list, Gutenberg's search, then the trailing lines.
@available(iOS 18.0, *)
struct UnifiedSearchRows: View {
    let model: UnifiedSearchModel
    let status: UnifiedSearchStatus
    let canLoadMore: Bool
    let loadMore: () -> Void
    /// The query Gutenberg is offered for; nil where the public libraries are not.
    let gutenbergQuery: String?
    let submitGutenberg: () -> Void

    var body: some View {
        let rows = model.rows
        if let leading = status.leading {
            statusLine(leading, anchors: true)
        }
        ForEach(rows) { row in
            NavigationLink(value: UnifiedSearchResultRoute(id: row.id, snapshot: row.selection)) {
                SearchBookListRow(content: row.content) { UnifiedSearchCover(payload: row.lead) }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: DSLayout.searchListHorizontalInset,
                                      bottom: 0, trailing: DSLayout.searchListHorizontalInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(row.id == rows.first?.id ? .hidden : .automatic, edges: .top)
            .background {
                if status.leading == nil, row.id == rows.first?.id { Color.clear.rootTabTitleScrollAnchor() }
            }
        }
        if let overflow = model.publicLibraryOverflow {
            NavigationLink(localized("顯示全部"), value: overflow)
                .listRowBackground(Color.clear)
        }
        if canLoadMore {
            Button(action: loadMore) {
                Label(localized("載入更多"), systemImage: "arrow.down.circle")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.accent)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        if let gutenbergQuery {
            Button(action: submitGutenberg) {
                Label(String(format: localized("在 Project Gutenberg 搜尋「%@」"), gutenbergQuery), systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("publicLibrary.searchGutenberg")
            .listRowBackground(Color.clear)
            .background {
                if status.leading == nil, rows.isEmpty { Color.clear.rootTabTitleScrollAnchor() }
            }
        }
        ForEach(Array(status.trailing.enumerated()), id: \.offset) { offset, line in
            statusLine(line, anchors: status.leading == nil && rows.isEmpty && gutenbergQuery == nil && offset == 0)
        }
    }

    private func statusLine(_ text: String, anchors: Bool) -> some View {
        Text(text)
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textSecondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .top)
            .background { if anchors { Color.clear.rootTabTitleScrollAnchor() } }
    }
}

#if DEBUG
@available(iOS 18.0, *)
#Preview("搜索：一張作品清單") {
    let store = BookStore()
    let model = UnifiedSearchModel(sourceURL: { _ in nil })
    let rows = UnifiedSearchParts(sources: [
        SearchBook(name: "三體", author: "劉慈欣"),
        SearchBook(name: "三體II：黑暗森林", author: "劉慈欣"),
    ])
    let failure = LibrarySearchFailure(id: "calibre", name: "Calibre", reason: "無法連線到伺服器")
    return NavigationStack {
        List {
            UnifiedSearchRows(model: model,
                              status: UnifiedSearchStatus(hasRows: true, isSearching: false, isPaused: false,
                                                          othersSearching: true, submittedQuery: "三體", failures: [failure]),
                              canLoadMore: true, loadMore: {}, gutenbergQuery: "三體", submitGutenberg: {})
        }
        .listStyle(.plain)
        .task { await model.update(rows, query: "三體") }
    }
    .environmentObject(store)
}
#endif
