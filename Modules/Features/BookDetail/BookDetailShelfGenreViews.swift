import SwiftUI

/// 同題材作品 on a copy's 作品詳情 (maintainer, 2026-11-14: the same sections whatever the source):
/// the other works on this device of one of the copy's genres, as a row of covers whose title
/// opens all of that genre. Not shown until read, nor when no genre has another work.
struct BookDetailShelfGenreSection: View {
    let related: ShelfGenresModel.Related?
    let onShowAll: (String) -> Void
    let onSelect: (WorkDetailRoute) -> Void
    @EnvironmentObject private var store: BookStore

    var body: some View {
        if let related {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("同題材作品"), actionTitle: localized("查看全部"),
                                        action: { onShowAll(related.genre) }, trailing: related.genre)
                    .padding(.horizontal, DSSpacing.lg)
                    .accessibilityIdentifier("detail.shelfGenre.header")
                BookDetailCoverShelf(cards: HomeRowContent(entries: related.works, store: store).cards,
                                     identifier: "detail.shelfGenre.book", onSelect: onSelect)
                BookDetailSectionRule()
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }
}

/// A genre's works on this device, the page a copy's genre link and 同題材's title open: never the
/// search screen. A work opens its 作品詳情 on top.
struct ShelfGenreWorksPage: View {
    let genre: String
    @EnvironmentObject private var store: BookStore
    @State private var works: [CollectionEntry]?
    @State private var pushedWork: WorkDetailRoute?

    /// Works listed: a shelf of thousands of one genre is still a page.
    static let limit = 120

    var body: some View {
        content
            .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            .navigationTitle(genre)
            .toolbarTitleDisplayMode(.inline)
            .task(id: genre) {
                works = await ShelfProvider(store: store).works(ofGenre: genre, excluding: [], limit: Self.limit)
            }
            .navigationDestination(item: $pushedWork) { route in
                WorkDetailView(route: route).environmentObject(store)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let works {
            if works.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("這個分類沒有其他作品"), systemImage: "books.vertical")
                }
            } else {
                ScrollView {
                    // Not in a lazy stack: the grid measures its own width (`HomeSectionCards`).
                    HomeSectionCards(layout: .coverGrid, cards: HomeRowContent(entries: works, store: store).cards,
                                     rowID: "detail.shelfGenre", hasShowAll: false,
                                     open: { card, _ in pushedWork = card.route })
                        .padding(.vertical, DSSpacing.lg)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(localized("載入中…"))
        }
    }
}

#if DEBUG
#Preview("同題材 · 本機") {
    let index = AozoraCatalogIndex.preview
    return ScrollView {
        BookDetailShelfGenreSection(
            related: .init(genre: "科幻", works: index.newWorks.map { CollectionEntry.aozora($0, index: index) }),
            onShowAll: { _ in }, onSelect: { _ in })
    }
    .environmentObject(BookStore())
}

#Preview("分類頁 · 本機") {
    NavigationStack { ShelfGenreWorksPage(genre: "科幻") }
        .environmentObject(BookStore())
}
#endif
