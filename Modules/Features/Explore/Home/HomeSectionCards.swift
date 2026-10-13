import SwiftUI

// Unified library 5d-3: a section's books in the layout it chose (Phase 5 plan, decision 14;
// the maintainer's layout notes):
// - 大型閱讀卡片: a large cover beside the title, author and how far it is read, one card to a
//   phone's width (two on a wider screen), the next one showing past the edge.
// - 精簡閱讀卡片 (5d-3c, decision 20): as Apple Books' Continue, a small cover beside the
//   title, author and kind・progress, on the cover's colour, with a ••• for a shelf copy.
// - 橫向單排書架: one row of covers that swipes sideways (5c's row).
// - 多行橫向輪播: two rows of smaller covers, swiped sideways together.
// - 固定封面網格: a fixed number of columns, read downwards.
// - 圖文資訊清單: a small cover beside the title, author and blurb; ranked as an option.
// - 精選 (decisions 30 and 37): as Apple Books' featured, one book to a page on the cover's
//   colour: a large cover beside the category, title, author, a line of blurb and 查看作品.
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
    /// What a shelf copy's ••• offers on 精簡閱讀卡片; none in a fixture or a loading row.
    var bookActions: HomeBookActions?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.publicLibraryCoverFrames) private var coverFrames
    @ScaledMetric(relativeTo: .subheadline) private var scaledRowCoverWidth = DSLayout.homeCardCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var compactCoverWidth = DSLayout.homeCompactCoverWidth
    @ScaledMetric(relativeTo: .headline) private var readingCoverWidth = DSLayout.homeReadingCardCoverWidth
    @ScaledMetric(relativeTo: .headline) private var listCoverWidth = DSLayout.homeListCoverWidth
    @ScaledMetric(relativeTo: .headline) private var compactReadingCoverWidth = DSLayout.homeCompactReadingCardCoverWidth
    @ScaledMetric(relativeTo: .headline) private var featuredCoverWidth = DSLayout.homeFeaturedCoverWidth
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
            case .compactReadingCard: compactReadingCards
            case .row: rail
            case .multiRow: multiRow
            case .coverGrid: grid
            case .list: list
            case .featured: featured
            }
        }
        .environment(\.publicLibraryCoverScope, rowID)
    }

    /// One card's button: the identifier the UI tests find it by, and the label VoiceOver reads.
    /// - Parameter value: what VoiceOver reads after the label, when the layout shows more than
    ///   the card's own value.
    private func button(_ index: Int, in shown: [HomeCardContent], rank: Int? = nil, menu: [HomeCardMenuItem] = [],
                        value: String? = nil, @ViewBuilder label: () -> some View) -> some View {
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
        .accessibilityValue(value ?? card.accessibilityValue)
        // The ••• menu's items, also on the card for VoiceOver's actions rotor.
        .accessibilityActions {
            ForEach(menu) { item in Button(item.title, action: item.perform) }
        }
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

    // MARK: 精簡閱讀卡片

    private var compactReadingCards: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    let menu = HomeCardMenuItem.items(for: card, actions: bookActions)
                    button(index, in: cards, menu: menu) {
                        HomeCompactReadingCard(content: card, coverWidth: compactReadingCoverWidth,
                                               stacksVertically: dynamicTypeSize.isAccessibilitySize,
                                               reservesMenuSpace: !menu.isEmpty)
                    }
                    // Beside the card's button, not in it: a menu inside a button is not reachable.
                    .overlay(alignment: .bottomTrailing) {
                        if !menu.isEmpty { HomeCardMenuButton(card: card, items: menu) }
                    }
                    .containerRelativeFrame(.horizontal) { length, _ in
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

    // MARK: 精選

    /// One book to a page, the next one showing past the edge; two to a page on a wider screen.
    private var featured: some View {
        let perScreen = horizontalSizeClass == .regular ? 2 : 1
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    // The card's whole text, as on screen: the category and the blurb too.
                    let value = [card.category, card.accessibilityValue, card.blurb]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                    button(index, in: cards, value: value) {
                        HomeFeaturedCard(content: card, coverWidth: featuredCoverWidth,
                                         stacksVertically: dynamicTypeSize.isAccessibilitySize)
                    }
                    .containerRelativeFrame(.horizontal) { length, _ in
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

// MARK: - 精選

/// 精選's page (decision 37): a large cover and, beside it, the category, title, author, a line
/// of blurb and 查看作品, in white on the cover's colour, as 精簡閱讀卡片 draws it. A line the
/// source has nothing for is not drawn, so a 青空文庫 work with its generated cover and title
/// alone is still a full card. A shelf copy shows how far it is read in place of the blurb.
/// The text goes under the cover at accessibility text sizes.
struct HomeFeaturedCard: View {
    let content: HomeCardContent
    let coverWidth: CGFloat
    var stacksVertically = false

    @Environment(\.colorSchemeContrast) private var contrast
    /// The cover's average colour, once the cover has drawn.
    @State private var coverColor: CoverTint.RGB?

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    private var ground: Color {
        guard let coverColor else { return DSColor.coverTintPlaceholder }
        return CoverTint.background(for: coverColor, minimumContrast: contrast == .increased ? 7 : 4.5).color
    }

    var body: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpacing.lg))
        layout {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .environment(\.coverImageObserver, { image in
                    Task {
                        let color = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                        if color != coverColor { coverColor = color }
                    }
                })
            text
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: coverSize.height + DSSpacing.lg * 2, alignment: .topLeading)
        .background(ground, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .animation(DSAnimation.standard, value: coverColor)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if let category = content.category {
                Text(category)
                    .font(DSFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Text(content.title)
                .font(DSFont.title3.weight(.bold))
                .lineLimit(3)
            if !content.author.isEmpty {
                Text(content.author)
                    .font(DSFont.subheadline)
                    .lineLimit(1)
            }
            if let blurb = content.blurb {
                Text(blurb)
                    .font(DSFont.footnote)
                    .lineLimit(2)
                    .padding(.top, DSSpacing.xxs)
            } else if let detail = content.detail {
                Text(detail)
                    .font(DSFont.footnote)
                    .lineLimit(1)
            }
            if let progress = content.progress {
                HomeProgressBar(progress: progress)
                    .clipShape(Capsule())
            }
            Spacer(minLength: DSSpacing.md)
            // The card is the button (one VoiceOver stop, which opens the work); this says so.
            Text(localized("查看作品"))
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(ground)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)
                .background(DSColor.textOnAccent, in: Capsule())
                .accessibilityHidden(true)
        }
        .foregroundStyle(DSColor.textOnAccent)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: stacksVertically ? nil : coverSize.height, alignment: .topLeading)
    }
}

// MARK: - 精簡閱讀卡片

/// What a shelf copy's ••• offers on 精簡閱讀卡片 (5d-3c, decision 20).
struct HomeBookActions {
    /// 從繼續閱讀移除; nil outside 繼續閱讀.
    var removeFromContinueReading: ((ReadingBook) -> Void)?
    let markFinished: (ReadingBook) -> Void
}

/// One item of a card's ••• menu, also one of its VoiceOver actions.
struct HomeCardMenuItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let perform: () -> Void

    /// A shelf copy's items: 從繼續閱讀移除 in 繼續閱讀, and 標記為已讀完 unless it is finished.
    /// Nothing for another source's book, so it has no •••.
    static func items(for card: HomeCardContent, actions: HomeBookActions?) -> [HomeCardMenuItem] {
        guard let actions, let book = card.shelfBook else { return [] }
        var items: [HomeCardMenuItem] = []
        if let remove = actions.removeFromContinueReading {
            items.append(HomeCardMenuItem(id: "removeFromContinueReading", title: localized("從繼續閱讀移除"),
                                          symbol: "minus.circle", perform: { remove(book) }))
        }
        if book.currentPosition < 0.99 {
            items.append(HomeCardMenuItem(id: "markFinished", title: localized("標記為已讀完"),
                                          symbol: "checkmark.circle", perform: { actions.markFinished(book) }))
        }
        return items
    }
}

