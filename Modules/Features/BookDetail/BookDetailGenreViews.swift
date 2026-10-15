import SwiftUI

// MARK: - Genre and author taps

/// A book-source detail page's genre links and author link, for a source that does not take
/// those taps itself (`BookDetailSourceGestures`): a genre opens the source's category of that
/// name, else searches the source for it; the author searches the source for their books.
@MainActor
struct BookDetailSourceLinks {
    let source: BookSource?
    let genres: SourceGenreLinks
    let openCategory: (ExploreCategoryReference) -> Void

    func links(for tags: [String]) -> [BookDetailLink] {
        tags.map { tag in BookDetailLink(id: tag, title: tag, action: { open(tag) }) }
    }

    func authorActions(_ author: String) -> [BookDetailAuthorAction] {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !name.isEmpty, name != localized("未知作者") else { return [] }
        let sourceKey = SearchSourceScope.sourceKey(for: source)
        return [BookDetailAuthorAction(id: "source", name: name, action: {
            SourceCallBackService.requestSearch(keyword: name, sourceURL: sourceKey)
        })]
    }

    private func open(_ tag: String) {
        let source = source
        let sourceKey = source.map(SearchSourceScope.sourceKey(for:))
        Task {
            switch await genres.destination(for: tag, in: source) {
            case .category(let reference):
                openCategory(reference)
            case .search(let keyword):
                SourceCallBackService.requestSearch(keyword: keyword, sourceURL: sourceKey)
            }
        }
    }
}

// MARK: - Genre category

/// A genre link's category, pushed from a book-source detail page: Explore's 查看全部 page for
/// it, whose books push their own detail here, since Explore's routes are registered only on
/// Explore's stack.
struct BookDetailCategoryPage: View {
    let reference: ExploreCategoryReference
    @EnvironmentObject private var bookStore: BookStore
    @State private var pushedBook: OnlineBook?

    var body: some View {
        Group {
            if let source = reference.source, let item = reference.cardItem {
                DiscoverCategoryView(
                    section: DiscoverShowcaseSection(
                        item: item, coverBaseURL: source.bookSourceUrl, coverHeaders: source.parsedHeaders
                    ),
                    source: source,
                    onSelectBook: { pushedBook = $0 }
                )
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("暫無發現內容"), systemImage: "books.vertical")
                }
                .navigationTitle(reference.title)
                .toolbarTitleDisplayMode(.inline)
            }
        }
        .navigationDestination(item: $pushedBook) { book in
            BookDetailRelatedBookDestination(book: book)
        }
    }
}

/// A book a detail page links to (同題材, a genre's category), opened as Explore opens one.
struct BookDetailRelatedBookDestination: View {
    let book: OnlineBook
    @EnvironmentObject private var bookStore: BookStore

    var body: some View {
        OnlineBookDetailDestination(.book(book))
            .environmentObject(bookStore)
            // Never the shelf's UIKit card driver: its reader closes onto the shelf, not
            // onto this pushed page.
            .environment(\.readerNavigator, nil)
    }
}

// MARK: - 同題材

/// 同題材作品: the first page of the source's category one of the book's genres names, as a
/// shelf of covers. Not shown when no genre names a category (`SourceGenreLinks.Related`).
/// The menu beside the title picks another category (maintainer, 2026-10-15).
struct BookDetailRelatedSection: View {
    let related: SourceGenreLinks.Related
    var choices: RelatedCategoryChoices?
    var onChoose: (String) -> Void = { _ in }
    let onShowAll: (ExploreCategoryReference) -> Void
    let onSelect: (OnlineBook) -> Void
    let onRetry: () -> Void

    var body: some View {
        if let reference {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(
                    title: localized("同題材作品"),
                    actionTitle: localized("查看全部"),
                    action: { onShowAll(reference) }
                ) {
                    if let choices, choices.offersChoice { categoryMenu(choices) }
                }
                .padding(.horizontal, DSSpacing.lg)
                content(reference)
            }
        }
    }

    /// Only once the books are read (or their read failed, to retry): a header over a
    /// spinner that could then vanish would move the page under the reader. A category the
    /// reader picked keeps the header with no other book (`SourceGenreLinks.choose`).
    private var reference: ExploreCategoryReference? {
        switch related {
        case .hidden, .loading: return nil
        case .loaded(let reference, _): return reference
        case .failed(let reference, _): return reference
        }
    }

    /// The book's genres that name a category, then the source's other categories.
    private func categoryMenu(_ choices: RelatedCategoryChoices) -> some View {
        let selection = Binding(get: { choices.current }, set: onChoose)
        return Menu {
            Picker(localized("同題材分類"), selection: selection) {
                ForEach(choices.matched, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            if !choices.others.isEmpty {
                Picker(localized("其他分類"), selection: selection) {
                    ForEach(choices.others, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            HStack(spacing: DSSpacing.xxs) {
                Text(choices.current)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DSFont.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.accent)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("同題材分類"))
        .accessibilityValue(choices.current)
        .accessibilityIdentifier("detail.related.category")
    }

    @ViewBuilder
    private func content(_ reference: ExploreCategoryReference) -> some View {
        switch related {
        case .loaded(_, let section) where section.books.isEmpty:
            Text(localized("這個分類沒有其他作品"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: DSLayout.discoverShelfCoverHeight)
                .padding(.horizontal, DSSpacing.lg)
        case .loaded(_, let section):
            shelf(section)
        case .failed:
            Button(action: onRetry) {
                Label(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.accent)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.discoverShelfCoverHeight)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DSSpacing.lg)
        case .loading, .hidden:
            EmptyView()
        }
    }

    private func shelf(_ section: DiscoverShowcaseSection) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(section.books) { display in
                    Button { onSelect(display.book) } label: {
                        DiscoverFeaturedCard(display: display, section: section)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("detail.related.book")
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

#Preview("同題材") {
    let reference = ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "/xuanhuan")
    let books = ["斗羅大陸", "鬥破蒼穹", "完美世界", "遮天"].map { name in
        DiscoverBookDisplay(
            book: OnlineBook(name: name, author: "作者", intro: "", coverUrl: "", bookUrl: "/\(name)",
                             tocUrl: "", wordCount: "", lastChapter: "", kind: "玄幻",
                             sourceId: UUID(), sourceName: "晴天小說"),
            intro: "", isAudiobook: false
        )
    }
    var section = DiscoverShowcaseSection(
        item: reference.cardItem!, coverBaseURL: reference.sourceURL, coverHeaders: [:]
    )
    section.books = books
    return ScrollView {
        VStack(spacing: DSSpacing.xl) {
            BookDetailRelatedSection(related: .loaded(reference, section),
                                     choices: RelatedCategoryChoices(matched: ["玄幻", "仙俠"], others: ["都市", "歷史"],
                                                                     current: "玄幻"),
                                     onShowAll: { _ in }, onSelect: { _ in }, onRetry: {})
            BookDetailRelatedSection(related: .loading(reference), onShowAll: { _ in },
                                     onSelect: { _ in }, onRetry: {})
            BookDetailRelatedSection(related: .failed(reference, "timeout"), onShowAll: { _ in },
                                     onSelect: { _ in }, onRetry: {})
        }
    }
}
