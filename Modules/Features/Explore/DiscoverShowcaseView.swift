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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                if discover.isLoadingItems && discover.sections.isEmpty {
                    loadingState
                } else if discover.sections.isEmpty {
                    emptyState
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

    private var emptyState: some View {
        ContentUnavailableView(
            localized("暫無發現內容"),
            systemImage: "sparkles",
            description: Text(localized("此書源未回傳發現內容，可下拉重新整理或切換書源"))
        )
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var rankedSections: [DiscoverShowcaseSection] {
        discover.sections.filter { $0.style == .ranked }
    }

    private var firstRankedSectionId: UUID? {
        rankedSections.first?.id
    }
}

// MARK: - Filter bar

/// Horizontal row of the source's own dropdown filters (线路 / 类型 / 频道 / 平台).
/// Each is a native `Menu` (design.md: 就地選擇 → Menu). Options come from the
/// source's `select` items, so the 平台 list reflects the per-mode cloud config.
private struct DiscoverFilterBar: View {
    @ObservedObject var discover: DiscoverViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(discover.filters) { filter in
                    Menu {
                        Picker(filter.title, selection: selectionBinding(for: filter)) {
                            ForEach(filter.options, id: \.self) { option in
                                Text(displayName(option)).tag(option)
                            }
                        }
                    } label: {
                        chip(for: filter)
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .background(DSColor.groupedBackground.opacity(0.001))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func selectionBinding(for filter: DiscoverFilter) -> Binding<String> {
        Binding(
            get: { filter.selected },
            set: { discover.selectFilter(filter, value: $0) }
        )
    }

    /// A compact, single-line filter pill with Apple's continuous (squircle)
    /// corners. When the filter sits on its default (first) option the pill stays
    /// neutral and shows the category name; once the reader picks another option it
    /// tints to the accent and shows that value, so the active filters read at a
    /// glance across the bar.
    private func chip(for filter: DiscoverFilter) -> some View {
        let isActive = filter.selected != filter.options.first
        let label = isActive ? displayName(filter.selected) : filterLabel(filter.title)
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return HStack(spacing: DSSpacing.xs) {
            Text(label)
                .font(DSFont.caption.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(DSFont.fixed(size: 9, weight: .semibold))
        }
        .foregroundColor(isActive ? DSColor.accent : DSColor.textPrimary)
        .padding(.horizontal, DSSpacing.sm + 2)
        .padding(.vertical, DSSpacing.xs + 2)
        .background(isActive ? DSColor.accent.opacity(0.15) : DSColor.surface)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isActive ? DSColor.accent.opacity(0.35) : DSColor.separator,
                lineWidth: 0.5
            )
        )
        .contentShape(shape)
    }

    private func filterLabel(_ title: String) -> String {
        switch title {
        case "线路", "線路":
            return localized("線路")
        case "类型", "類型":
            return localized("類型")
        case "频道", "頻道":
            return localized("頻道")
        case "平台":
            return localized("平台")
        default:
            return title
        }
    }

    /// 线路 values are server URLs — drop the scheme so the chip stays tidy.
    private func displayName(_ value: String) -> String {
        guard value.hasPrefix("http") else { return value }
        return value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Section

/// One showcase section. Loads its books lazily the first time it scrolls on.
private struct DiscoverSectionView: View {
    let section: DiscoverShowcaseSection
    let source: BookSource?
    let onAppearLoad: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            sectionBody
        }
        .task { onAppearLoad() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(DSFont.headline)
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DSSpacing.sm)
            if source != nil {
                NavigationLink(value: ExploreNavigationRoute.category(section.id)) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(localized("查看全部"))
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption2.weight(.semibold))
                    }
                    .font(DSFont.subheadline)
                    .foregroundColor(DSColor.textSecondary)
                }
                .disabled(section.books.isEmpty)
                .opacity(section.books.isEmpty ? 0 : 1)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private var sectionBody: some View {
        if !section.books.isEmpty {
            content
        } else {
            switch section.phase {
            case .failed:
                sectionFailed
            case .loaded:
                sectionEmpty
            case .idle, .loading:
                sectionLoading
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section.style {
        case .featured:
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy is load-bearing: a featured category returns 20–50 books,
                // and building every card the moment the section scrolls on-screen
                // is a one-frame spike at each section boundary — the page kept
                // dropping frames on vertical scroll even after all sections had
                // loaded. Cards are fixed-height (see DiscoverFeaturedCard), so
                // lazily materializing them can't change the carousel's height.
                LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(section.books) { display in
                        NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                            DiscoverFeaturedCard(display: display, section: section)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
            }
            .scrollClipDisabled()
        case .ranked:
            VStack(spacing: 0) {
                let ranked = Array(section.books.prefix(6).enumerated())
                ForEach(ranked, id: \.element.id) { index, display in
                    NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                        DiscoverRankedRow(rank: index + 1, display: display, section: section)
                    }
                    .buttonStyle(.plain)
                    if index < ranked.count - 1 {
                        Divider().padding(.leading, 88)
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    private var sectionLoading: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: section.style == .featured ? 170 : 120)
    }

    private var sectionEmpty: some View {
        Text(localized("暫無發現內容"))
            .font(DSFont.caption)
            .foregroundColor(DSColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, DSSpacing.lg)
            .padding(.horizontal, DSSpacing.lg)
    }

    private var sectionFailed: some View {
        Button(action: onRetry) {
            VStack(spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "arrow.clockwise")
                    Text(localized("載入失敗，點按重試"))
                }
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.accent)
                if let reason = section.errorReason, !reason.isEmpty {
                    Text(reason)
                        .font(DSFont.caption2)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, DSSpacing.lg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, DSSpacing.lg)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ranked sections carousel

private struct DiscoverRankedSectionsCarousel: View {
    let sections: [DiscoverShowcaseSection]
    let source: BookSource?
    let onAppearLoad: (UUID) -> Void
    let onRetry: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(sections) { section in
                    DiscoverRankedSummaryCard(
                        section: section,
                        source: source,
                        onAppearLoad: { onAppearLoad(section.id) },
                        onRetry: { onRetry(section.id) }
                    )
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
        .scrollClipDisabled()
    }
}

private struct DiscoverRankedSummaryCard: View {
    let section: DiscoverShowcaseSection
    let source: BookSource?
    let onAppearLoad: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            content
        }
        .padding(DSSpacing.md)
        .frame(width: 320, alignment: .topLeading)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                .strokeBorder(DSColor.separator, lineWidth: 0.5)
        }
        .task { onAppearLoad() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(DSFont.headline)
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DSSpacing.sm)
            if source != nil {
                NavigationLink(value: ExploreNavigationRoute.category(section.id)) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(localized("查看全部"))
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption2.weight(.semibold))
                    }
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                }
                .disabled(section.books.isEmpty)
                .opacity(section.books.isEmpty ? 0 : 1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !section.books.isEmpty {
            let ranked = Array(section.books.prefix(6).enumerated())
            VStack(spacing: 0) {
                ForEach(ranked, id: \.element.id) { index, display in
                    NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                        DiscoverRankedRow(rank: index + 1, display: display, section: section)
                    }
                    .buttonStyle(.plain)
                    if index < ranked.count - 1 {
                        Divider().padding(.leading, 88)
                    }
                }
            }
        } else {
            switch section.phase {
            case .failed:
                failed
            case .loaded:
                empty
            case .idle, .loading:
                loading
            }
        }
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: 120)
    }

    private var empty: some View {
        Text(localized("暫無發現內容"))
            .font(DSFont.caption)
            .foregroundColor(DSColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, DSSpacing.lg)
    }

    private var failed: some View {
        Button(action: onRetry) {
            VStack(spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "arrow.clockwise")
                    Text(localized("載入失敗，點按重試"))
                }
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.accent)
                if let reason = section.errorReason, !reason.isEmpty {
                    Text(reason)
                        .font(DSFont.caption2)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, DSSpacing.lg)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Featured card (horizontal carousel item)

/// Rows read only precomputed `DiscoverBookDisplay` fields — no HTML stripping,
/// audiobook inference, or source lookups in `body` (each visible row re-renders
/// every time any section finishes loading; see `DiscoverBookDisplay`).
private struct DiscoverFeaturedCard: View {
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookCoverImage(
                coverURL: display.book.coverUrl,
                title: display.book.name,
                sourceBaseURL: section.coverBaseURL,
                sourceHeaders: section.coverHeaders
            )
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
            .overlay(alignment: .bottomTrailing) {
                if display.isAudiobook {
                    AudiobookCoverBadge(glyphSize: 11)
                }
            }
            Text(display.book.name)
                .font(DSFont.caption.weight(.medium))
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
            // Always present with two lines reserved so every card is the same
            // height — the carousel is a LazyHStack whose height tracks only the
            // cards built so far, and it must not grow as more scroll in.
            Text(display.intro)
                .font(DSFont.caption2)
                .foregroundColor(DSColor.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 104, alignment: .leading)
    }
}