/// The ••• at a card's trailing bottom, as large as a tap target.
struct HomeCardMenuButton: View {
    let card: HomeCardContent
    let items: [HomeCardMenuItem]

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(item.title, systemImage: item.symbol, action: item.perform)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textOnAccent)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("更多"))
        .accessibilityIdentifier("home.card.more.\(card.id.instance.type.rawValue).\(card.id.item)")
    }
}

/// A small cover and, beside it, the title, author and kind・progress in white on the
/// cover's main colour, darkened until white text on it is legible (4.5:1, 7:1 with
/// 增加對比). All the text is white: a dimmed line would fall under that contrast. The text goes under the cover at accessibility text sizes.
struct HomeCompactReadingCard: View {
    let content: HomeCardContent
    let coverWidth: CGFloat
    var stacksVertically = false
    /// Keeps the trailing bottom clear for the ••• drawn over the card.
    var reservesMenuSpace = false

    @Environment(\.colorSchemeContrast) private var contrast
    /// The cover's average colour, once the cover has drawn.
    @State private var coverColor: CoverTint.RGB?

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    private var ground: Color {
        guard let coverColor else { return DSColor.coverTintPlaceholder }
        return CoverTint.background(for: coverColor, minimumContrast: contrast == .increased ? 7 : 4.5).color
    }

