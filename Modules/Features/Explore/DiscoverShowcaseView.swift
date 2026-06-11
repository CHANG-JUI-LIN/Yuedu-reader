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
    let onOpenBook: (OnlineBook) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !discover.filters.isEmpty {
                DiscoverFilterBar(discover: discover)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                    if discover.isLoadingItems && discover.sections.isEmpty {
                        loadingState
                    } else if discover.sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(discover.sections) { section in
                            DiscoverSectionView(
                                section: section,
                                onOpenBook: onOpenBook,
                                onAppearLoad: { discover.loadSection(section.id) },
                                onRetry: { discover.retrySection(section.id) }
                            )
                        }
                    }
                }
                .padding(.vertical, DSSpacing.lg)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { discover.reload() }
        }
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
        .background(DSColor.groupedBackground)
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
                .font(.system(size: 9, weight: .semibold))
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
    let onOpenBook: (OnlineBook) -> Void
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
            NavigationLink {
                DiscoverCategoryView(section: section, onOpenBook: onOpenBook)
            } label: {
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
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(section.books) { book in
                        Button { onOpenBook(book) } label: {
                            DiscoverFeaturedCard(book: book)
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
                ForEach(ranked, id: \.element.id) { index, book in
                    Button { onOpenBook(book) } label: {
                        DiscoverRankedRow(rank: index + 1, book: book)
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

// MARK: - Featured card (horizontal carousel item)

private struct DiscoverFeaturedCard: View {
    let book: OnlineBook

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookCoverImage(onlineBook: book)
                .frame(width: 104, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
            Text(book.name)
                .font(DSFont.caption.weight(.medium))
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
            if !introText.isEmpty {
                Text(introText)
                    .font(DSFont.caption2)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: 104, alignment: .leading)
    }

    private var introText: String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: book.intro)
    }
}

// MARK: - Ranked row

private struct DiscoverRankedRow: View {
    let rank: Int
    let book: OnlineBook

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            rankBadge
            BookCoverImage(onlineBook: book)
                .frame(width: 52, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(book.name)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundColor(DSColor.textPrimary)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }
                if !introText.isEmpty {
                    Text(introText)
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

    private var introText: String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: book.intro)
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
private struct DiscoverCategoryView: View {
    let section: DiscoverShowcaseSection
    let onOpenBook: (OnlineBook) -> Void

    var body: some View {
        List {
            ForEach(Array(section.books.enumerated()), id: \.element.id) { index, book in
                Button { onOpenBook(book) } label: {
                    DiscoverRankedRow(rank: index + 1, book: book)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle(section.title)
        .toolbarTitleDisplayMode(.large)
    }
}

// MARK: - Preview

#Preview {
    let vm = DiscoverViewModel()
    return NavigationStack {
        DiscoverShowcaseView(discover: vm, onOpenBook: { _ in })
            .navigationTitle("探索")
            .toolbarTitleDisplayMode(.inlineLarge)
    }
}
