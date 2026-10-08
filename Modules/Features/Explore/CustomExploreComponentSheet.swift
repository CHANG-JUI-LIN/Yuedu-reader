import SwiftUI

// MARK: - Adding or changing a block

/// Adds a block to a custom explore page — its layout first, from a half-height grid of
/// tiles, then its source, category and title, the sheet growing to full height for them
/// — or changes one already there.
struct CustomExploreComponentSheet: View {
    let pageID: UUID
    /// The block being changed; nil adds one.
    let editing: CustomExploreComponent?

    @ObservedObject private var store = CustomExplorePageStore.shared
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption) private var tileMinWidth = DSLayout.customExploreLayoutTileMinWidth
    @State private var path: [CustomExploreComponent.Kind] = []
    @State private var detent: PresentationDetent = .medium

    /// Every layout, but the waterfall only while the page has none.
    private var kinds: [CustomExploreComponent.Kind] {
        let hasWaterfall = store.page(id: pageID)?.hasWaterfall ?? false
        return CustomExploreComponent.Kind.allCases.filter { $0 != .waterfall || !hasWaterfall }
    }

    var body: some View {
        if let editing {
            NavigationStack {
                CustomExploreComponentForm(kind: editing.kind, initial: editing, isRoot: true, onSave: save)
            }
            .presentationDetents([.large])
        } else {
            NavigationStack(path: $path) {
                kindGrid
                    .navigationDestination(for: CustomExploreComponent.Kind.self) { kind in
                        CustomExploreComponentForm(kind: kind, initial: nil, isRoot: false, onSave: save)
                    }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            // The settings need the room; back at the layouts, half height again.
            .onChange(of: path) { _, path in
                detent = path.isEmpty ? .medium : .large
            }
        }
    }

    private var kindGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileMinWidth), spacing: DSSpacing.md)],
                spacing: DSSpacing.md
            ) {
                ForEach(kinds) { kind in
                    Button { path.append(kind) } label: {
                        CustomExploreLayoutTile(kind: kind)
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityHint(localized(kind.descriptionKey))
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .navigationTitle(localized("新增元件"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Label(localized("關閉"), systemImage: "xmark")
                }
            }
        }
    }

    private func save(_ component: CustomExploreComponent) {
        store.saveComponent(component, inPage: pageID)
        dismiss()
    }
}

/// A layout's tile in 新增元件: its symbol in a circle over its name, on its own hue.
private struct CustomExploreLayoutTile: View {
    let kind: CustomExploreComponent.Kind

    @ScaledMetric(relativeTo: .caption) private var iconSize = DSLayout.customExploreLayoutIconSize
    @ScaledMetric(relativeTo: .caption) private var minHeight = DSLayout.customExploreLayoutTileMinWidth

    var body: some View {
        let tint = kind.tint
        let shape = RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: kind.systemImage)
                .font(DSFont.headline)
                .foregroundStyle(tint)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(tint.opacity(0.18)))
                .accessibilityHidden(true)
            // Two lines kept for every name, so every tile is the same height.
            Text(localized(kind.titleKey))
                .font(DSFont.caption.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(DSSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(shape.fill(tint.opacity(0.12)))
        .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .contentShape(shape)
    }
}

extension CustomExploreComponent.Kind {
    /// The layout's hue on its tile.
    var tint: Color {
        switch self {
        case .featuredCards: DSColor.layoutFeaturedCards
        case .ranking: DSColor.layoutRanking
        case .grid: DSColor.layoutGrid
        case .carousel: DSColor.layoutCarousel
        case .pagedRanking: DSColor.layoutPagedRanking
        case .multiCategoryRanking: DSColor.layoutMultiCategoryRanking
        case .waterfall: DSColor.layoutWaterfall
        }
    }
}

// MARK: - The block's settings

/// A block's source, category and title. ✓ saves once the block has what its layout
/// needs; 多分類排行榜 needs two categories or more and has no title, its tabs naming them.
private struct CustomExploreComponentForm: View {
    let kind: CustomExploreComponent.Kind
    let initial: CustomExploreComponent?
    /// The sheet's first page, which closes it; pushed from the layouts, Back leads back.
    let isRoot: Bool
    let onSave: (CustomExploreComponent) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @State private var componentID: UUID
    @State private var sourceURL: String?
    @State private var categories: [ExploreCategoryReference]
    @State private var title: String

    init(
        kind: CustomExploreComponent.Kind,
        initial: CustomExploreComponent?,
        isRoot: Bool,
        onSave: @escaping (CustomExploreComponent) -> Void
    ) {
        self.kind = kind
        self.initial = initial
        self.isRoot = isRoot
        self.onSave = onSave
        _componentID = State(initialValue: initial?.id ?? UUID())
        _sourceURL = State(initialValue: initial?.sourceURL)
        _categories = State(initialValue: initial?.categories ?? [])
        _title = State(initialValue: initial?.title ?? "")
    }

    private var source: BookSource? {
        sourceURL.flatMap { url in sourceStore.sources.first { $0.bookSourceUrl == url } }
    }

    private var draft: CustomExploreComponent {
        CustomExploreComponent(
            id: componentID,
            kind: kind,
            title: kind.takesSeveralCategories ? "" : title.trimmingCharacters(in: .whitespacesAndNewlines),
            categories: categories
        )
    }

