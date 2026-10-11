import SwiftUI

// Unified library 5d-3: a section's books in the layout it chose (Phase 5 plan, decision 14;
// the maintainer's layout notes):
// - 大型閱讀卡片: a large cover beside the title, author and how far it is read, one card to a
//   phone's width (two on a wider screen), the next one showing past the edge.
// - 橫向單排書架: one row of covers that swipes sideways (5c's row).
// - 多行橫向輪播: two rows of smaller covers, swiped sideways together.
// - 固定封面網格: a fixed number of columns, read downwards.
// - 圖文資訊清單: a small cover beside the title, author and blurb; ranked as an option.
// The grid and the list show a few rows when the section has 查看全部 and everything when it
// has not, since nothing else would show the rest. A loading section draws the same layout
// with blank cards, so the page does not jump when the books arrive.

struct HomeSectionCards: View {
    let layout: HomeSectionLayout
    let cards: [HomeCardContent]
    /// The row's id: the cards' scope for the public-library carousel's cover frames.
    let rowID: String
    /// Whether the header leads to 查看全部.
    let hasShowAll: Bool
    let open: (HomeCardContent, [HomeCardContent]) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.publicLibraryCoverFrames) private var coverFrames
    @ScaledMetric(relativeTo: .subheadline) private var scaledRowCoverWidth = DSLayout.homeCardCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var compactCoverWidth = DSLayout.homeCompactCoverWidth
    @ScaledMetric(relativeTo: .headline) private var readingCoverWidth = DSLayout.homeReadingCardCoverWidth
    @ScaledMetric(relativeTo: .headline) private var listCoverWidth = DSLayout.homeListCoverWidth
    @State private var gridWidth: CGFloat = 0

    /// Rows the grid shows, and books the list shows, when 查看全部 has the rest.
    private static let gridRows = 3
    private static let listCount = 5

    private var rowCoverWidth: CGFloat { min(scaledRowCoverWidth, DSLayout.homeCardCoverMaxWidth) }
    private var style: HomeLayoutStyle { layout.drawnStyle(accessibilityTextSize: dynamicTypeSize.isAccessibilitySize) }

    var body: some View {
        Group {
            switch style {
            case .readingCard: readingCards
            case .row: rail
            case .multiRow: multiRow
            case .coverGrid: grid
            case .list: list
            }
        }
        .environment(\.publicLibraryCoverScope, rowID)
    }

    /// One card's button: the identifier the UI tests find it by, and the label VoiceOver reads.
    private func button(_ index: Int, in shown: [HomeCardContent], rank: Int? = nil,
                        @ViewBuilder label: () -> some View) -> some View {
        let card = shown[index]
        let rankText = rank.map { $0.formatted() }
        return Button {
            coverFrames?.activeScope = rowID
            open(card, cards)
        } label: {
            label()
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([rankText, card.accessibilityLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(card.accessibilityValue)
        .accessibilityIdentifier("home.card.\(card.id.instance.type.rawValue).\(card.id.item)")
    }

    // MARK: 橫向單排書架

    private var rail: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                // By position: a source can list one item twice.
                ForEach(cards.indices, id: \.self) { index in
                    button(index, in: cards) { HomeBookCard(content: cards[index], coverWidth: rowCoverWidth) }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    // MARK: 大型閱讀卡片

    private var readingCards: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(cards.indices, id: \.self) { index in
                    button(index, in: cards) {
                        HomeReadingCard(content: cards[index], coverWidth: readingCoverWidth,
                                        stacksVertically: dynamicTypeSize.isAccessibilitySize)
                    }
                    .containerRelativeFrame(.horizontal) { length, _ in
                        // The next card shows past the edge when there is one.
                        let peek = cards.count > perScreen ? DSLayout.homeReadingCardPeek + DSSpacing.md : 0
                        let gaps = DSSpacing.md * CGFloat(perScreen - 1)
                        return max(0, (length - gaps - peek) / CGFloat(perScreen))
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    // MARK: 多行橫向輪播

    private var multiRow: some View {
        let columns = stride(from: 0, to: cards.count, by: 2).map { Array($0..<min($0 + 2, cards.count)) }
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        ForEach(columns[column], id: \.self) { index in
                            button(index, in: cards) {
                                HomeBookCard(content: cards[index], coverWidth: compactCoverWidth, reservesTextSpace: true)
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    // MARK: 固定封面網格

    /// As many columns as fit at the compact cover's width, never fewer than two.
    private var gridColumns: Int {
        let spacing = DSSpacing.md
        return max(2, Int((gridWidth + spacing) / (compactCoverWidth + spacing)))
    }

    private var grid: some View {
        let spacing = DSSpacing.md
        let count = gridColumns
        let coverWidth = max(0, (gridWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
        let shown = hasShowAll ? Array(cards.prefix(count * Self.gridRows)) : cards
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(coverWidth), spacing: spacing, alignment: .top), count: count),
                         alignment: .leading, spacing: DSSpacing.lg) {
            if gridWidth > 0 {
                ForEach(shown.indices, id: \.self) { index in
                    button(index, in: shown) {
                        HomeBookCard(content: shown[index], coverWidth: coverWidth, reservesTextSpace: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: 圖文資訊清單

    private var list: some View {
        let shown = hasShowAll ? Array(cards.prefix(Self.listCount)) : cards
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown.indices, id: \.self) { index in
                button(index, in: shown, rank: layout.showsRanks ? index + 1 : nil) {
                    HomeListRow(content: shown[index], rank: layout.showsRanks ? index + 1 : nil,
                                coverWidth: listCoverWidth, stacksVertically: dynamicTypeSize.isAccessibilitySize)
                }
                if index < shown.count - 1 {
                    Divider().padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : listCoverWidth + DSSpacing.md)
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

/// The sideways layouts' scrolling: margins as wide as the header's, one card at a time.
private struct HomeSidewaysScroll: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
    }
}

// MARK: - 大型閱讀卡片

/// A large cover and, beside it, the title, author, the blurb or status, and the progress bar
/// of a copy part read. The text goes under the cover at accessibility text sizes.
struct HomeReadingCard: View {
    let content: HomeCardContent
    let coverWidth: CGFloat
    var stacksVertically = false

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    var body: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpacing.lg))
        layout {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
            text
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: coverSize.height + DSSpacing.lg * 2, alignment: .topLeading)
        .background(DSColor.surface, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(content.title)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
            if !content.author.isEmpty {
                Text(content.author)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if let blurb = content.blurb {
                Text(blurb)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(3)
                    .padding(.top, DSSpacing.xxs)
            }
            Spacer(minLength: DSSpacing.sm)
            if let detail = content.detail {
                Text(detail)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if let progress = content.progress {
                HomeProgressBar(progress: progress)
                    .clipShape(Capsule())
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 圖文資訊清單

/// A rank, a small cover, and the title, author, blurb and status beside it.
struct HomeListRow: View {
    let content: HomeCardContent
    let rank: Int?
    let coverWidth: CGFloat
    var stacksVertically = false

    var body: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpacing.md))
        layout {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author,
                          size: CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio))
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                if let rank {
                    CustomExploreRankBadge(rank: rank)
                        .padding(.bottom, DSSpacing.xxs)
                }
                Text(content.title)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
                if !content.author.isEmpty {
                    Text(content.author)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
                if let blurb = content.blurb {
                    Text(blurb)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
                if let detail = content.detail {
                    Text(detail)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DSSpacing.md)
        .contentShape(Rectangle())
    }
}

#Preview("五種呈現方式") {
    let cards = (0..<8).map(HomeCardContent.placeholder)
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            ForEach(HomeLayoutStyle.allCases) { style in
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    Text(localized(style.titleKey)).font(DSFont.title2.weight(.bold)).padding(.horizontal, DSSpacing.lg)
                    HomeSectionCards(layout: HomeSectionLayout(style: style, ranked: style == .list), cards: cards,
                                     rowID: style.rawValue, hasShowAll: true, open: { _, _ in })
                }
            }
        }
    }
}
