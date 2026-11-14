import SwiftUI

/// What an author's page pushes, through its one `navigationDestination`.
private enum AuthorPagePush: Hashable {
    /// Every work of one row, from its title.
    case all(title: String, works: [CollectionEntry])
    /// A public library's own page of the author, every work the library has.
    case library(PublicLibraryAuthorDestination)
    case work(WorkDetailRoute)
}

/// An author's page, the one every detail page's author opens (maintainer, 2026-11-14: never the
/// search screen, and the same page whatever the source). An author with books and audiobooks
/// has a row of each, as Apple Books' store draws an author, whose title opens all of that row;
/// an author with one kind has that kind's works as a grid.
struct AuthorPageView: View {
    let request: AuthorPageRequest
    @EnvironmentObject private var store: BookStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AuthorPageModel()
    @State private var pushed: AuthorPagePush?

    var body: some View {
        content
            // A white page, as the detail page it was pushed from; a theme still paints its own.
            .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            // In 中繼資料語言偏好推薦's script, as the works under it are written.
            .navigationTitle(MetadataDisplay.current.text(request.name))
            .toolbarTitleDisplayMode(.inline)
            .task(id: request) {
                model.setPresentationActive(scenePhase == .active)
                await model.load(request, store: store)
            }
            .onChange(of: scenePhase) { _, phase in model.setPresentationActive(phase == .active) }
            .toolbar {
                // The background search, quietly: the page is usable while more sources answer.
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isSearching {
                        ProgressView()
                            .accessibilityLabel(localized("正在搜尋…"))
                    }
                }
            }
            .navigationDestination(item: $pushed) { push in
                switch push {
                case .all(let title, let works):
                    AuthorWorksGridPage(title: title, works: works).environmentObject(store)
                case .library(let destination):
                    WorkDetailAuthorPage(destination: destination).environmentObject(store)
                case .work(let route):
                    WorkDetailView(route: route).environmentObject(store)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            // The page's own shape, grey: covers where the works will be (maintainer, 2026-11-14:
            // 「改成骨架屏佔位來加載」), as a home row draws its loading cards.
            ScrollView {
                HomeSectionCards(layout: .coverGrid, cards: (0..<6).map(HomeCardContent.placeholder),
                                 rowID: "author.loading", hasShowAll: false, open: { _, _ in })
                    .padding(.vertical, DSSpacing.lg)
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localized("載入中…"))
            }
            .scrollDisabled(true)
        case .loaded(let shelf) where shelf.isEmpty:
            ContentUnavailableView {
                UnavailableLabel(localized("沒有找到這位作者的作品"), systemImage: "person")
            }
        case .loaded(let shelf) where shelf.hasBothKinds:
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    row(localized("書籍"), works: shelf.books, identifier: "author.books", isBooks: true)
                    row(localized("有聲書"), works: shelf.audiobooks, identifier: "author.audiobooks", isBooks: false)
                }
                .padding(.vertical, DSSpacing.lg)
            }
        case .loaded(let shelf):
            // One kind: its works alone, with no row title to tell it from another.
            ScrollView {
                AuthorWorksGrid(works: shelf.books.isEmpty ? shelf.audiobooks : shelf.books,
                                open: { pushed = .work($0) })
            }
        }
    }

    private func row(_ title: String, works: [CollectionEntry], identifier: String, isBooks: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookDetailSectionHeader(title: title, actionTitle: localized("查看全部"),
                                    action: { showAll(title, works, isBooks: isBooks) })
                .padding(.horizontal, DSSpacing.lg)
                .accessibilityIdentifier(identifier + ".header")
            BookDetailCoverShelf(cards: HomeRowContent(entries: works, store: store).cards,
                                 identifier: identifier + ".book", onSelect: { pushed = .work($0) })
        }
    }

    /// Every work of a row. A public library's books are the library's own page of the author,
    /// which lists all of them (the row holds the first `AuthorShelf.limit`).
    private func showAll(_ title: String, _ works: [CollectionEntry], isBooks: Bool) {
        if isBooks, case .library(let destination) = request.context {
            pushed = .library(destination)
        } else {
            pushed = .all(title: title, works: works)
        }
    }
}

/// A grid of covers, each opening its work. Not in a lazy stack: the grid measures its own width
/// (`HomeSectionCards`).
private struct AuthorWorksGrid: View {
    let works: [CollectionEntry]
    let open: (WorkDetailRoute) -> Void
    @EnvironmentObject private var store: BookStore

    var body: some View {
        let cards = HomeRowContent(entries: works, store: store).cards
        HomeSectionCards(layout: .coverGrid, cards: cards, rowID: "author.all", hasShowAll: false,
                         open: { card, _ in if let route = card.route { open(route) } })
            .padding(.vertical, DSSpacing.lg)
            .prefetchingCovers(of: cards)
    }
}

/// Every work of one of an author's rows: the page 查看全部 opens. A work opens its 作品詳情 on top.
struct AuthorWorksGridPage: View {
    let title: String
    let works: [CollectionEntry]
    @EnvironmentObject private var store: BookStore
    @State private var pushedWork: WorkDetailRoute?

    var body: some View {
        ScrollView {
            AuthorWorksGrid(works: works, open: { pushedWork = $0 })
        }
        .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
        .pageBackgroundToolbar(for: .global)
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushedWork) { route in
            WorkDetailView(route: route).environmentObject(store)
        }
    }
}

#if DEBUG
#Preview("作者頁") {
    NavigationStack {
        AuthorPageView(request: AuthorPageRequest(name: "夏目 漱石", context: .device))
    }
    .environmentObject(BookStore())
}

#Preview("作者頁 · 查看全部") {
    let index = AozoraCatalogIndex.preview
    return NavigationStack {
        AuthorWorksGridPage(title: "書籍", works: index.newWorks.map { CollectionEntry.aozora($0, index: index) })
    }
    .environmentObject(BookStore())
}
#endif
