import SwiftUI

/// One shelf copy found by 搜索 (unified search 4b-1), with the 作品詳情 route frozen when it
/// was found (audit §11.5 rule 1).
struct ShelfSearchMatch: Identifiable, Equatable {
    let book: ReadingBook
    let route: WorkDetailRoute
    var id: UUID { book.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book.id == rhs.book.id && lhs.book.title == rhs.book.title && lhs.book.author == rhs.book.author
            && lhs.book.currentPosition == rhs.book.currentPosition && lhs.book.coverImagePath == rhs.book.coverImagePath
    }
}

/// 搜索's 書架 matches, as you type (unified search 4b-1). Local: the work index in memory,
/// no network. Owned by the search page and read only by the views that draw it.
@Observable
@MainActor
final class ShelfSearchModel {
    private(set) var matches: [ShelfSearchMatch] = []
    /// The shelf revision the index was last brought up to; a search after the shelf
    /// changed refreshes it first, once.
    @ObservationIgnored private var indexedRevision: UInt64?

    func search(_ query: String, in store: BookStore) async {
        guard !query.isEmpty else {
            if !matches.isEmpty { matches = [] }
            return
        }
        let revision = store.mutationRevision
        if indexedRevision != revision {
            _ = await store.workIndex.current()
            guard !Task.isCancelled else { return }
            indexedRevision = revision
        }
        let provider = ShelfProvider(store: store)
        let books = provider.searchCopies(query)
        let found = zip(books, provider.items(books)).compactMap { book, entry in
            WorkDetailRoute(entry).map { ShelfSearchMatch(book: book, route: $0) }
        }
        if found != matches { matches = found }
    }
}

/// The 書架 section of the 搜索 tab's results on iOS 18 and later: each copy as the shelf
/// draws it, opening 作品詳情.
struct ShelfSearchSection: View {
    let model: ShelfSearchModel
    /// The first row measures the list's scroll for the 搜索 tab's title.
    let anchorsTitle: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !model.matches.isEmpty {
            Section(localized("書架")) {
                ForEach(model.matches) { match in
                    NavigationLink(value: match.route) {
                        SearchBookListRow(content: SearchBookListRowContent(shelfBook: match.book)) {
                            BookshelfCoverStyle.artwork(
                                for: match.book,
                                colorScheme: colorScheme,
                                displaySize: CGSize(width: DSLayout.searchListCoverWidth, height: DSLayout.searchListCoverHeight)
                            )
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
            }
        }
    }
}

#Preview {
    let store = BookStore()
    let model = ShelfSearchModel()
    return NavigationStack {
        List { ShelfSearchSection(model: model, anchorsTitle: false) }
            .listStyle(.plain)
            .task {
                store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt"))
                await model.search("三体", in: store)
            }
    }
    .environmentObject(store)
}
