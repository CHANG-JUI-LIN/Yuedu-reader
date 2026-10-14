import SwiftUI

/// One shelf copy found by 搜索 (unified search 4b-1), with the 作品詳情 route frozen when it
/// was found (audit §11.5 rule 1).
struct ShelfSearchMatch: Identifiable, Equatable {
    let book: ReadingBook
    let route: WorkDetailRoute
    /// What the work index knows of the copy beyond its record (its sidecar's ISBNs, the Open
    /// Library work its metadata was filled from), so 搜索 merges it with what shares one
    /// (unified search 4c-3, rule A).
    var identifiers: Set<ExternalIdentifier> = []
    /// Its language code as the index knows it; nil when unknown.
    var language: String? = nil
    var id: UUID { book.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book.id == rhs.book.id && lhs.book.title == rhs.book.title && lhs.book.author == rhs.book.author
            && lhs.book.currentPosition == rhs.book.currentPosition && lhs.book.coverImagePath == rhs.book.coverImagePath
            && lhs.identifiers == rhs.identifiers && lhs.language == rhs.language
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
        let indexed = store.workIndex.entries(for: Set(books.map { SourceItemKey.copy($0.id) }))
        let found = zip(books, provider.items(books)).compactMap { book, entry in
            WorkDetailRoute(entry).map { route in
                let known = indexed[.copy(book.id)]
                return ShelfSearchMatch(book: book, route: route, identifiers: Set(known?.identifiers ?? []),
                                        language: known?.language?.language)
            }
        }
        if found != matches { matches = found }
    }
}
