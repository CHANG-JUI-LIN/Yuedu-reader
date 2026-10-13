import SwiftUI

// MARK: - 資源庫's sections and cards

/// 資源庫's sources by group (decision 31): the root never lays thousands of sources flat, so it
/// shows 所有來源配置 and one card per group, each opening its sources.
enum LibrarySourceGroups {
    struct Group: Equatable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// Every group the sources name, in name order, with how many sources each holds. A source
    /// in two groups counts in both, as Legado's group menu lists it under each.
    static func groups(of sources: [BookSource]) -> [Group] {
        var counts: [String: Int] = [:]
        for source in sources {
            for name in Set(DiscoverViewModel.groupNames(of: source)) {
                counts[name, default: 0] += 1
            }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Group(name: $0, count: counts[$0] ?? 0) }
    }
}

/// Cards laid out as 資源庫 is: so many to a row, or one under another, from the old 探索 root's
/// 格狀 and 每列欄數. At accessibility text sizes a card cannot hold its name in a column, so it
/// is the list whatever the setting.
struct LibraryEntries<Content: View>: View {
    @ViewBuilder let content: (ExploreEntryLabel.Layout) -> Content

    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey) private var gridColumnCount = ExploreGridDensity.default.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: ExploreEntryLabel.Layout {
        guard showsGrid, !dynamicTypeSize.isAccessibilitySize else { return .list }
        return .grid(.fitting(gridColumnCount, dynamicTypeSize: dynamicTypeSize))
    }

    var body: some View {
        switch layout {
        case .grid(let density):
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: density.rawValue),
                spacing: DSSpacing.md
            ) {
                content(layout)
            }
        case .list:
            LazyVStack(spacing: DSSpacing.md) {
                content(layout)
            }
        }
    }
}

/// A section of 資源庫: its name, quiet, with the page that manages it beside it, then its cards.
struct LibrarySection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: (ExploreEntryLabel.Layout) -> Content

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping (ExploreEntryLabel.Layout) -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xxs) {
                Text(title)
                    .font(DSFont.title3.weight(.semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                accessory()
            }
            .padding(.leading, DSSpacing.xs)
            LibraryEntries(content: content)
        }
    }
}

/// The small control beside a section's name: the page that manages the section.
struct LibrarySectionAccessoryLabel: View {
    var body: some View {
        Image(systemName: "slider.horizontal.3")
            .font(DSFont.subheadline.weight(.semibold))
            .foregroundStyle(DSColor.textSecondary)
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// 資源庫's layout choices, in its •••: the old 探索 root's 格狀 and 每列欄數, same keys.
struct LibraryLayoutMenuItems: View {
    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey) private var gridColumnCount = ExploreGridDensity.default.rawValue

    var body: some View {
        Toggle(isOn: $showsGrid) {
            Label(localized("格狀"), systemImage: "square.grid.2x2")
        }
        Picker(selection: $gridColumnCount) {
            ForEach(ExploreGridDensity.allCases) { density in
                Text(String(format: localized("%d 欄"), density.rawValue)).tag(density.rawValue)
            }
        } label: {
            Label(localized("每列欄數"), systemImage: "rectangle.split.3x1")
        }
        .pickerStyle(.menu)
        .disabled(!showsGrid)
    }
}

/// A source's card: opens its discover page; a long press offers Legado's actions on it.
struct LibrarySourceEntry: View {
    let source: BookSource
    let layout: ExploreEntryLabel.Layout
    @Binding var sheet: BookSourceActionSheet?
    @Binding var pendingDeletion: BookSource?
    let onSearch: () -> Void

    var body: some View {
        NavigationLink(value: ExploreNavigationRoute.source(sourceURL: source.bookSourceUrl)) {
            ExploreEntryLabel(source: source, layout: layout)
        }
        .buttonStyle(ExploreTileButtonStyle())
        .accessibilityLabel(source.bookSourceName)
        .accessibilityIdentifier("library.source.\(source.bookSourceName)")
        .contextMenu {
            // 刷新 lives on the source's own page, where pulling down reloads it.
            BookSourceActionMenuItems(
                source: source,
                onEdit: { sheet = .edit(source) },
                onPinToTop: {
                    BookSourceStore.shared.pinToTop(id: source.id)
                    UIAccessibility.post(notification: .announcement, argument: localized("已置頂"))
                },
                onLogin: { sheet = .login(source) },
                onSearch: onSearch,
                onRefresh: nil,
                onSetVariable: { sheet = .variable(source) },
                onDelete: { pendingDeletion = source }
            )
        }
    }
}

// MARK: - A group's sources

/// One group's sources, or all of them, as cards (decision 31): each opens its discover page.
struct LibrarySourcesView: View {
    let group: String?

    @ObservedObject private var sourceStore = BookSourceStore.shared
    @Environment(\.explorePush) private var push
    @State private var sources: [BookSource] = []
    @State private var sheet: BookSourceActionSheet?
    @State private var pendingDeletion: BookSource?

    var body: some View {
        ScrollView {
            LibraryEntries { layout in
                ForEach(sources) { source in
                    LibrarySourceEntry(source: source, layout: layout, sheet: $sheet, pendingDeletion: $pendingDeletion) {
                        push?(.explore(.searchInSource(sourceURL: source.bookSourceUrl)))
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .overlay {
            if sources.isEmpty {
                ContentUnavailableView(localized("沒有來源配置"), systemImage: "square.grid.2x2")
            }
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .navigationTitle(group ?? localized("所有來源配置"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryLayoutMenuItems()
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("更多"))
            }
        }
        .bookSourceActionSheets(sheet: $sheet, pendingDeletion: $pendingDeletion)
        .onReceive(sourceStore.sourcesPublisher) { _ in
            sources = DiscoverViewModel.exploreSources(DiscoverViewModel.exploreSources(in: sourceStore),
                                                       inGroup: group, matching: "")
        }
    }
}

#if DEBUG
#Preview("一個分組") {
    NavigationStack {
        LibrarySourcesView(group: nil)
    }
}
#endif