    private var categorySummary: String {
        categories.isEmpty ? localized("未選擇") : categories.map(\.title).joined(separator: "、")
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CustomExploreSourcePicker(selectedURL: sourceURL) { url in
                        guard url != sourceURL else { return }
                        sourceURL = url
                        categories = []
                        title = ""
                    }
                } label: {
                    LabeledContent(localized("來源配置"), value: source?.bookSourceName ?? localized("未選擇"))
                }
                if let source {
                    NavigationLink {
                        CustomExploreCategoryPicker(
                            source: source,
                            allowsSeveral: kind.takesSeveralCategories,
                            selection: $categories,
                            onPick: pick
                        )
                    } label: {
                        LabeledContent(localized("發現項"), value: categorySummary)
                    }
                } else {
                    LabeledContent(localized("發現項"), value: localized("未選擇"))
                        .foregroundStyle(DSColor.textDisabled)
                }
            } footer: {
                if kind.takesSeveralCategories {
                    Text(localized("至少選 2 個分類，在頁面上用標籤切換。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()
            if !kind.takesSeveralCategories {
                Section(localized("標題")) {
                    TextField(
                        localized("標題"),
                        text: $title,
                        prompt: Text(categories.first?.title ?? localized("標題"))
                    )
                }
                .interfaceSectionSurface()
            }
        }
        .themedAppSurface(for: .explore)
        .navigationTitle(localized(kind.titleKey))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { onSave(draft) } label: {
                    Label(localized("完成"), systemImage: "checkmark")
                }
                .disabled(!draft.isComplete)
            }
        }
    }

    /// One category chosen for a one-category block: it becomes the block's, and its
    /// title the block's too unless one was typed.
    private func pick(_ reference: ExploreCategoryReference) {
        let previousTitle = categories.first?.title
        categories = [reference]
        if title.isEmpty || title == previousTitle {
            title = reference.title
        }
    }
}

// MARK: - Choosing the source

/// The explore sources, to search and pick one.
private struct CustomExploreSourcePicker: View {
    let selectedURL: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @State private var query = ""

    private var exploreSources: [BookSource] {
        DiscoverViewModel.exploreSources(in: sourceStore)
    }

    private var visibleSources: [BookSource] {
        ExploreHomeView.sources(
            exploreSources,
            inGroup: nil,
            matching: query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var body: some View {
        List {
            ForEach(visibleSources) { source in
                let isSelected = source.bookSourceUrl == selectedURL
                Button {
                    onPick(source.bookSourceUrl)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                            Text(source.bookSourceName)
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.textPrimary)
                            if !source.bookSourceGroup.isEmpty {
                                Text(source.bookSourceGroup)
                                    .font(DSFont.footnote)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(DSColor.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .interfaceSectionSurface()
        }
        .overlay {
            if exploreSources.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("尚未啟用支援發現的來源配置"), systemImage: "books.vertical")
                }
            } else if visibleSources.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .themedAppSurface(for: .explore)
        .navigationTitle(localized("來源配置"))
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: localized("搜索來源配置"))
    }
}

// MARK: - Choosing the category

/// The source's categories as 發現頁設定 draws them — a card of chips for each group the
/// source lists — to pick one, or several for 多分類排行榜.
private struct CustomExploreCategoryPicker: View {
    let source: BookSource
    let allowsSeveral: Bool
    @Binding var selection: [ExploreCategoryReference]
    /// One category picked, for a block that takes one.
    let onPick: (ExploreCategoryReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var discover: DiscoverViewModel
    @ScaledMetric(relativeTo: .subheadline) private var chipMinWidth = DSLayout.discoverChipMinWidth
    @State private var query = ""

    init(
        source: BookSource,
        allowsSeveral: Bool,
        selection: Binding<[ExploreCategoryReference]>,
        onPick: @escaping (ExploreCategoryReference) -> Void
    ) {
        self.source = source
        self.allowsSeveral = allowsSeveral
        _selection = selection
        self.onPick = onPick
        _discover = StateObject(wrappedValue: DiscoverViewModel(source: source))
    }

    private var groups: [DiscoverCategoryGroup] {
        discover.categoryGroups(defaultTitle: localized("分類"))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleGroups: [DiscoverCategoryGroup] {
        DiscoverCategoryGroup.filtered(groups, matching: trimmedQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                ForEach(visibleGroups) { group in
                    DiscoverChipCard(title: group.title, minimumChipWidth: chipMinWidth) {
                        ForEach(group.items, id: \.stableKey) { item in
                            chip(item)
                        }
                    }
                }
            }
            // The full width even with nothing to list, as 探索's own page needs.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .overlay {
            if groups.isEmpty {
                if discover.isLoadingItems {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        UnavailableLabel(localized("暫無發現內容"), systemImage: "sparkles")
                    }
                }
            } else if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
        .softScrollEdges()
        .scrollDismissesKeyboard(.immediately)
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .navigationTitle(localized("發現項"))
        .toolbarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("搜尋發現項目")
        )
        .onAppear { discover.refreshSources() }
    }

    @ViewBuilder
    private func chip(_ item: DiscoverCardItem) -> some View {
        if let reference = ExploreCategoryReference(source: source, item: item) {
            let isSelected = selection.contains(reference)
            Button {
                if allowsSeveral {
                    if isSelected {
                        selection.removeAll { $0 == reference }
                    } else {
                        selection.append(reference)
                    }
                } else {
                    onPick(reference)
                    dismiss()
                }
            } label: {
                DSCapsuleLabel(title: item.title, isSelected: isSelected, fillsWidth: true, onCard: true)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
