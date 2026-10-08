import SwiftUI

// MARK: - Discover Showcase

/// The redesigned 發現 (Discover) showcase. Renders the *book source's own*
/// explore categories as stacked ranking sections — a horizontal cover carousel
/// for 推薦/精選 categories and a numbered list for 榜單/排行 categories.
///
/// The source owns the feed; this view only presents it faithfully (see
/// `docs/design.md` §10 — Discover archetype).
struct DiscoverShowcaseView: View {
    @ObservedObject var discover: DiscoverViewModel
    /// Opens a category that is a web page rather than a book list.
    var onOpenPage: ((String) -> Void)?

    /// Which categories are charts follows these words; read so a change redraws.
    @AppStorage(ExploreSettings.rankedKeywordsKey)
    private var rankedKeywords = ExploreSettings.encodeKeywords(ExploreSettings.defaultRankedKeywords)

    /// Categories that open a page (a source's `java.startBrowser` link).
    private var pageItems: [DiscoverCardItem] {
        discover.pageItems
    }

    var body: some View {
        let _ = rankedKeywords
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                if !discover.filters.isEmpty || (onOpenPage != nil && !pageItems.isEmpty) {
                    DiscoverControlsRow(
                        discover: discover,
                        pageItems: onOpenPage == nil ? [] : pageItems,
                        onOpenPage: { onOpenPage?($0) }
                    )
                }
                if discover.isLoadingItems && discover.sections.isEmpty {
                    loadingState
                } else if discover.sections.isEmpty {
                    DiscoverEmptyState(discover: discover)
                } else {
                    ForEach(discover.sections) { section in
                        if section.style == .ranked {
                            if section.id == firstRankedSectionId {
                                DiscoverRankedSectionsCarousel(
                                    sections: rankedSections,
                                    source: discover.selectedSource,
                                    onAppearLoad: { discover.loadSection($0) },
                                    onRetry: { discover.retrySection($0) }
                                )
                            }
                        } else {
                            DiscoverSectionView(
                                section: section,
                                source: discover.selectedSource,
                                onAppearLoad: { discover.loadSection(section.id) },
                                onRetry: { discover.retrySection(section.id) }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, DSSpacing.lg)
            .padding(.bottom, 120)
        }
        .softScrollEdges()
        .scrollDismissesKeyboard(.immediately)
        .refreshable { discover.reload(forceRefresh: true) }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, DSSpacing.xxl)
    }

    private var rankedSections: [DiscoverShowcaseSection] {
        discover.sections.filter { $0.style == .ranked }
    }

    private var firstRankedSectionId: UUID? {
        rankedSections.first?.id
    }
}

/// A source page with no categories to show, in either layout.
private struct DiscoverEmptyState: View {
    @ObservedObject var discover: DiscoverViewModel

