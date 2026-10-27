import SwiftUI

// 排行榜 (maintainer, 2026-10-27: 「排行榜也照著圖片1比1復刻」 after Apple Books' Top Charts; it
// replaced 顯示排名, 「每欄一份排行」「每欄 3 名」): a column per ranking, swiped sideways and the
// next one peeking, each its first three places under a rule and between rules. With several
// rankings each column is headed by its name and a chevron to all of it, as Paid and Free are;
// with one, the section's header names it and the column takes the page.

/// A section's rankings as Top Charts' columns.
struct HomeChartColumns: View {
    /// The rankings, a column each: what the column's header opens.
    let collections: [CollectionSummary]
    /// Each ranking's books, or articles (訂閱的最新文章), in order, by its id
    /// (`HomeRowContent.lists`); the first `places` are drawn. A ranking with none while the row
    /// loads draws blank places.
    let contents: [String: HomeRowContent]
    let openColumn: (CollectionSummary) -> Void
    let open: (HomeCardContent, [HomeCardContent]) -> Void
    var openArticle: (SubscriptionArticle) -> Void = { _ in }

    /// Places a column draws, as Top Charts does.
    static let places = 3

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.redactionReasons) private var redactionReasons
    @ScaledMetric(relativeTo: .headline) private var coverWidth = DSLayout.homeChartCoverWidth

    var body: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        let headed = collections.count > 1
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.xl) {
                ForEach(collections) { collection in
                    column(collection, headed: headed)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            guard collections.count > perScreen else {
                                return max(0, (length - DSSpacing.xl * CGFloat(collections.count - 1)) / CGFloat(collections.count))
                            }
                            let gaps = DSSpacing.xl * CGFloat(perScreen)
                            return max(0, (length - gaps - DSLayout.homePagePeek) / CGFloat(perScreen))
                        }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    private func column(_ collection: CollectionSummary, headed: Bool) -> some View {
        let content = contents[collection.id]
        let cards = content?.cards ?? []
        let articles = cards.isEmpty ? Array((content?.articles ?? []).prefix(Self.places)) : []
        // A loading column has no books yet: blank places, drawn as the skeleton.
        let shown = cards.isEmpty && redactionReasons.contains(.placeholder)
            ? (0..<Self.places).map(HomeCardContent.placeholder)
            : Array(cards.prefix(Self.places))
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            if headed {
                Button { openColumn(collection) } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Text(collection.title)
                            .font(DSFont.title3.weight(.semibold))
                            .foregroundStyle(DSColor.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.forward")
                            .font(DSFont.title3.weight(.semibold))
                            .foregroundStyle(DSColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, DSSpacing.lg)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .homeRowControl()
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(localized("查看全部"))
                .accessibilityIdentifier("home.chart.header.\(collection.id)")
            }
            ForEach(shown.indices, id: \.self) { index in
                if index > 0 { Divider() }
                row(shown[index], rank: index + 1, in: cards)
            }
            ForEach(articles.indices, id: \.self) { index in
                if index > 0 { Divider() }
                articleRow(articles[index], rank: index + 1)
            }
        }
    }

    private func articleRow(_ article: SubscriptionArticle, rank: Int) -> some View {
        Button { openArticle(article) } label: {
            HomeChartArticleRow(article: article, rank: rank, thumbnailWidth: min(coverWidth, DSLayout.homeCardCoverMaxWidth),
                                stacksVertically: dynamicTypeSize.isAccessibilitySize)
        }
        .buttonStyle(ExploreTileButtonStyle())
        .homeRowControl()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([rank.formatted(), article.title].joined(separator: ", "))
        .accessibilityValue(article.accessibilityValue)
        .accessibilityIdentifier("home.article.\(article.id)")
    }

    private func row(_ card: HomeCardContent, rank: Int, in cards: [HomeCardContent]) -> some View {
        Button { open(card, cards) } label: {
            HomeChartRow(content: card, rank: rank, coverWidth: min(coverWidth, DSLayout.homeCardCoverMaxWidth),
                         stacksVertically: dynamicTypeSize.isAccessibilitySize)
        }
        .buttonStyle(ExploreTileButtonStyle())
        .homeRowControl()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([rank.formatted(), card.accessibilityLabel].joined(separator: ", "))
        .accessibilityValue(card.accessibilityValue)
        .accessibilityIdentifier("home.card.\(card.id.instance.type.rawValue).\(card.id.item)")
    }
}

extension CollectionSummary {
    /// The list's books as its row has them, for 排行榜's column: a card's, frozen when its row
    /// loaded (`HomeListOpening.entries`), or a bundled Gutenberg list's, which the app carries
    /// and its row reads the same way (`GutenbergProvider.load`).
    var bookEntries: [CollectionEntry] {
        switch opening {
        case .list(let opening):
            return opening.entries
        case .gutenbergCollection(let id):
            guard let collection = PublicLibraryCollection.all.first(where: { $0.id == id }) else { return [] }
            return collection.books.map(CollectionEntry.bundledGutenberg)
        }
    }
}

#if DEBUG
/// Blank places, as a loading column's.
@MainActor
private func chartPreviewContent() -> HomeRowContent {
    var content = HomeRowContent(entries: [], status: { _ in nil }, shelfBooks: [:])
    content.cards = (0..<6).map(HomeCardContent.placeholder)
    return content
}

#Preview("排行榜") {
    let lists = ["小說排行", "漫畫排行"].map { title in
        CollectionSummary(id: title, title: title, books: [], languages: [], opening: .gutenbergCollection(id: title))
    }
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            HomeChartColumns(collections: lists,
                             contents: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, chartPreviewContent()) }),
                             openColumn: { _ in }, open: { _, _ in })
            HomeChartColumns(collections: [lists[0]], contents: [lists[0].id: chartPreviewContent()],
                             openColumn: { _ in }, open: { _, _ in })
        }
    }
}
#endif
