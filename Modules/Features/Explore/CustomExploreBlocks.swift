import SwiftUI

// MARK: - A block of a custom explore page

/// One block of a custom explore page, in the layout its component chose. Every block
/// but the waterfall sits on a card under its title, the title being the link to the
/// category's full list; the waterfall's books are cards of their own.
struct CustomExploreBlockView: View {
    let block: CustomExplorePageModel.Block
    let waterfallPaging: CustomExplorePageModel.WaterfallPaging
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        if let section = block.sections.first {
            switch block.component.kind {
            case .featuredCards:
                CustomExploreShelfBlock(block: block, section: section, showsText: true, onLoad: onLoad, onRetry: onRetry)
            case .carousel:
                CustomExploreShelfBlock(block: block, section: section, showsText: false, onLoad: onLoad, onRetry: onRetry)
            case .ranking:
                CustomExploreRankingBlock(block: block, section: section, onLoad: onLoad, onRetry: onRetry)
            case .grid:
                CustomExploreGridBlock(block: block, section: section, onLoad: onLoad, onRetry: onRetry)
            case .pagedRanking:
                CustomExploreCard {
                    DiscoverSectionHeader(section: section, source: block.source, title: block.component.displayTitle)
                        .padding(.horizontal, DSSpacing.lg)
                    CustomExplorePagedRanking(section: section, onRetry: { onRetry(section.id) })
                }
                .task { onLoad(section.id) }
            case .multiCategoryRanking:
                CustomExploreMultiRankingBlock(block: block, onLoad: onLoad, onRetry: onRetry)
            case .waterfall:
                CustomExploreWaterfallBlock(
                    block: block,
                    section: section,
                    paging: waterfallPaging,
                    onLoad: onLoad,
                    onRetry: onRetry,
                    onLoadMore: onLoadMore
                )
            }
        } else {
            // The source was deleted, or a category no longer parses.
            CustomExploreCard {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(block.component.displayTitle)
                        .font(DSFont.title3.weight(.bold))
                        .foregroundStyle(DSColor.textPrimary)
                    Label(localized("來源配置已被刪除"), systemImage: "exclamationmark.triangle")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                .padding(.horizontal, DSSpacing.lg)
            }
        }
    }
}

/// The card a block sits on. Content runs edge to edge, so rows that scroll sideways
/// reach the card's sides; each piece pads itself.
private struct CustomExploreCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md, content: content)
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .interfaceCardSurface(in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
    }
}

/// A book with its place in its category — its rank, or its turn round the waterfall's
/// columns.
private struct CustomExploreEntry: Identifiable {
    let index: Int
    let display: DiscoverBookDisplay
    var id: UUID { display.id }
}

// MARK: - 推薦卡片 and 左右滑動

/// A row of covers that swipes sideways — 推薦卡片 with each book's title and intro under
/// its cover, 左右滑動 with the covers alone.
private struct CustomExploreShelfBlock: View {
    let block: CustomExplorePageModel.Block
    let section: DiscoverShowcaseSection
    let showsText: Bool
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    /// 探索設定's 橫滑展示數; 0 shows the whole first page.
    @AppStorage(ExploreSettings.shelfBookCountKey)
    private var shelfBookCount = ExploreSettings.defaultShelfBookCount

    private var books: [DiscoverBookDisplay] {
        shelfBookCount > 0 ? Array(section.books.prefix(shelfBookCount)) : section.books
    }

