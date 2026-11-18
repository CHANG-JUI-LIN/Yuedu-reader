import SwiftUI

// MARK: - Genre and author taps

/// A book-source detail page's genre links and author link, for a source that does not take
/// those taps itself (`BookDetailSourceGestures`). Each opens a page of its own, never the
/// search screen (maintainer, 2026-11-14): a genre the source's category of that name, else
/// the source's books for it (`SourceTagWorksPage`); the author the author's page
/// (`AuthorPageView`).
@MainActor
struct BookDetailSourceLinks {
    let source: BookSource?
    let genres: SourceGenreLinks
    let openCategory: (ExploreCategoryReference) -> Void
    let openTag: (SourceTagPage) -> Void
    let openAuthor: (AuthorPageRequest) -> Void

    func links(for tags: [String]) -> [BookDetailLink] {
        tags.map { tag in BookDetailLink(id: tag, title: tag, action: { open(tag) }) }
    }

    func authorActions(_ author: String) -> [BookDetailAuthorAction] {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !WorkMatchKey.knownAuthors([name]).isEmpty else { return [] }
        let request = AuthorPageRequest(name: name, context: .source(source.id))
        return [BookDetailAuthorAction(id: "source", name: name, action: { openAuthor(request) })]
    }

    private func open(_ tag: String) {
        let source = source
        Task {
            switch await genres.destination(for: tag, in: source) {
            case .category(let reference):
                openCategory(reference)
            case .search(let keyword):
                // No category of that name: the source's books for the word, on a page of their own.
                guard let source else { return }
                openTag(SourceTagPage(sourceID: source.id, tag: keyword))
            }
        }
    }
}

// MARK: - Genre without a category

/// A genre the source lists no category for: the source and the word.
struct SourceTagPage: Hashable, Sendable {
    let sourceID: UUID
    let tag: String
}

/// The source's books for a genre it has no category of (maintainer, 2026-11-14: a genre opens
/// a page of its own, never the search screen): what the source's own search finds for the word,
/// as a grid of covers. A book opens its detail on top.
struct SourceTagWorksPage: View {
    let page: SourceTagPage
    @EnvironmentObject private var bookStore: BookStore
    @State private var state: LoadState = .loading
    @State private var pushedBook: OnlineBook?

    private enum LoadState {
        case loading
        case loaded([CollectionEntry])
        case failed
    }

    var body: some View {
        content
            .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            .navigationTitle(page.tag)
            .toolbarTitleDisplayMode(.inline)
            .task(id: page) { await load() }
            .navigationDestination(item: $pushedBook) { book in
                BookDetailRelatedBookDestination(book: book).environmentObject(bookStore)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(localized("載入中…"))
        case .loaded(let works) where works.isEmpty:
            ContentUnavailableView {
                UnavailableLabel(localized("這個分類沒有其他作品"), systemImage: "books.vertical")
            }
        case .loaded(let works):
            ScrollView {
                // Not in a lazy stack: the grid measures its own width (`HomeSectionCards`).
                HomeSectionCards(layout: .coverGrid, cards: HomeRowContent(entries: works, store: bookStore).cards,
                                 rowID: "detail.tag", hasShowAll: false,
                                 open: { card, _ in
                                     if case .onlineBook(let frozen)? = card.route?.opening { pushedBook = frozen.book }
                                 })
                    .padding(.vertical, DSSpacing.lg)
            }
        case .failed:
            ContentUnavailableView {
                UnavailableLabel(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
            } actions: {
                Button(localized("重試")) { Task { await load() } }
            }
        }
    }

    private func load() async {
        state = .loading
        guard let source = BookSourceStore.shared.source(id: page.sourceID), !source.searchUrl.isEmpty else {
            state = .loaded([])
            return
        }
        do {
            // Through the source's own search, as 搜索 asks it (`BookSourceSession` under it).
            switch try await BookSourceFetcher.shared.searchOutcome(query: page.tag, in: source) {
            case .results(let books):
                state = .loaded(CollectionEntry.onlineBooks(books.prefix(AuthorShelf.limit), source: source))
            case .empty:
                state = .loaded([])
            case .failed(let failure):
                throw failure
            }
        } catch is CancellationError {
            return
        } catch {
            AppLogger.network("⟐ genre page: source search failed", error: SourceFailure.loggable(error),
                              context: ["source": page.sourceID.uuidString])
            state = .failed
        }
    }
}

// MARK: - A module book's genre

/// A module book's genre, pushed from 作品詳情 (format 3.0.2): the module's books of it, page by
/// page, on the page a module row's 查看全部 opens (`ModuleListPage`). A book opens its own
/// 作品詳情 on this stack, a series its page first, as Explore opens them.
struct WorkDetailModuleTagPage: View {
    let route: ModuleListRoute
    @EnvironmentObject private var store: BookStore
    @State private var pushed: ExplorePush?

