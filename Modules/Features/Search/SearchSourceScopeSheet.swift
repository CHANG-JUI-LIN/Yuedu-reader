import SwiftUI

struct SearchSourceScopeCapsule: View {
    let title: String
    let isCustom: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                title,
                systemImage: isCustom
                    ? "checkmark.circle.fill"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(DSFont.caption)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .frame(minHeight: DSLayout.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .tint(DSColor.accent)
        .accessibilityLabel(localized("搜索範圍"))
        .accessibilityValue(title)
    }
}

struct SearchSourceScopeSheet: View {
    let enabledSources: [BookSource]
    let onSave: (SearchSourceScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: SearchSourceScope.Mode
    @State private var selectedSourceURLs: Set<String>
    @State private var sourceQuery = ""

    init(
        enabledSources: [BookSource],
        initialScope: SearchSourceScope,
        onSave: @escaping (SearchSourceScope) -> Void
    ) {
        self.enabledSources = enabledSources
        self.onSave = onSave
        _mode = State(initialValue: initialScope.mode)
        _selectedSourceURLs = State(initialValue: initialScope.selectedSourceURLs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(localized("搜索範圍")) {
                    Picker(localized("搜索範圍"), selection: $mode) {
                        Text(localized("全部書源")).tag(SearchSourceScope.Mode.all)
                        Text(localized("自選書源")).tag(SearchSourceScope.Mode.custom)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(DSColor.surface)
                }

                if mode == .custom {
                    quickSelectionSection
                    sourceSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .search).ignoresSafeArea())
            .pageBackgroundToolbar(for: .search)
            .navigationTitle(localized("搜索範圍"))
            .toolbarTitleDisplayMode(.inline)
            .searchable(text: $sourceQuery, prompt: localized("搜索書源"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveAndDismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private var quickSelectionSection: some View {
        Section(localized("快速選擇")) {
            Button(localized("全選")) {
                selectedSourceURLs = Set(enabledSources.compactMap { source in
                    let key = SearchSourceScope.sourceKey(for: source)
                    return key.isEmpty ? nil : key
                })
            }
            .listRowBackground(DSColor.surface)

            Button(localized("清除")) {
                selectedSourceURLs.removeAll()
            }
            .listRowBackground(DSColor.surface)
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            if enabledSources.isEmpty {
                ContentUnavailableView(
                    localized("尚未設置書源"),
                    systemImage: "exclamationmark.triangle"
                )
                .listRowBackground(Color.clear)
            } else if filteredSources.isEmpty {
                ContentUnavailableView.search(text: sourceQuery)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredSources) { source in
                    sourceRow(source)
                }
            }
        } footer: {
            if !canSave {
                Text(localized("請至少選擇一個可用書源"))
                    .dsSectionFooter(color: DSColor.destructive)
            }
        }
    }

    private func sourceRow(_ source: BookSource) -> some View {
        let key = SearchSourceScope.sourceKey(for: source)
        let isSelected = selectedSourceURLs.contains(key)

        return Button {
            if isSelected {
                selectedSourceURLs.remove(key)
            } else if !key.isEmpty {
                selectedSourceURLs.insert(key)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(source.bookSourceName)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(source.bookSourceUrl)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DSSpacing.sm)
                if isSelected {
                    Label(localized("已選取"), systemImage: "checkmark")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(DSColor.surface)
        .accessibilityLabel(source.bookSourceName)
        .accessibilityValue(localized(isSelected ? "已選取" : "未選取"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filteredSources: [BookSource] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return enabledSources }
        return enabledSources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(query)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(query)
        }
    }

    private var validSelectedSourceURLs: Set<String> {
        let enabledURLs = Set(enabledSources.compactMap { source in
            let key = SearchSourceScope.sourceKey(for: source)
            return key.isEmpty ? nil : key
        })
        return selectedSourceURLs.intersection(enabledURLs)
    }

    private var canSave: Bool {
        mode == .all || !validSelectedSourceURLs.isEmpty
    }

    private func saveAndDismiss() {
        let scope = mode == .all
            ? SearchSourceScope.all
            : SearchSourceScope(
                mode: .custom,
                selectedSourceURLs: validSelectedSourceURLs
            )
        onSave(scope)
        dismiss()
    }
}

private let searchSourceScopePreviewSources: [BookSource] = {
    var first = BookSource()
    first.bookSourceName = "示例書源 A"
    first.bookSourceUrl = "https://source-a.example"
    var second = BookSource()
    second.bookSourceName = "示例書源 B"
    second.bookSourceUrl = "https://source-b.example"
    return [first, second]
}()

#Preview("搜索範圍") {
    SearchSourceScopeSheet(
        enabledSources: searchSourceScopePreviewSources,
        initialScope: SearchSourceScope(
            mode: .custom,
            selectedSourceURLs: ["https://source-a.example"]
        ),
        onSave: { _ in }
    )
}