    var body: some View {
        // When the source replied with a plain message instead of categories
        // (e.g. 「请先于【源变量】处填写共享Token」), show ITS words — the generic
        // copy would hide the one instruction the user needs.
        ContentUnavailableView {
            UnavailableLabel(localized("暫無發現內容"), systemImage: "sparkles")
        } description: {
            Text(
                discover.sourceNotice
                    ?? localized("此來源配置未回傳發現內容，可下拉重新整理或切換來源配置")
            ).foregroundStyle(DSColor.textSecondary)
        } actions: {
            // The source asked for a device id and got none. The toggle that fixes
            // it lives in 書源編輯 → 基本, which nobody looking at an empty 發現頁
            // will find — so offer it here. See `AndroidIdentityRecovery`.
            if discover.androidIdentityRepairSource != nil {
                Button(localized("提供裝置識別碼並重試")) {
                    discover.enableAndroidIdentityAndReload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Filters and page links

/// The source's own controls above its categories, in one scrolling row: each filter
/// it emits (线路、类型、频道、平台) as a menu of its options, then the categories that
/// open a web page. legado-E draws the same `select` kinds inline on its explore page.
private struct DiscoverControlsRow: View {
    @ObservedObject var discover: DiscoverViewModel
    let pageItems: [DiscoverCardItem]
    let onOpenPage: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(discover.filters) { filter in
                    filterMenu(filter)
                }
                ForEach(pageItems) { item in
                    Button {
                        if let url = item.actionURL { onOpenPage(url) }
                    } label: {
                        DSCapsuleLabel(title: item.title, trailingSystemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(localized("在瀏覽器中開啟"))
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.xs)
        }
        .scrollIndicators(.hidden)
    }

    /// Each filter reads 「線路：<chosen line>」, its name and its value together; one
    /// changed from its first option takes the accent, so the active filters stand out.
    private func filterMenu(_ filter: DiscoverFilter) -> some View {
        let isActive = filter.selected != filter.options.first
        let title = Self.filterTitle(filter.title)
        let value = Self.displayName(filter.selected)
        return Menu {
            Picker(title, selection: Binding(
                get: { filter.selected },
                set: { discover.selectFilter(filter, value: $0) }
            )) {
                ForEach(filter.options, id: \.self) { option in
                    Text(Self.displayName(option)).tag(option)
                }
            }
        } label: {
            DSCapsuleLabel(
                title: value.isEmpty ? title : String(format: localized("%@：%@"), title, value),
                trailingSystemImage: "chevron.down",
                isSelected: isActive
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    static func filterTitle(_ title: String) -> String {
        switch title {
        case "线路", "線路": localized("線路")
        case "类型", "類型": localized("類型")
        case "频道", "頻道": localized("頻道")
        case "平台": localized("平台")
        default: title
        }
    }

    static func displayName(_ value: String) -> String {
        guard value.hasPrefix("http") else { return value }
        return value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Section header

/// A section title in Apple Books' store style: the title itself is the link to the
/// category's full list, marked by a trailing chevron. A section with nothing to
/// list (still loading, empty, or no source) shows the bare title. A long press adds
/// the category to a custom explore page.
struct DiscoverSectionHeader: View {
    let section: DiscoverShowcaseSection
    let source: BookSource?
    /// What the header reads; the category's own title by default — a custom page's
    /// block can carry a title of its own.
    var title: String?

    private var reference: ExploreCategoryReference? {
        source.flatMap { ExploreCategoryReference(source: $0, item: section.item) }
    }

    private var destination: ExploreNavigationRoute? {
        reference.map(ExploreNavigationRoute.sourceCategory)
    }

    var body: some View {
        Group {
            if let destination, !section.books.isEmpty {
                NavigationLink(value: destination) {
                    titleLabel(showsChevron: true)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(localized("查看全部"))
            } else {
                titleLabel(showsChevron: false)
                    .frame(minHeight: DSLayout.minimumTapTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let reference {
                AddToCustomPageMenu(reference: reference)
            }
        }
    }

    private func titleLabel(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
            Text(title ?? section.title)
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Section phase states

/// Loading, empty and failed placeholders shared by shelves and chart columns.
struct DiscoverSectionPlaceholder: View {
    let section: DiscoverShowcaseSection
    let onRetry: () -> Void

    var body: some View {
        switch section.phase {
        case .failed:
            Button(action: onRetry) {
                VStack(spacing: DSSpacing.xs) {
                    Label(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.accent)
                    if let reason = section.errorReason, !reason.isEmpty {
                        Text(reason)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .loaded:
            Text(localized("暫無發現內容"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Featured shelf

/// A 推薦／精選 category as one of Apple Books' store shelves: a horizontal row of
/// covers with title and author, snapping to the cover edges. Loads its books lazily
/// the first time it scrolls on.
struct DiscoverSectionView: View {
    let section: DiscoverShowcaseSection
    let source: BookSource?
    let onAppearLoad: () -> Void
    let onRetry: () -> Void

    /// 探索設定's 橫滑展示數; 0 shows the whole first page.
    @AppStorage(ExploreSettings.shelfBookCountKey)
    private var shelfBookCount = ExploreSettings.defaultShelfBookCount

    private var shelfBooks: [DiscoverBookDisplay] {
        shelfBookCount > 0 ? Array(section.books.prefix(shelfBookCount)) : section.books
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            DiscoverSectionHeader(section: section, source: source)
                .padding(.horizontal, DSSpacing.lg)
            if section.books.isEmpty {
                DiscoverSectionPlaceholder(section: section, onRetry: onRetry)
                    .frame(height: DSLayout.discoverShelfCoverHeight)
                    .padding(.horizontal, DSSpacing.lg)
            } else {
                shelf
            }
        }
        .task { onAppearLoad() }
    }

    private var shelf: some View {
        ScrollView(.horizontal) {
            // Lazy is load-bearing: a featured category returns 20–50 books, and
            // building every card the moment the section scrolls on-screen is a
            // one-frame spike at each section boundary. Cards are fixed-height (see
            // DiscoverFeaturedCard), so lazily materializing them can't change the
            // shelf's height.
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(shelfBooks) { display in
                    NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                        DiscoverFeaturedCard(display: display, section: section)
                    }
                    .buttonStyle(.plain)
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

// MARK: - Charts

/// Every 榜單／排行 category as one row of chart columns, paged sideways like Apple
/// Books' Top Charts: each column is one ranking with its title and top entries,
/// and the next column peeks in from the edge.
private struct DiscoverRankedSectionsCarousel: View {
    let sections: [DiscoverShowcaseSection]
    let source: BookSource?
    let onAppearLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.lg) {
                ForEach(sections) { section in
                    DiscoverChartColumn(
                        section: section,
                        source: source,
                        onAppearLoad: { onAppearLoad(section.id) },
                        onRetry: { onRetry(section.id) }
                    )
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
        .scrollClipDisabled()
    }
}

private struct DiscoverChartColumn: View {
    let section: DiscoverShowcaseSection
    let source: BookSource?
    let onAppearLoad: () -> Void
    let onRetry: () -> Void

    /// Entries every column reserves, filled or not.
    ///
    /// The columns sit in a `LazyHStack` with `scrollClipDisabled`, so the row's
    /// height tracks only the columns built so far AND anything taller draws outside
    /// it: a full column next to an empty 「暫無發現內容」 one once rendered straight
    /// over the section below. Every column must therefore be the same height —
    /// `prefix` and the reserved height stay driven by this one value — 探索設定's
    /// 豎排展示數, the same for every column.
    @AppStorage(ExploreSettings.chartBookCountKey)
    private var reservedRows = ExploreSettings.defaultChartBookCount

    /// One chart row at default text size: the cover plus `DSSpacing.sm` above and
    /// below. `@ScaledMetric` keeps it in step with Dynamic Type instead of clipping.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat =
        DSLayout.discoverRowCoverHeight + DSSpacing.sm * 2

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            DiscoverSectionHeader(section: section, source: source)
            Group {
                if section.books.isEmpty {
                    DiscoverSectionPlaceholder(section: section, onRetry: onRetry)
                } else {
                    entries
                }
            }
            .frame(height: CGFloat(reservedRows) * rowHeight, alignment: .top)
            .clipped()
        }
        .task { onAppearLoad() }
    }

    private var entries: some View {
        let ranked = Array(section.books.prefix(reservedRows).enumerated())
        return VStack(spacing: 0) {
            ForEach(ranked, id: \.element.id) { index, display in
                if index > 0 {
                    Divider()
                        .padding(.leading, DSLayout.discoverRowCoverWidth + DSSpacing.md)
                }
                NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                    DiscoverBookRow(
                        rank: index + 1,
                        display: display,
                        section: section,
                        showsIntro: false
                    )
                    .frame(height: rowHeight)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Featured card (shelf item)

/// Rows read only precomputed `DiscoverBookDisplay` fields — no HTML stripping,
/// audiobook inference, or source lookups in `body` (each visible row re-renders
/// every time any section finishes loading; see `DiscoverBookDisplay`).
/// Whether a 探索 card may fall back to the user's 預設封面 library, and under
/// which key. Gated on 外觀主題 → 介面 → 預設封面 → 探索頁啟用預設封面, so the
/// bookshelf can use default covers without the discover page changing.
enum DiscoverDefaultCoverSeed {
    static func seed(for display: DiscoverBookDisplay) -> String? {
        guard GlobalSettings.shared.exploreUsesDefaultCover else { return nil }
        // Book URL first: two books can share a title, and the same book keeps
        // its picture across carousels this way.
        let url = display.book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? display.book.name : url
    }
}

/// A cover with its title and author under it. Both text lines reserve their space
/// so every card is the same height — the shelf is a `LazyHStack` whose height
/// tracks only the cards built so far, and it must not grow as more scroll in.
private struct DiscoverFeaturedCard: View {
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            DiscoverCover(
                display: display,
                section: section,
                size: CGSize(
                    width: DSLayout.discoverShelfCoverWidth,
                    height: DSLayout.discoverShelfCoverHeight
                )
            )
            .padding(.bottom, DSSpacing.xs)
            Text(display.book.name)
                .font(DSFont.footnote.weight(.medium))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text(display.book.author)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(1, reservesSpace: true)
        }
        .frame(width: DSLayout.discoverShelfCoverWidth, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
    }
}

// MARK: - Cover

/// A 探索 cover with the audiobook badge. Hidden from VoiceOver: the row or card it
/// sits in already reads the title, and the badge is spoken as the row's value.
struct DiscoverCover: View {
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection
    /// Its size; nil takes the width it is offered, at a cover's proportions.
    let size: CGSize?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
        Group {
            if let size {
                image.frame(width: size.width, height: size.height)
            } else {
                Color.clear
                    .aspectRatio(DSLayout.discoverCoverAspectRatio, contentMode: .fit)
                    .overlay { image }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if display.isAudiobook {
                AudiobookCoverBadge()
            }
        }
        .accessibilityHidden(true)
    }

    private var image: some View {
        BookCoverImage(
            coverURL: display.book.coverUrl,
            title: display.book.name,
            author: display.book.author,
            sourceBaseURL: section.coverBaseURL,
            sourceHeaders: section.coverHeaders,
            defaultCoverSeed: DiscoverDefaultCoverSeed.seed(for: display)
        )
    }
}

// MARK: - Book row

/// A chart or 查看全部 row: cover, the rank in plain bold numerals when the category
/// is a ranking (Apple Books' charts colour none of them), title and author, and the
/// description where there is room for it.
private struct DiscoverBookRow: View {
    let rank: Int?
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection
    let showsIntro: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DSSpacing.md) {
            DiscoverCover(
                display: display,
                section: section,
                size: CGSize(
                    width: DSLayout.discoverRowCoverWidth,
                    height: DSLayout.discoverRowCoverHeight
                )
            )
            if let rank {
                Text(rank.formatted())
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
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
                if showsIntro, !display.intro.isEmpty {
                    Text(display.intro)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(display.isAudiobook ? localized("有聲書") : "")
    }
}

// MARK: - Category detail ("查看全部")

/// Full list of one explore category, reached from a section's 查看全部 link.
struct DiscoverCategoryView: View {
    let section: DiscoverShowcaseSection
    let source: BookSource

    var body: some View {
        DiscoverCategoryBookList(section: section, source: source)
            .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
            .pageBackgroundToolbar(for: .explore)
            .navigationTitle(section.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if let reference = ExploreCategoryReference(source: source, item: section.item) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            AddToCustomPageItems(reference: reference)
                        } label: {
                            Label(localized("加入自訂頁"), systemImage: "rectangle.stack.badge.plus")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
    }
}

// MARK: - Category book list

/// One category's books as a list of cards, a page more each time the reader nears the
/// end — the body of 查看全部, and of a source's page in the list layout.
struct DiscoverCategoryBookList: View {
    let section: DiscoverShowcaseSection
    let source: BookSource
    /// Pull to refresh, where the page around the list offers it.
    var onRefresh: (() -> Void)?

    @State private var books: [DiscoverBookDisplay]
    @State private var nextPage: Int
    @State private var hasMorePages = true
    @State private var isLoadingMore = false
    @State private var loadMoreErrorReason: String?

    init(
        section: DiscoverShowcaseSection,
        source: BookSource,
        onRefresh: (() -> Void)? = nil
    ) {
        self.section = section
        self.source = source
        self.onRefresh = onRefresh
        _books = State(initialValue: section.books)
        _nextPage = State(initialValue: section.books.isEmpty ? 1 : 2)
    }

    var body: some View {
        let list = ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, display in
                    if index > 0 {
                        Divider()
                            .padding(.leading, DSLayout.discoverRowCoverWidth + DSSpacing.md)
                    }
                    NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                        DiscoverBookRow(
                            rank: section.style == .ranked ? index + 1 : nil,
                            display: display,
                            section: section,
                            showsIntro: true
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index >= books.count - 5 {
                            loadMoreIfNeeded()
                        }
                    }
                }

                loadMoreFooter
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .overlay {
            if books.isEmpty, !hasMorePages, !isLoadingMore, loadMoreErrorReason == nil {
                ContentUnavailableView {
                    UnavailableLabel(localized("暫無發現內容"), systemImage: "books.vertical")
                }
            }
        }
        .softScrollEdges()
        .scrollDismissesKeyboard(.immediately)

        if let onRefresh {
            list.refreshable { onRefresh() }
        } else {
            list
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
        } else if loadMoreErrorReason != nil {
            Button {
                loadMoreIfNeeded()
            } label: {
                VStack(spacing: DSSpacing.xs) {
                    Label(localized("載入失敗，點按重試"), systemImage: "arrow.clockwise")
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.accent)

                    if let reason = loadMoreErrorReason, !reason.isEmpty {
                        Text(reason)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.md)
            }
            .buttonStyle(.plain)
        } else if hasMorePages {
            Color.clear
                .frame(height: 1)
                .onAppear(perform: loadMoreIfNeeded)
        }
    }

    private func loadMoreIfNeeded() {
        guard hasMorePages, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreErrorReason = nil
        let page = nextPage
        let existing = books.map(\.book)

        Task {
            do {
                let loaded = try await BookSourceFetcher.shared.discoverBooks(
                    from: section.item.raw,
                    page: page,
                    in: source
                )
                let additional = DiscoverViewModel.uniqueAdditionalBooks(loaded, existing: existing)
                let displays = await DiscoverViewModel.makeDisplays(additional, source: source)
                applyLoadedPage(displays, page: page)
            } catch {
                applyLoadMoreError((error as NSError).localizedDescription)
            }
        }
    }

    @MainActor
    private func applyLoadedPage(_ additional: [DiscoverBookDisplay], page: Int) {
        if additional.isEmpty {
            hasMorePages = false
        } else {
            books.append(contentsOf: additional)
            nextPage = page + 1
            hasMorePages = true
        }
        isLoadingMore = false
    }

    @MainActor
    private func applyLoadMoreError(_ reason: String) {
        loadMoreErrorReason = reason
        isLoadingMore = false
    }
}

// MARK: - List layout

/// A source's page as Legado lays it out (探索設定 › 書源頁佈局 › 列表): its filters and
/// page links, its categories as chips along the top, and the chosen category's books as
/// a list of cards below.
struct DiscoverListLayoutView: View {
    @ObservedObject var discover: DiscoverViewModel
    /// Opens a category that is a web page rather than a book list.
    var onOpenPage: ((String) -> Void)?

    /// The chosen category, by the key that survives a reload; the first until one is chosen.
    @State private var selectedKey: String?

    private var selectedSection: DiscoverShowcaseSection? {
        discover.sections.first { $0.item.stableKey == selectedKey } ?? discover.sections.first
    }

    private var pageItems: [DiscoverCardItem] {
        onOpenPage == nil ? [] : discover.pageItems
    }

    var body: some View {
        VStack(spacing: 0) {
            if !discover.filters.isEmpty || !pageItems.isEmpty {
                DiscoverControlsRow(
                    discover: discover,
                    pageItems: pageItems,
                    onOpenPage: { onOpenPage?($0) }
                )
                .padding(.top, DSSpacing.sm)
            }
            if !discover.sections.isEmpty {
                categoryChips
            }
            if discover.isLoadingItems && discover.sections.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let section = selectedSection, let source = discover.selectedSource {
                DiscoverCategoryBookList(
                    section: section,
                    source: source,
                    onRefresh: { discover.reload(forceRefresh: true) }
                )
                // A reload rebuilds the sections; their books start again from page one.
                .id(section.id)
            } else {
                ScrollView {
                    DiscoverEmptyState(discover: discover)
                }
                .refreshable { discover.reload(forceRefresh: true) }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(discover.sections) { section in
                    DSChip(
                        title: section.title,
                        isSelected: section.id == selectedSection?.id,
                        minWidth: DSLayout.capsuleControlMinWidth
                    ) {
                        selectedKey = section.item.stableKey
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Preview

#Preview {
    var source = BookSource()
    source.bookSourceName = "範例來源配置"
    source.bookSourceUrl = "https://example.com"
    return NavigationStack {
        DiscoverShowcaseView(discover: DiscoverViewModel(source: source))
            .navigationTitle(source.bookSourceName)
            .toolbarTitleDisplayMode(.inline)
    }
}