    var body: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpacing.md))
        layout {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .environment(\.coverImageObserver, { image in
                    Task {
                        let color = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                        if color != coverColor { coverColor = color }
                    }
                })
            text
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, minHeight: coverSize.height + DSSpacing.md * 2, alignment: .topLeading)
        .background(ground, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .animation(DSAnimation.standard, value: coverColor)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Text(content.title)
                .font(DSFont.headline)
                .lineLimit(2)
            if !content.author.isEmpty {
                Text(content.author)
                    .font(DSFont.subheadline)
                    .lineLimit(1)
            }
            Spacer(minLength: DSSpacing.sm)
            Text(content.kindAndDetail)
                .font(DSFont.caption)
                .lineLimit(1)
                .padding(.trailing, reservesMenuSpace && !stacksVertically ? DSLayout.minimumTapTarget - DSSpacing.md : 0)
                .padding(.bottom, reservesMenuSpace && stacksVertically ? DSLayout.minimumTapTarget - DSSpacing.md : 0)
        }
        .foregroundStyle(DSColor.textOnAccent)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: stacksVertically ? nil : coverSize.height, alignment: .topLeading)
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
                    HomeRankBadge(rank: rank)
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

#if DEBUG
/// 精選's preview cards: a book-source book with everything, and a bundled Gutenberg book with a
/// title, an author and a generated cover, nothing else.
@MainActor
private func featuredPreviewCards() -> [HomeCardContent] {
    var source = BookSource()
    source.bookSourceUrl = "https://source.example"
    let book = OnlineBook(name: "宿命之環", author: "愛潛水的烏賊",
                          intro: "灰霧之上，命運的環一圈圈收緊；一個從夢裡醒來的人，發現自己的日子已經被寫好了。",
                          coverUrl: "", bookUrl: "https://source.example/book/1", tocUrl: "", wordCount: "",
                          lastChapter: "", kind: "玄幻,連載", sourceId: source.id, sourceName: "S")
    let entries: [CollectionEntry] = [
        CollectionEntry.onlineBook(book, source: source),
        CollectionEntry.bundledGutenberg(PublicLibraryCollection.all[0].books[0]),
    ]
    return entries.compactMap { HomeCardContent($0, status: { _ in nil }, shelfBooks: [:]) }
}

#Preview("精選，資料齊全與最少") {
    let cards = featuredPreviewCards()
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            ForEach(cards) { card in
                HomeFeaturedCard(content: card, coverWidth: DSLayout.homeFeaturedCoverWidth)
            }
            HomeFeaturedCard(content: cards[0], coverWidth: DSLayout.homeFeaturedCoverWidth, stacksVertically: true)
                .environment(\.dynamicTypeSize, .accessibility2)
        }
        .padding(DSSpacing.lg)
    }
}
#endif

/// A rank in a small square: white on red, teal and orange for the top three, grey for
/// the rest: 圖文資訊清單's ranks (5d-3), as custom pages' rankings had them.
struct HomeRankBadge: View {
    let rank: Int

    @ScaledMetric(relativeTo: .caption) private var side = DSLayout.homeRankBadgeSize

    private var fill: Color? {
        switch rank {
        case 1: DSColor.rankFirst
        case 2: DSColor.rankSecond
        case 3: DSColor.rankThird
        default: nil
        }
    }

    var body: some View {
        Text(rank.formatted())
            .font(DSFont.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(fill == nil ? DSColor.textSecondary : DSColor.textOnAccent)
            .padding(.horizontal, DSSpacing.xs)
            .frame(minWidth: side, minHeight: side)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(fill ?? DSColor.neutralControlFill)
            )
    }
}
