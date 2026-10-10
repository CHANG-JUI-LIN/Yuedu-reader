import SwiftUI

/// 發現頁設定, behind the gear on a source's page: the categories the source returns as
/// chips, a card for each group the source draws (☆ 排行榜 ☆), to pick the ones the page
/// shows. With none picked the page shows every category; 全部顯示 clears the pick. Under
/// 快捷操作 with it sit the source's own controls — its buttons, inputs and toggles, run
/// as legado-E and MD3 run them — and its page links.
struct DiscoverPageSettingsSheet: View {
    @ObservedObject var discover: DiscoverViewModel
    /// Opens one of the source's page links; the source's page shows it once the sheet
    /// has gone.
    let onOpenPage: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .subheadline) private var chipMinWidth = DSLayout.discoverChipMinWidth
    @State private var query = ""
    /// The input being edited, and its text so far.
    @State private var editingInput: DiscoverQuickAction?
    @State private var inputDraft = ""

    /// Whether 快捷操作 has anything besides 全部顯示.
    private var hasControls: Bool {
        !discover.quickActions.isEmpty || !pageLinks.isEmpty
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    // A search looks through the categories alone. The controls show even
                    // without categories: a source may list none until its login button
                    // has run.
                    if trimmedQuery.isEmpty && (!groups.isEmpty || hasControls) {
                        quickActions
                    }
                    if !groups.isEmpty {
                        ForEach(visibleGroups) { group in
                            DiscoverChipCard(title: group.title, minimumChipWidth: chipMinWidth) {
                                // Keyed by the category: the groups are mapped afresh on
                                // every update of the page behind the sheet, each item with
                                // a new id, which would rebuild every chip each time.
                                ForEach(group.items, id: \.stableKey) { item in
                                    categoryChip(item)
                                }
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
                if groups.isEmpty && !hasControls {
                    if discover.isLoadingItems {
                        ProgressView()
                    } else {
                        ContentUnavailableView {
                            UnavailableLabel(localized("暫無發現內容"), systemImage: "sparkles")
                        }
                    }
                } else if !trimmedQuery.isEmpty && visibleGroups.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .softScrollEdges()
            .scrollDismissesKeyboard(.immediately)
            .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
            .navigationTitle(localized("發現頁設定"))
            .toolbarTitleDisplayMode(.inline)
            .modifier(SubtitleWhereAvailable(subtitle: localized("選擇想看的分區")))
            .pageBackgroundToolbar(for: .explore)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜尋發現項目")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark")
                    }
                }
            }
            .alert(
                editingInput.map(discover.displayName(for:)) ?? "",
                isPresented: Binding(
                    get: { editingInput != nil },
                    set: { if !$0 { editingInput = nil } }
                ),
                presenting: editingInput
            ) { input in
                TextField(localized("輸入"), text: $inputDraft)
                Button(localized("取消"), role: .cancel) {}
                Button(localized("確定")) {
                    let text = inputDraft
                    Task { await discover.submitText(text, for: input, presentToast: Self.presentToast) }
                }
            }
        }
    }

    /// Toasts from the source's scripts, shown the way its login page shows them.
    private static func presentToast(_ message: String) {
        BookSourceFormLoginView.presentToastAlert(message: message)
    }

    /// 全部顯示, picked while no category is, then the source's page links.
    private var quickActions: some View {
        DiscoverChipCard(title: localized("快捷操作"), minimumChipWidth: chipMinWidth) {
            let showsAll = !discover.hasCustomCategorySelection
            Button { discover.showAllCategories() } label: {
                DSCapsuleLabel(title: localized("全部顯示"), isSelected: showsAll, fillsWidth: true, onCard: true)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showsAll ? .isSelected : [])
            ForEach(discover.quickActions) { action in
                controlChip(action)
            }
            ForEach(pageLinks, id: \.stableKey) { item in
                if let url = item.actionURL {
                    Button {
                        onOpenPage(url)
                        dismiss()
                    } label: {
                        DSCapsuleLabel(
                            title: item.title,
                            trailingSystemImage: "arrow.up.right",
                            fillsWidth: true,
                            onCard: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(localized("在瀏覽器中開啟"))
                }
            }
        }
    }

    /// The source's page links, each once.
    private var pageLinks: [DiscoverCardItem] {
        var seen = Set<String>()
        return discover.pageItems.filter { seen.insert($0.stableKey).inserted }
    }

    /// A source control as a chip: a button runs its script, an input opens for editing
    /// and shows what it holds, a toggle steps to its next value.
    private func controlChip(_ action: DiscoverQuickAction) -> some View {
        let name = discover.displayName(for: action)
        let value = discover.quickActionValues[action.title] ?? ""
        let isRunning = discover.runningQuickActionID == action.id
        return Button {
            switch action.kind {
            case .button:
                Task { await discover.runButton(action, presentToast: Self.presentToast) }
            case .text:
                inputDraft = value
                editingInput = action
            case .toggle:
                Task { await discover.cycleToggle(action, presentToast: Self.presentToast) }
            }
        } label: {
            switch action.kind {
            case .button:
                DSCapsuleLabel(title: name, fillsWidth: true, onCard: true)
            case .text:
                DSCapsuleLabel(
                    title: name,
                    fillsWidth: true,
                    onCard: true,
                    detail: value.isEmpty ? localized("輸入") : value
                )
            case .toggle:
                let current = action.toggleValue(in: discover.quickActionValues)
                DSCapsuleLabel(
                    title: action.valueTrails ? name + current : current + name,
                    fillsWidth: true,
                    onCard: true
                )
            }
        }
        .buttonStyle(.plain)
        .opacity(isRunning ? 0.5 : 1)
        .disabled(discover.runningQuickActionID != nil)
    }

    private func categoryChip(_ item: DiscoverCardItem) -> some View {
        let selected = discover.isCategorySelected(item)
        return Button { discover.toggleCategorySelection(item) } label: {
            DSCapsuleLabel(title: item.title, isSelected: selected, fillsWidth: true, onCard: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The subtitle under the title, from iOS 26; earlier bars have no place for one.
private struct SubtitleWhereAvailable: ViewModifier {
    let subtitle: String

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#Preview {
    var source = BookSource()
    source.bookSourceName = "範例來源配置"
    source.bookSourceUrl = "https://example.com"
    return DiscoverPageSettingsSheet(discover: DiscoverViewModel(source: source), onOpenPage: { _ in })
}
