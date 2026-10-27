import SwiftUI

/// A card of a layout of lists whose list has no page of its own (繼續閱讀, 相關, a 書架 group…;
/// `HomeListCards.swift`): the books the card drew, frozen when it was made, as a grid.
/// A book opens what its card on the home opens (`ExplorePush.card`).
struct HomeListPage: View {
    let route: HomeListRoute
    @EnvironmentObject private var store: BookStore
    @Environment(\.explorePush) private var push

    private var cards: [HomeCardContent] {
        HomeRowContent(entries: route.entries, store: store).cards
    }

    var body: some View {
        let cards = cards
        ScrollView {
            // Not a `LazyVStack`: the grid draws its covers once it has measured its width
            // (`ModuleListPage`). The grid itself is lazy.
            VStack(spacing: DSSpacing.lg) {
                if cards.isEmpty {
                    ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical")
                } else {
                    HomeSectionCards(layout: HomeSectionLayout(style: .coverGrid), cards: cards,
                                     rowID: "home.list.\(route.title)", hasShowAll: false) { card, _ in
                        if let work = card.route { push?(.card(work, in: route.binding)) }
                    }
                }
            }
            .padding(.bottom, DSSpacing.xxl)
        }
        .softScrollEdges()
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
    }
}

#Preview("卡片的書") {
    NavigationStack {
        HomeListPage(route: HomeListRoute(title: "繼續閱讀", binding: .continueReading,
                                          entries: PublicLibraryCollection.all[0].books.prefix(6).map(CollectionEntry.bundledGutenberg)))
    }
    .environmentObject(BookStore())
}

#Preview("卡片的書：空") {
    NavigationStack {
        HomeListPage(route: HomeListRoute(title: "書架", binding: .bookshelf, entries: []))
    }
    .environmentObject(BookStore())
}