// MARK: - Ranked row

private struct DiscoverRankedRow: View {
    let rank: Int
    let display: DiscoverBookDisplay
    let section: DiscoverShowcaseSection

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            rankBadge
            BookCoverImage(
                coverURL: display.book.coverUrl,
                title: display.book.name,
                sourceBaseURL: section.coverBaseURL,
                sourceHeaders: section.coverHeaders
            )
            .frame(width: 52, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
            .overlay(alignment: .bottomTrailing) {
                if display.isAudiobook {
                    AudiobookCoverBadge(glyphSize: 7)
                }
            }

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(display.book.name)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
                if !display.book.author.isEmpty {
                    Text(display.book.author)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }
                if !display.intro.isEmpty {
                    Text(display.intro)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.md)
        .contentShape(Rectangle())
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(DSFont.caption.weight(.bold))
            .foregroundColor(rank <= 3 ? DSColor.textOnAccent : DSColor.textSecondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .fill(rankColor)
            )
            .padding(.top, DSSpacing.xs)
    }

    private var rankColor: Color {
        switch rank {
        case 1: return DSColor.destructive
        case 2: return DSColor.warning
        case 3: return DSColor.warning.opacity(0.7)
        default: return DSColor.surface
        }
    }
}

// MARK: - Category detail ("查看全部")

