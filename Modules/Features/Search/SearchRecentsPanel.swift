import SwiftUI
import UIKit

// MARK: - Idle content

/// What the 搜索 page shows when it has no search to show: while its field is active
/// and empty, 最近搜索 and 最近閱讀 — Apple Books shows Recently Searched and Recently
/// Viewed when its field is tapped — and otherwise, or with neither to list, the page's
/// own hint.
///
/// A view of its own because `isSearching` is set only for the views inside
/// `.searchable`, never for the view that applies it.
struct SearchIdleContent<Hint: View>: View {
    let isQueryEmpty: Bool
    let onSearch: (String) -> Void
    let onOpenBook: (ReadingBook) -> Void
    let hint: Hint

    @Environment(\.isSearching) private var isSearching
    @EnvironmentObject private var bookStore: BookStore
    @AppStorage(RecentSearchQueries.storageKey) private var recentQueries = RecentSearchQueries()
    @AppStorage(RecentReadingSelection.clearedAtStorageKey) private var readingClearedAt: Double = 0
    @AppStorage(OffShelfReadRecords.storageKey) private var offShelfReads = OffShelfReadRecords()

    init(
        isQueryEmpty: Bool,
        onSearch: @escaping (String) -> Void,
        onOpenBook: @escaping (ReadingBook) -> Void,
        @ViewBuilder hint: () -> Hint
    ) {
        self.isQueryEmpty = isQueryEmpty
        self.onSearch = onSearch
        self.onOpenBook = onOpenBook
        self.hint = hint()
    }

    var body: some View {
        if isSearching, isQueryEmpty {
            let books = RecentReadingSelection.entries(
                shelf: bookStore.books,
                records: offShelfReads.records,
                clearedAt: RecentReadingSelection.clearedAt(storedValue: readingClearedAt)
            )
            if recentQueries.queries.isEmpty, books.isEmpty {
                hint
            } else {
                SearchRecentsList(
                    queries: recentQueries.queries,
                    books: books,
                    onSearch: onSearch,
                    onClearQueries: { recentQueries = RecentSearchQueries() },
                    onOpenBook: onOpenBook,
                    onClearBooks: { readingClearedAt = Date().timeIntervalSinceReferenceDate }
                )
            }
        } else {
            hint
        }
    }
}

// MARK: - Lists

/// 最近搜索 and 最近閱讀 laid out as Apple Books' search lays out Recently Searched and
/// Recently Viewed: each under a bold serif title with 清除 beside it and a rule under
/// both; a past search is a magnifying glass and its words, a book is a search-list row.
/// A tap runs the search again, or opens a shelf book where it was left; a book read
/// without being shelved is searched for by name, as legado opens such a record.
private struct SearchRecentsList: View {
    let queries: [String]
    let books: [RecentReadingSelection.Entry]
    let onSearch: (String) -> Void
    let onClearQueries: () -> Void
    let onOpenBook: (ReadingBook) -> Void
    let onClearBooks: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Plain rows, no `Section`: on iOS 26 a list section adds a gap above itself
        // and a rule of its own over the first row, which Apple Books' lists do not have.
        // Each head is a row with no rule above it; the only rules are the ones under
        // the heads and between the rows.
        List {
            if !queries.isEmpty {
                SearchRecentsHeader(
                    title: localized("最近搜索"),
                    clearAccessibilityLabel: localized("清除最近搜索"),
                    onClear: onClearQueries
                )
                .searchRecentsRow()
                .listRowSeparator(.hidden, edges: .top)

                ForEach(queries, id: \.self) { query in
                    Button {
                        searchAgain(query)
                    } label: {
                        RecentQueryLabel(query: query)
                    }
                    .accessibilityHint(localized("搜索"))
                    .searchRecentsRow()
                    .listRowSeparator(query == queries.last ? .hidden : .visible, edges: .bottom)
                }
            }

            if !books.isEmpty {
                SearchRecentsHeader(
                    title: localized("最近閱讀"),
                    clearAccessibilityLabel: localized("清除最近閱讀"),
                    onClear: onClearBooks
                )
                .searchRecentsRow()
                .listRowSeparator(.hidden, edges: .top)

                ForEach(books) { entry in
                    bookRow(entry)
                        .searchRecentsRow()
                        .listRowSeparator(entry.id == books.last?.id ? .hidden : .visible, edges: .bottom)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .softScrollEdges()
    }

    @ViewBuilder
    private func bookRow(_ entry: RecentReadingSelection.Entry) -> some View {
        switch entry {
        case .shelf(let book):
            Button {
                onOpenBook(book)
            } label: {
                SearchBookListRow(content: SearchBookListRowContent(shelfBook: book)) {
                    BookshelfCoverStyle.artwork(
                        for: book,
                        colorScheme: colorScheme,
                        displaySize: CGSize(
                            width: DSLayout.searchListCoverWidth,
                            height: DSLayout.searchListCoverHeight
                        )
                    )
                }
            }
        case .record(let record):
            Button {
                searchAgain(record.title)
            } label: {
                SearchBookListRow(content: SearchBookListRowContent(offShelfRecord: record)) {
                    BookCoverImage(coverURL: record.coverUrl, title: record.title, author: record.author)
                }
            }
            .accessibilityHint(localized("搜索"))
        }
    }

    /// Runs a search as the keyboard's own search key does: the field keeps the words
    /// and stays active, the keyboard goes.
    private func searchAgain(_ text: String) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        onSearch(text)
    }
}

/// A section's head: the title in bold serif, 清除 on the same baseline at the trailing
/// end, and a rule under both that spans the column, where a row's starts at its text.
private struct SearchRecentsHeader: View {
    let title: String
    /// 清除 alone does not say which list it empties.
    let clearAccessibilityLabel: String
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(title)
                .font(DSFont.serifSectionTitle)
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            // Borderless, so only the word answers a tap and not the whole row.
            Button(localized("清除"), action: onClear)
                .buttonStyle(.borderless)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .contentShape(Rectangle().inset(by: -DSSpacing.sm))
                .accessibilityLabel(clearAccessibilityLabel)
        }
        .padding(.top, DSSpacing.xl)
        .padding(.bottom, DSSpacing.sm)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
}

/// A past search: a magnifying glass, then the words.
private struct RecentQueryLabel: View {
    let query: String

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            // A size under the words, as Apple Books draws it.
            Image(systemName: "magnifyingglass")
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .accessibilityHidden(true)
            Text(query)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.leading, DSSpacing.sm)
        .padding(.vertical, DSSpacing.md)
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .contentShape(Rectangle())
    }
}

private extension View {
    /// A row of the recents lists: the search list's inset, and the page behind it.
    func searchRecentsRow() -> some View {
        listRowInsets(EdgeInsets(
            top: 0,
            leading: DSLayout.searchListHorizontalInset,
            bottom: 0,
            trailing: DSLayout.searchListHorizontalInset
        ))
        .listRowBackground(Color.clear)
    }
}

#Preview("最近搜索與最近閱讀") {
    SearchRecentsList(
        queries: ["紅樓夢", "三體"],
        books: [],
        onSearch: { _ in },
        onClearQueries: {},
        onOpenBook: { _ in },
        onClearBooks: {}
    )
}