    var body: some View {
        CustomExploreCard {
            DiscoverSectionHeader(section: section, source: block.source, title: block.component.displayTitle)
                .padding(.horizontal, DSSpacing.lg)
            if section.books.isEmpty {
                DiscoverSectionPlaceholder(section: section, onRetry: { onRetry(section.id) })
                    .frame(height: DSLayout.customExploreCardCoverHeight)
                    .padding(.horizontal, DSSpacing.lg)
            } else {
                ScrollView(.horizontal) {
                    // Every card is the same height (its text lines reserve their space),
                    // so building them lazily cannot change the row's height.
                    LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                        ForEach(books) { display in
                            NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                                card(display)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
        .task { onLoad(section.id) }
    }

    @ViewBuilder
    private func card(_ display: DiscoverBookDisplay) -> some View {
        let cover = DiscoverCover(
            display: display,
            section: section,
            size: CGSize(width: DSLayout.customExploreCardCoverWidth, height: DSLayout.customExploreCardCoverHeight)
        )
        if showsText {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                cover
                Text(display.book.name)
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1, reservesSpace: true)
                Text(display.intro.isEmpty ? display.book.author : display.intro)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1, reservesSpace: true)
            }
            .frame(width: DSLayout.customExploreCardCoverWidth, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
        } else {
            // The cover is hidden from VoiceOver; the link reads the book instead.
            cover
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(display.book.name)
                .accessibilityValue(display.isAudiobook ? localized("有聲書") : display.book.author)
        }
    }
}

// MARK: - 排行榜

/// The top five as a list, 顯示全部 for the top ten.
private struct CustomExploreRankingBlock: View {
    let block: CustomExplorePageModel.Block
    let section: DiscoverShowcaseSection
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    private static let collapsedCount = 5
    private static let expandedCount = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var books: [DiscoverBookDisplay] {
        Array(section.books.prefix(isExpanded ? Self.expandedCount : Self.collapsedCount))
    }

    var body: some View {
        CustomExploreCard {
            DiscoverSectionHeader(section: section, source: block.source, title: block.component.displayTitle)
                .padding(.horizontal, DSSpacing.lg)
            if section.books.isEmpty {
                DiscoverSectionPlaceholder(section: section, onRetry: { onRetry(section.id) })
                    .frame(height: DSLayout.discoverRowCoverHeight * 2)
                    .padding(.horizontal, DSSpacing.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, display in
                        NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                            CustomExploreRankedRow(rank: index + 1, display: display, section: section, badgeLeads: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                if section.books.count > Self.collapsedCount {
                    Button {
                        withAnimation(reduceMotion ? nil : DSAnimation.standard) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: DSSpacing.xs) {
                            Text(isExpanded ? localized("收起") : localized("顯示全部"))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(DSFont.caption.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.accent)
                        .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { onLoad(section.id) }
    }
}

/// A ranked book: its rank badge, cover, title, author and intro — the badge before the
/// cover in 排行榜, after the text in the paged rankings.
private struct CustomExploreRankedRow: View {
    let rank: Int
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection
    let badgeLeads: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            if badgeLeads {
                CustomExploreRankBadge(rank: rank)
            }
            DiscoverCover(
                display: display,
                section: section,
                size: CGSize(width: DSLayout.discoverRowCoverWidth, height: DSLayout.discoverRowCoverHeight)
            )
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(display.book.name)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                if !display.book.author.isEmpty {
                    Text(display.book.author)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
                if !display.intro.isEmpty {
                    Text(display.intro)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
                // The source's own tags (连载中,9.1,玄幻), where the list has room.
                if badgeLeads, !display.book.kind.isEmpty {
                    Text(display.book.kind)
                        .font(DSFont.caption2)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, DSLayout.titleTagHorizontalPadding)
                        .padding(.vertical, DSLayout.titleTagVerticalPadding)
                        .background(
                            RoundedRectangle(cornerRadius: DSRadius.titleTag, style: .continuous)
                                .fill(DSColor.neutralControlFill)
                        )
                        .padding(.top, DSSpacing.xxs)
                }
            }
            Spacer(minLength: 0)
            if !badgeLeads {
                CustomExploreRankBadge(rank: rank)
            }
        }
        .padding(.vertical, DSSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
    }
}

/// A rank in a small square: white on red, teal and orange for the top three, grey for
/// the rest.
private struct CustomExploreRankBadge: View {
    let rank: Int

    @ScaledMetric(relativeTo: .caption) private var side = DSLayout.customExploreRankBadgeSize

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

// MARK: - 宮格

/// Two rows of covers with their titles — five to a row on a phone.
private struct CustomExploreGridBlock: View {
    let block: CustomExplorePageModel.Block
    let section: DiscoverShowcaseSection
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Fewer, wider cells at accessibility text sizes, so a title still has room.
    private var columnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return 3 }
        return horizontalSizeClass == .regular ? 8 : 5
    }

    var body: some View {
        CustomExploreCard {
            DiscoverSectionHeader(section: section, source: block.source, title: block.component.displayTitle)
                .padding(.horizontal, DSSpacing.lg)
            if section.books.isEmpty {
                DiscoverSectionPlaceholder(section: section, onRetry: { onRetry(section.id) })
                    .frame(height: DSLayout.customExploreCardCoverHeight)
                    .padding(.horizontal, DSSpacing.lg)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: DSSpacing.sm, alignment: .top),
                        count: columnCount
                    ),
                    alignment: .leading,
                    spacing: DSSpacing.md
                ) {
                    ForEach(section.books.prefix(columnCount * 2)) { display in
                        NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                DiscoverCover(display: display, section: section, size: nil)
                                Text(display.book.name)
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
            }
        }
        .task { onLoad(section.id) }
    }
}

// MARK: - 網絡排行榜 and 多分類排行榜

/// One ranking in columns of four, paged sideways with the next column peeking in.
private struct CustomExplorePagedRanking: View {
    let section: DiscoverShowcaseSection
    let onRetry: () -> Void

    private static let rowsPerColumn = 4

    /// One row at the default text size: the cover plus `DSSpacing.sm` above and below.
    /// Every column reserves four, filled or not, so the row of columns keeps one height.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat =
        DSLayout.discoverRowCoverHeight + DSSpacing.sm * 2
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private struct Column: Identifiable {
        let id: Int
        let entries: [CustomExploreEntry]
    }

    private var columns: [Column] {
        stride(from: 0, to: section.books.count, by: Self.rowsPerColumn).map { start in
            let end = min(start + Self.rowsPerColumn, section.books.count)
            return Column(
                id: start,
                entries: (start..<end).map { CustomExploreEntry(index: $0, display: section.books[$0]) }
            )
        }
    }

    var body: some View {
        if section.books.isEmpty {
            DiscoverSectionPlaceholder(section: section, onRetry: onRetry)
                .frame(height: rowHeight * CGFloat(Self.rowsPerColumn))
                .padding(.horizontal, DSSpacing.lg)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                    ForEach(columns) { column in
                        VStack(spacing: 0) {
                            ForEach(column.entries) { entry in
                                NavigationLink(value: ExploreNavigationRoute.book(entry.display.book)) {
                                    CustomExploreRankedRow(
                                        rank: entry.index + 1,
                                        display: entry.display,
                                        section: section,
                                        badgeLeads: false
                                    )
                                    .frame(height: rowHeight)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: rowHeight * CGFloat(Self.rowsPerColumn), alignment: .top)
                        .clipped()
                        .containerRelativeFrame(
                            .horizontal,
                            count: horizontalSizeClass == .regular ? 2 : 1,
                            spacing: DSSpacing.lg
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.leading, DSSpacing.lg, for: .scrollContent)
            .contentMargins(.trailing, DSSpacing.lg + DSLayout.discoverChartPeek, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// Several rankings of one source behind tabs; each tab's ranking loads the first time
/// it is chosen.
private struct CustomExploreMultiRankingBlock: View {
    let block: CustomExplorePageModel.Block
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    @State private var selectedIndex = 0

    private var selected: DiscoverShowcaseSection? {
        block.sections.indices.contains(selectedIndex) ? block.sections[selectedIndex] : block.sections.first
    }

    var body: some View {
        CustomExploreCard {
            HStack(spacing: DSSpacing.xs) {
                ScrollView(.horizontal) {
                    HStack(spacing: DSSpacing.sm) {
                        ForEach(Array(block.sections.enumerated()), id: \.element.id) { index, section in
                            let isSelected = section.id == selected?.id
                            Button { selectedIndex = index } label: {
                                DSCapsuleLabel(
                                    title: section.title,
                                    isSelected: isSelected,
                                    onCard: true,
                                    minWidth: DSLayout.capsuleControlMinWidth
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                }
                .scrollIndicators(.hidden)
                if let selected, let source = block.source,
                   let reference = ExploreCategoryReference(source: source, item: selected.item) {
                    NavigationLink(value: ExploreNavigationRoute.sourceCategory(reference)) {
                        Image(systemName: "chevron.right")
                            .font(DSFont.subheadline.weight(.semibold))
                            .foregroundStyle(DSColor.textSecondary)
                            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, DSSpacing.sm)
                    .accessibilityLabel(localized("查看全部"))
                    .accessibilityValue(selected.title)
                }
            }
            if let selected {
                CustomExplorePagedRanking(section: selected, onRetry: { onRetry(selected.id) })
                    .task(id: selected.id) { onLoad(selected.id) }
            }
        }
    }
}

// MARK: - 錯位瀑布流

/// Cards in staggered columns — each as tall as its title and intro make it — that go on
/// loading pages as the reader reaches their bottom. Always the page's last block.
private struct CustomExploreWaterfallBlock: View {
    let block: CustomExplorePageModel.Block
    let section: DiscoverShowcaseSection
    let paging: CustomExplorePageModel.WaterfallPaging
    let onLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onLoadMore: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return 2 }
        return horizontalSizeClass == .regular ? 5 : 3
    }

    /// The books dealt round the columns, each with its place in the category.
    private var columns: [[CustomExploreEntry]] {
        var columns = Array(repeating: [CustomExploreEntry](), count: columnCount)
        for (index, display) in section.books.enumerated() {
            columns[index % columnCount].append(CustomExploreEntry(index: index, display: display))
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            DiscoverSectionHeader(section: section, source: block.source, title: block.component.displayTitle)
            if section.books.isEmpty {
                DiscoverSectionPlaceholder(section: section, onRetry: { onRetry(section.id) })
                    .frame(height: DSLayout.discoverShelfCoverHeight)
            } else {
                // Books go round the columns in order, so the first row reads across;
                // VoiceOver keeps that order too rather than reading a column at a time.
                HStack(alignment: .top, spacing: DSSpacing.sm) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        LazyVStack(spacing: DSSpacing.sm) {
                            ForEach(column) { entry in
                                NavigationLink(value: ExploreNavigationRoute.book(entry.display.book)) {
                                    CustomExploreWaterfallCard(display: entry.display, section: section)
                                }
                                .buttonStyle(.plain)
                                .accessibilitySortPriority(Double(-entry.index))
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                footer
            }
        }
        .task { onLoad(section.id) }
    }

    @ViewBuilder
    private var footer: some View {
        if paging.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
        } else if let reason = paging.errorReason {
            Button(action: onLoadMore) {
                VStack(spacing: DSSpacing.xs) {
                    Label(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.accent)
                    if !reason.isEmpty {
                        Text(reason)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if paging.hasMore {
            Color.clear
                .frame(height: 1)
                .onAppear(perform: onLoadMore)
        }
    }
}

/// A waterfall book: its cover the card's width, then title, author and intro.
private struct CustomExploreWaterfallCard: View {
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            DiscoverCover(display: display, section: section, size: nil)
            Text(display.book.name)
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !display.book.author.isEmpty {
                Text(display.book.author)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if !display.intro.isEmpty {
                Text(display.intro)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
    }
}