    var body: some View {
        ModuleListPage(route: route)
            .environment(\.explorePush, .into($pushed))
            .navigationDestination(item: $pushed) { push in
                switch push {
                case .work(let work): WorkDetailView(route: work).environmentObject(store)
                case .series(let series): ListedSeriesPage(route: series).environmentObject(store)
                // A module list's card opens nothing else (`ExplorePush.item`).
                case .reader, .explore, .feed, .folder, .publicLibrary, .article, .list: EmptyView()
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
    /// How the works are laid out: a row that scrolls (books), or a wall of posters, as a media
    /// centre shows a genre (videos; maintainer, 2026-11-01: 「海報牆」).
    enum Layout {
        case shelf
        case wall
    }

    let related: SourceGenreLinks.Related
    var choices: RelatedCategoryChoices?
    var layout: Layout = .shelf
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
                BookDetailSectionRule()
                    .padding(.horizontal, DSSpacing.lg)
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
        let selection = Binding(get: { choices.current }, set: { onChoose($0) })
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
            // Quiet, as the rest of the page is: no accent colour (maintainer, 2026-11-12).
            .foregroundStyle(DSColor.textSecondary)
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
            switch layout {
            case .shelf: shelf(section)
            case .wall: wall(section)
            }
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
        // The row is lazy and below the fold: its covers are fetched once it has its books
        // (2026-11-14). The wall is not lazy: its posters load as the page is built.
        .prefetchingCovers(of: section)
    }

    /// Three posters a row, the first few rows; 查看全部 has the rest. Not a lazy grid: it is
    /// a handful, and a lazy one inside the page's scroll view can leave VoiceOver nothing to
    /// reach.
    private func wall(_ section: DiscoverShowcaseSection) -> some View {
        let books = Array(section.books.prefix(DSLayout.videoPosterWallCount))
        let columns = 3
        return VStack(alignment: .leading, spacing: DSSpacing.lg) {
            ForEach(Array(stride(from: 0, to: books.count, by: columns)), id: \.self) { start in
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(start..<(start + columns), id: \.self) { index in
                        if books.indices.contains(index) {
                            poster(books[index], in: section)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private func poster(_ display: DiscoverBookDisplay, in section: DiscoverShowcaseSection) -> some View {
        Button { onSelect(display.book) } label: {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                DiscoverCover(display: display, section: section, size: nil)
                Text(display.book.name)
                    .font(DSFont.footnote.weight(.medium))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityValue(ContentKind(display.contentKind).mediaTag ?? "")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.related.book")
    }
}

#Preview("同題材") {
    let reference = ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "/xuanhuan")
    let books = ["斗羅大陸", "鬥破蒼穹", "完美世界", "遮天"].map { name in
        DiscoverBookDisplay(
            book: OnlineBook(name: name, author: "作者", intro: "", coverUrl: "", bookUrl: "/\(name)",
                             tocUrl: "", wordCount: "", lastChapter: "", kind: "玄幻",
                             sourceId: UUID(), sourceName: "晴天小說"),
            intro: "", contentKind: .text
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
            BookDetailRelatedSection(related: .loaded(reference, section), layout: .wall,
                                     onShowAll: { _ in }, onSelect: { _ in }, onRetry: {})
            BookDetailRelatedSection(related: .loading(reference), onShowAll: { _ in },
                                     onSelect: { _ in }, onRetry: {})
            BookDetailRelatedSection(related: .failed(reference, "timeout"), onShowAll: { _ in },
                                     onSelect: { _ in }, onRetry: {})
        }
    }
}
