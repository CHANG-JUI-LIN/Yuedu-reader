import SwiftUI

/// One book a saved library found for 搜索 (unified search 4b-2), as the home draws one of
/// its items, with the 作品詳情 route frozen when it was found.
struct LibrarySearchMatch: Identifiable {
    /// Made once, when the answer arrives, so the iOS 17 table can diff its rows.
    let id = UUID()
    let card: HomeCardContent
    let route: WorkDetailRoute
    let connectionID: String
    /// The library's name: the row's detail line.
    let libraryName: String

    var rowContent: SearchBookListRowContent {
        SearchBookListRowContent(title: card.title, titleTag: nil, author: card.author, detail: libraryName)
    }
}

/// A library that could not answer, with why: its status line (design §16 item 4).
struct LibrarySearchFailure: Identifiable, Equatable {
    let id: String
    let name: String
    let reason: String

    /// 「Calibre：無法搜尋（原因）」.
    var line: String {
        String(format: localized("%@：無法搜尋（%@）"), name, reason)
    }
}

/// 搜索's 我的書庫 section: every saved OPDS and Calibre library asked on submit, each
/// answering on its own (unified search 4b-2). Owned by the search page and read only by the
/// views that draw it.
@Observable
@MainActor
final class LibrarySearchModel {
    private(set) var matches: [LibrarySearchMatch] = []
    private(set) var failures: [LibrarySearchFailure] = []
    private(set) var isSearching = false
    @ObservationIgnored private let search: LibrarySearch
    @ObservationIgnored private var running: Task<Void, Never>?

    init(search: LibrarySearch? = nil) {
        self.search = search ?? LibrarySearch()
    }

    var hasLibraries: Bool { search.hasLibraries }

    func start(_ query: String, store: BookStore) {
        clear()
        guard search.hasLibraries else { return }
        isSearching = true
        running = Task { [weak self] in
            guard let self else { return }
            await self.search.search(query) { answer in
                guard !Task.isCancelled else { return }
                self.add(answer, store: store)
            }
            guard !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    func clear() {
        running?.cancel()
        running = nil
        isSearching = false
        if !matches.isEmpty { matches = [] }
        if !failures.isEmpty { failures = [] }
    }

    #if DEBUG
    func waitForTesting() async { await running?.value }

    /// An answer as if a library had sent it, for previews.
    func receiveForPreview(_ answer: LibrarySearchAnswer, store: BookStore) { add(answer, store: store) }
    #endif

    private func add(_ answer: LibrarySearchAnswer, store: BookStore) {
        switch answer.outcome {
        case .results:
            let lookup = store.copyLookup()
            matches += answer.entries.compactMap { entry in
                guard let card = HomeCardContent(entry, status: lookup.status(for:), shelfBooks: [:]),
                      let route = card.route else { return nil }
                return LibrarySearchMatch(card: card, route: route, connectionID: answer.connectionID,
                                          libraryName: answer.name)
            }
        case .failed(let reason):
            failures.append(LibrarySearchFailure(id: answer.connectionID, name: answer.name, reason: reason))
        case .empty, .noSearch:
            break
        }
    }
}

/// The 我的書庫 section of the 搜索 tab's results on iOS 18 and later.
struct LibrarySearchSection: View {
    let model: LibrarySearchModel
    let anchorsTitle: Bool

    var body: some View {
        if model.isSearching || !model.matches.isEmpty || !model.failures.isEmpty {
            Section(localized("我的書庫")) {
                ForEach(model.matches) { match in
                    NavigationLink(value: match.route) {
                        SearchBookListRow(content: match.rowContent) {
                            HomeCoverArtwork(cover: match.card.cover, title: match.card.title, author: match.card.author,
                                             size: CGSize(width: DSLayout.searchListCoverWidth, height: DSLayout.searchListCoverHeight))
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: DSLayout.searchListHorizontalInset,
                                              bottom: 0, trailing: DSLayout.searchListHorizontalInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(match.id == model.matches.first?.id ? .hidden : .automatic, edges: .top)
                    .background {
                        if anchorsTitle, match.id == model.matches.first?.id {
                            Color.clear.rootTabTitleScrollAnchor()
                        }
                    }
                }
                // While no library has found anything yet: the search is still going.
                if model.isSearching, model.matches.isEmpty {
                    statusLine(localized("搜索中…"), anchors: anchorsTitle)
                }
                ForEach(model.failures) { failure in
                    statusLine(failure.line, anchors: anchorsTitle && model.matches.isEmpty && !model.isSearching
                                   && failure.id == model.failures.first?.id)
                }
            }
        }
    }

    private func statusLine(_ text: String, anchors: Bool) -> some View {
        Text(text)
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textSecondary)
            .listRowBackground(Color.clear)
            .background { if anchors { Color.clear.rootTabTitleScrollAnchor() } }
    }
}

#Preview {
    let store = BookStore()
    let model = LibrarySearchModel()
    model.receiveForPreview(LibrarySearchAnswer(connectionID: "calibre", name: "Calibre",
                                                outcome: .failed("無法連線到伺服器"), entries: []), store: store)
    return NavigationStack {
        List { LibrarySearchSection(model: model, anchorsTitle: false) }
            .listStyle(.plain)
    }
    .environmentObject(store)
}
