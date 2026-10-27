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
// The maintainer, 2026-10-25, after Apple Books' store and home
// (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`):
// - 色帶書架: as Apple Books Japan's manga band, large covers alone under the header, all on
//   the first cover's colour from edge to edge (`HomeBandGround`). Since 2026-10-27 the
//   home's 頂部輪播圖 only, drawn when the row gives the band's colour (`bandCover`).
// - 大型封面書架: a row of larger covers with their titles, about two to a phone.
// - 一大四小: as Apple Books' Special Offers, a large cover and four small ones beside it, a
//   group at a time.
// - 橫向單排書架 ranked: as Apple Books' charts, each cover's rank beside its title.
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
    /// 呈現方式's gallery: the rows a layout read downwards shows (`HomeLayoutPreview`).
    var previewRows: Int?
    /// The 頂部輪播圖's colour, the first cover's: given, the cards are its band's large covers
    /// alone, whatever the layout, and the first one reports its colour here.
    var bandCover: Binding<CoverTint.RGB?>?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.publicLibraryCoverFrames) private var coverFrames
    @ScaledMetric(relativeTo: .subheadline) private var scaledRowCoverWidth = DSLayout.homeCardCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var compactCoverWidth = DSLayout.homeCompactCoverWidth
    @ScaledMetric(relativeTo: .headline) private var readingCoverWidth = DSLayout.homeReadingCardCoverWidth
    @ScaledMetric(relativeTo: .headline) private var listCoverWidth = DSLayout.homeListCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var compactReadingCoverWidth = DSLayout.homeCompactReadingCardCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var continueCardWidth = DSLayout.homeContinueCardWidth
    @ScaledMetric(relativeTo: .headline) private var featuredCoverWidth = DSLayout.homeFeaturedCoverWidth
    @ScaledMetric(relativeTo: .subheadline) private var scaledLargeCoverWidth = DSLayout.homeLargeCoverWidth
    @State private var gridWidth: CGFloat = 0

    /// Rows the grid shows, and books the list shows, when 查看全部 has the rest.
    private static let gridRows = 3
    private static let listCount = 5

    private var rowCoverWidth: CGFloat { min(scaledRowCoverWidth, DSLayout.homeCardCoverMaxWidth) }
    private var largeCoverWidth: CGFloat { min(scaledLargeCoverWidth, DSLayout.homeCardCoverMaxWidth) }
    private var style: HomeLayoutStyle { layout.drawnStyle(accessibilityTextSize: dynamicTypeSize.isAccessibilitySize) }

    var body: some View {
        Group {
            if let bandCover {
                band(cover: bandCover)
            } else {
                switch style {
                case .readingCard: readingCards
                case .compactReadingCard: compactReadingCards
                case .row: rail(coverWidth: rowCoverWidth, ranked: layout.showsRanks)
                case .multiRow: multiRow
                case .coverGrid: grid
                case .list: list
                case .featured: featured
                case .largeRow: rail(coverWidth: largeCoverWidth)
                case .heroGrid: heroGrid
                // A section of books is never offered a layout of lists (`HomeLayoutStyle.choices`);
                // a stored one draws the row every section can take, as an unknown layout does.
                case .collection, .categoryCards, .collageCards, .bannerCards: rail(coverWidth: rowCoverWidth)
                }
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

    // MARK: 橫向單排書架, 大型封面書架

    /// One row of covers with their titles; ranked, each rank beside its title.
    private func rail(coverWidth: CGFloat, ranked: Bool = false) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                // By position: a source can list one item twice.
                ForEach(cards.indices, id: \.self) { index in
                    if ranked {
                        button(index, in: cards, rank: index + 1) {
                            HomeRankedBookCard(content: cards[index], rank: index + 1, coverWidth: coverWidth)
                        }
                    } else {
                        button(index, in: cards) { HomeBookCard(content: cards[index], coverWidth: coverWidth) }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    // MARK: 頂部輪播圖

    /// Covers alone, larger than a row's; the first one's colour is the band's.
    private func band(cover: Binding<CoverTint.RGB?>) -> some View {
        let size = CGSize(width: DSLayout.homeBandCoverWidth,
                          height: DSLayout.homeBandCoverWidth / DSLayout.discoverCoverAspectRatio)
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(cards.indices, id: \.self) { index in
                    button(index, in: cards) { HomeCoverCard(content: cards[index], size: size) }
                        .environment(\.coverImageObserver, index == 0 ? Self.observer(reportingTo: cover) : nil)
                }
            }
            .scrollTargetLayout()
        }
        .modifier(HomeSidewaysScroll())
    }

    /// Takes the average colour of the image a cover draws, off the main thread.
    private static func observer(reportingTo cover: Binding<CoverTint.RGB?>) -> @MainActor (UIImage) -> Void {
        { image in
            Task {
                let color = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                if color != cover.wrappedValue { cover.wrappedValue = color }
            }
        }
    }

    // MARK: 一大四小

    /// Groups of five, a group at a time: the first cover large, the next four in two rows as
    /// tall as it beside it. A last group of fewer leaves its places empty.
    private var heroGrid: some View {
        let gap = DSSpacing.sm
        let large = CGSize(width: DSLayout.homeHeroCoverWidth,
                           height: DSLayout.homeHeroCoverWidth / DSLayout.discoverCoverAspectRatio)
        let smallHeight = (large.height - gap) / 2
        let small = CGSize(width: smallHeight * DSLayout.discoverCoverAspectRatio, height: smallHeight)
        let groups = stride(from: 0, to: cards.count, by: 5).map { Array($0..<min($0 + 5, cards.count)) }
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(groups, id: \.self) { group in
                    HStack(alignment: .top, spacing: gap) {
                        button(group[0], in: cards) { HomeCoverCard(content: cards[group[0]], size: large) }
                        let rest = Array(group.dropFirst())
                        if !rest.isEmpty {
                            // Read across, then down, as the covers are drawn.
                            Grid(alignment: .topLeading, horizontalSpacing: gap, verticalSpacing: gap) {
                                ForEach(stride(from: 0, to: rest.count, by: 2).map { $0 }, id: \.self) { start in
                                    GridRow {
                                        ForEach(rest[start..<min(start + 2, rest.count)], id: \.self) { index in
                                            button(index, in: cards) { HomeCoverCard(content: cards[index], size: small) }
                                        }
                                    }
                                }
                            }
                        }
                    }
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
        let stacks = dynamicTypeSize.isAccessibilitySize
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    let menu = HomeCardMenuItem.items(for: card, actions: bookActions)
                    button(index, in: cards, menu: menu) {
                        HomeCompactReadingCard(content: card, coverWidth: compactReadingCoverWidth,
                                               stacksVertically: stacks, reservesMenuSpace: !menu.isEmpty)
                    }
                    // Beside the card's button, not in it: a menu inside a button is not reachable.
                    // Centred on the trailing edge, as Apple Books' Continue card has it.
                    .overlay(alignment: stacks ? .bottomTrailing : .trailing) {
                        if !menu.isEmpty {
                            HomeCardMenuButton(card: card, items: menu)
                                .padding(.trailing, DSSpacing.xxs)
                        }
                    }
                    // Apple Books' width, the next card past it; the whole width, less a peek,
                    // when the text goes under the cover at accessibility sizes.
                    .containerRelativeFrame(.horizontal) { length, _ in
                        guard stacks else { return min(continueCardWidth, length) }
                        return max(0, length - (cards.count > 1 ? DSLayout.homeReadingCardPeek + DSSpacing.lg : 0))
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
                    let menu = HomeCardMenuItem.items(for: card, actions: bookActions)
                    button(index, in: cards, menu: menu, value: card.featuredAccessibilityValue) {
                        HomeFeaturedCard(content: card, coverWidth: featuredCoverWidth,
                                         stacksVertically: dynamicTypeSize.isAccessibilitySize,
                                         reservesMenuSpace: !menu.isEmpty)
                    }
                    // Beside the card's button, as 精簡閱讀卡片 has it: a shelf copy's •••.
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
        let rows = previewRows ?? (hasShowAll ? Self.gridRows : nil)
        let shown = rows.map { Array(cards.prefix(count * $0)) } ?? cards
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
        let count = previewRows ?? (hasShowAll ? Self.listCount : nil)
        let shown = count.map { Array(cards.prefix($0)) } ?? cards
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
struct HomeSidewaysScroll: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
    }
}

/// A cover alone, for the layouts that draw no text with it (頂部輪播圖, 一大四小); VoiceOver
/// reads the card's label all the same. A shelf copy part read shows how far along its bottom.
struct HomeCoverCard: View {
    let content: HomeCardContent
    let size: CGSize

    var body: some View {
        HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: size)
            .overlay(alignment: .bottom) {
                if let progress = content.progress { HomeProgressBar(progress: progress) }
            }
            .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
            .contentShape(Rectangle())
    }
}

/// The 頂部輪播圖's band: the first cover's colour from edge to edge, under the section's header
/// and covers, and up behind the bars and the status bar (`DSLayout.homeCarouselBleed`); the
/// placeholder grey until that cover has drawn. Darkened until the header's line, the cover's
/// hue made light (`line(for:)`), reads at 4.5:1 on it (7:1 with 增加對比), so the header's white
/// does too, as 精簡閱讀卡片's ground is, and the bar's 探索 over it. Decoration: VoiceOver
/// reads nothing of it. Inactive, it draws nothing, and the row keeps its identity as the band
/// comes and goes.
struct HomeBandGround: ViewModifier {
    let cover: CoverTint.RGB?
    var isActive = true

    @Environment(\.colorSchemeContrast) private var contrast

    /// The header's line under the section's name.
    static func line(for cover: CoverTint.RGB?) -> CoverTint.RGB {
        CoverTint.lightTint(for: cover ?? CoverTint.placeholder)
    }

    /// Also behind the header on its own, which its long press lifts out of the band.
    static func ground(for cover: CoverTint.RGB?, contrast: ColorSchemeContrast) -> Color {
        guard let cover else { return DSColor.coverTintPlaceholder }
        return CoverTint.background(for: cover, under: line(for: cover),
                                    minimumContrast: contrast == .increased ? 7 : 4.5).color
    }

    func body(content: Content) -> some View {
        content
            .padding(.vertical, isActive ? DSSpacing.xl : 0)
            .frame(maxWidth: isActive ? .infinity : nil, alignment: .leading)
            .background {
                (isActive ? Self.ground(for: cover, contrast: contrast) : .clear)
                    .padding(.top, isActive ? -DSLayout.homeCarouselBleed : 0)
            }
            .animation(DSAnimation.standard, value: cover)
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
            if let series = content.series {
                Text(series)
                    .font(DSFont.caption)
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
    /// Keeps the trailing bottom clear for a shelf copy's ••• drawn over the card.
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
            if let series = content.series {
                Text(series)
                    .font(DSFont.caption)
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
                .background(DSColor.textOnFixedFill, in: Capsule())
                .accessibilityHidden(true)
                .padding(.trailing, reservesMenuSpace && !stacksVertically ? DSLayout.minimumTapTarget - DSSpacing.lg : 0)
                .padding(.bottom, reservesMenuSpace && stacksVertically ? DSLayout.minimumTapTarget - DSSpacing.lg : 0)
        }
        .foregroundStyle(DSColor.textOnFixedFill)
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
                .foregroundStyle(DSColor.textOnFixedFill)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("更多"))
        .accessibilityIdentifier("home.card.more.\(card.id.instance.type.rawValue).\(card.id.item)")
    }
}

/// Apple Books' Continue card, measured on a 440pt phone: a 40×60 cover inset 10, then the
/// title (two lines), author and kind・progress in 15pt, centred against the cover. The title
/// and author are white; the kind line is the cover's hue made light. The ground is the cover's
/// main colour, darkened until that line reads at 4.5:1 (7:1 with 增加對比), so white does too.
/// The text goes under the cover at accessibility text sizes.
struct HomeCompactReadingCard: View {
    let content: HomeCardContent
    let coverWidth: CGFloat
    var stacksVertically = false
    /// Keeps the trailing edge clear for the ••• drawn over the card.
    var reservesMenuSpace = false

    @Environment(\.colorSchemeContrast) private var contrast
    /// The cover's average colour, once the cover has drawn.
    @State private var coverColor: CoverTint.RGB?

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    /// The kind line's colour; the placeholder ground's grey until the cover has drawn.
    private var line: CoverTint.RGB {
        CoverTint.lightTint(for: coverColor ?? CoverTint.placeholder)
    }

    private var ground: Color {
        guard let coverColor else { return DSColor.coverTintPlaceholder }
        return CoverTint.background(for: coverColor, under: line, minimumContrast: contrast == .increased ? 7 : 4.5).color
    }

    var body: some View {
        let inset = DSLayout.homeContinueCardInset
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.md))
            : AnyLayout(HStackLayout(alignment: .center, spacing: inset))
        layout {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .environment(\.coverImageObserver, { image in
                    Task {
                        let color = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                        if color != coverColor { coverColor = color }
                    }
                })
                // The cover and its inset set the card's height; the text centres against it
                // and may run into the inset, as Apple Books' four lines do.
                .padding(.vertical, stacksVertically ? 0 : inset)
            text
        }
        .padding(.horizontal, inset)
        .padding(.vertical, stacksVertically ? inset : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ground, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .animation(DSAnimation.standard, value: coverColor)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.title)
                .font(DSFont.subheadline.weight(.semibold).leading(.tight))
                .lineLimit(2)
            if !content.author.isEmpty {
                Text(content.author)
                    .font(DSFont.subheadline.leading(.tight))
                    .lineLimit(1)
            }
            Text(content.kindAndDetail)
                .font(DSFont.subheadline.leading(.tight))
                .foregroundStyle(line.color)
                .lineLimit(1)
        }
        .foregroundStyle(DSColor.textOnFixedFill)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, reservesMenuSpace && !stacksVertically ? DSLayout.minimumTapTarget : 0)
        .padding(.bottom, reservesMenuSpace && stacksVertically ? DSLayout.minimumTapTarget - DSSpacing.md : 0)
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
                if let series = content.series {
                    Text(series)
                        .font(DSFont.caption)
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

// MARK: - 橫向單排書架, ranked

/// A row's card with its rank, as Apple Books' charts: the cover, then the rank beside the title
/// and author, in 圖文資訊清單's badge.
struct HomeRankedBookCard: View {
    let content: HomeCardContent
    let rank: Int
    let coverWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author,
                          size: CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio))
                .overlay(alignment: .bottom) {
                    if let progress = content.progress { HomeProgressBar(progress: progress) }
                }
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .padding(.bottom, DSSpacing.sm)
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                HomeRankBadge(rank: rank)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
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
                }
                .multilineTextAlignment(.leading)
            }
        }
        .frame(width: coverWidth, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

#Preview("每種呈現方式") {
    let cards = (0..<8).map(HomeCardContent.placeholder)
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            ForEach(HomeLayoutStyle.allCases) { style in
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    Text(localized(style.titleKey)).font(DSFont.title2.weight(.bold)).padding(.horizontal, DSSpacing.lg)
                    HomeSectionCards(layout: HomeSectionLayout(style: style, ranked: style.canShowRanks), cards: cards,
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

#Preview("趨勢的系列，在作者下面") {
    // The same book twice, the second on the shelf; each its own item, as a row's cards are.
    let cards = [nil, CopyLookup.Status.onShelf].enumerated().compactMap { index, status in
        let record = SourceRecord(key: SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "trends"), item: "mistborn-\(index)"),
                                  title: "Mistborn: The Final Empire", authors: ["Brandon Sanderson"], language: "en",
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.viewOnly])
        let summary = WorkSummary(title: record.title, authors: record.authors, cover: .generated(seed: record.title),
                                  blurb: "A street thief learns she can burn metals, and joins a crew that means to end an empire.",
                                  language: "en", contentKind: .text, series: "Mistborn")
        return HomeCardContent(.item(record, summary, .bibliographic), status: { _ in status }, shelfBooks: [:])
    }
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            ForEach(HomeLayoutStyle.allCases) { style in
                HomeSectionCards(layout: HomeSectionLayout(style: style, ranked: style.canShowRanks), cards: cards,
                                 rowID: style.rawValue, hasShowAll: false, open: { _, _ in })
            }
        }
    }
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
            .foregroundStyle(fill == nil ? DSColor.textSecondary : DSColor.textOnFixedFill)
            .padding(.horizontal, DSSpacing.xs)
            .frame(minWidth: side, minHeight: side)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(fill ?? DSColor.neutralControlFill)
            )
    }
}