/// Full list of one explore category, reached from a section's 查看全部 link.
struct DiscoverCategoryView: View {
    let section: DiscoverShowcaseSection
    let source: BookSource

    @State private var books: [DiscoverBookDisplay]
    @State private var nextPage: Int
    @State private var hasMorePages = true
    @State private var isLoadingMore = false
    @State private var loadMoreErrorReason: String?

    init(
        section: DiscoverShowcaseSection,
        source: BookSource
    ) {
        self.section = section
        self.source = source
        _books = State(initialValue: section.books)
        _nextPage = State(initialValue: section.books.isEmpty ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, display in
                    NavigationLink(value: ExploreNavigationRoute.book(display.book)) {
                        DiscoverRankedRow(rank: index + 1, display: display, section: section)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index >= books.count - 5 {
                            loadMoreIfNeeded()
                        }
                    }

                    if index < books.count - 1 {
                        Divider()
                            .padding(.leading, 88)
                    }
                }

                loadMoreFooter
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(section.title)
        .toolbarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, DSSpacing.md)
        } else if loadMoreErrorReason != nil {
            Button {
                loadMoreIfNeeded()
            } label: {
                VStack(spacing: DSSpacing.xs) {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "arrow.clockwise")
                        Text(localized("載入失敗，點按重試"))
                    }
                    .font(DSFont.subheadline)
                    .foregroundColor(DSColor.accent)

                    if let reason = loadMoreErrorReason, !reason.isEmpty {
                        Text(reason)
                            .font(DSFont.caption2)
                            .foregroundColor(DSColor.textSecondary)
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

// MARK: - Preview

#Preview {
    let vm = DiscoverViewModel()
    return NavigationStack {
        DiscoverShowcaseView(discover: vm)
            .navigationTitle("探索")
            .toolbarTitleDisplayModeInlineLarge()
    }
}
