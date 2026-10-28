import SwiftUI

// MARK: - SourceImportConfirmList

/// The import confirmation list: what a pack contains, how each entry compares to what the
/// library already holds, and which entries to actually take — Legado's
/// `ImportBookSourceDialog` / `ImportHttpTtsDialog`.
///
/// Written once against `ImportableSource` and used by both book sources and narration
/// engines. Type-specific controls (a book source's 匯入選項 page) are injected as a leading
/// `Section` through `extraOptions` rather than branching inside here.
///
/// Those options deliberately sit in the list rather than in the toolbar menu that upstream
/// uses. iOS has no overflow-menu convention to begin with, and on iOS 17 a SwiftUI `Menu`
/// action loses a `.sheet` presented while the menu's controller is still dismissing — the
/// documented trap in `Technotes/iOS17MenuModalPresentation.md`. A `NavigationLink` inside
/// the list has neither problem, so 匯入到分組 and the keep-switches are reached that way.
struct SourceImportConfirmList<Source: ImportableSource, ExtraOptions: View>: View {
    let title: String
    @ObservedObject var plan: SourceImportPlan<Source>
    /// The library's clock for an identity key, so a per-row edit can recompute its badge.
    let existingClock: (String) -> Int64?
    /// 顯示源註釋. Bound because it is a remembered preference, not sheet-local state.
    @Binding var showsComments: Bool
    let confirmTitle: String
    /// A `Section` of type-specific import options, shown above the entries.
    @ViewBuilder let extraOptions: () -> ExtraOptions
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var editingEntry: EditingEntry?
    @State private var expandedComments: Set<Int> = []

    /// `sheet(item:)` needs an `Identifiable`, and the plan's row ids are plain `Int`s.
    /// Wrapped locally rather than conforming `Int` itself.
    private struct EditingEntry: Identifiable {
        let id: Int
    }

    /// Whether anything in this pack carries a note — the 顯示源註釋 switch is pointless
    /// otherwise, and narration engines never have one.
    private var hasAnyComment: Bool {
        plan.entries.contains { $0.source.importComment != nil }
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inline)
                .themedAppSurface(for: .settings)
                .toolbar { toolbarContent }
                .sheet(item: $editingEntry) { entry in
                    editor(for: entry.id)
                }
        }
    }

    // MARK: List

    @ViewBuilder
    private var listContent: some View {
        if plan.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(localized("沒有可匯入的內容"), systemImage: "tray")
            } description: {
                Text(localized("這個檔案裡沒有可以解析的來源。")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
            }
            .themedAppSurface(for: .settings)
        } else {
            List {
                extraOptions()

                Section {
                    ForEach(plan.entries) { entry in
                        SourceImportRow(
                            name: entry.source.importDisplayName,
                            state: entry.state,
                            comment: showsComments ? entry.source.importComment : nil,
                            isSelected: plan.isSelected(entry.id),
                            isCommentExpanded: expandedComments.contains(entry.id),
                            onToggle: { plan.toggle(entry.id) },
                            onEdit: { editingEntry = EditingEntry(id: entry.id) },
                            onToggleComment: { toggleComment(entry.id) }
                        )
                    }
                } header: {
                    Text(summaryText)
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    Text(localized("「已有」表示作者標記的更新時間不比本機的新，預設不勾選。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// 共 N 個 · 新增 X · 更新 Y · 已有 Z — the counts the user needs before ticking anything.
    private var summaryText: String {
        var parts: [String] = [String(format: localized("共 %d 個"), plan.totalCount)]
        if plan.newCount > 0 {
            parts.append(String(format: localized("新增 %d"), plan.newCount))
        }
        if plan.updateCount > 0 {
            parts.append(String(format: localized("更新 %d"), plan.updateCount))
        }
        if plan.existingCount > 0 {
            parts.append(String(format: localized("已有 %d"), plan.existingCount))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(localized("取消"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            optionsMenu
            Button {
                onConfirm()
            } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(confirmTitle)
            .disabled(plan.selectedCount == 0)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            selectAllButton
            Spacer()
            Text(String(format: localized("已選 %d 個"), plan.selectedCount))
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
                // 全選's accessibility value already announces the same count.
                .accessibilityHidden(true)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                plan.toggleSelectAllNew()
            } label: {
                Label(
                    localized(plan.isSelectingAllNew ? "取消全選新增" : "全選新增"),
                    systemImage: "plus.circle"
                )
            }
            .disabled(plan.newCount == 0)
            Button {
                plan.toggleSelectAllUpdate()
            } label: {
                Label(
                    localized(plan.isSelectingAllUpdate ? "取消全選更新" : "全選更新"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(plan.updateCount == 0)
            if hasAnyComment {
                Divider()
                Toggle(isOn: $showsComments) {
                    Label(localized("顯示源註釋"), systemImage: "text.bubble")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(localized("匯入選項"))
    }

    private var selectAllButton: some View {
        Button {
            plan.toggleSelectAll()
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: plan.isSelectingAll ? "checkmark.square.fill" : "square")
                    .foregroundColor(plan.isSelectingAll ? DSColor.accent : Color(UIColor.systemGray3))
                    .accessibilityHidden(true)
                Text(localized(plan.isSelectingAll ? "取消全選" : "全選"))
                    .font(DSFont.subheadline)
            }
        }
        .accessibilityLabel(localized(plan.isSelectingAll ? "取消全選" : "全選"))
        .accessibilityValue("\(plan.selectedCount)/\(plan.totalCount)")
    }

    // MARK: Per-row editor

    @ViewBuilder
    private func editor(for id: Int) -> some View {
        if let entry = plan.entries.first(where: { $0.id == id }) {
            SourceImportJSONEditor(
                title: entry.source.importDisplayName,
                initialJSON: entry.source.importEditableJSON,
                onSave: { json in
                    plan.applyEdit(json: json, to: id, existingClock: existingClock)
                }
            )
        }
    }

    private func toggleComment(_ id: Int) {
        if expandedComments.contains(id) {
            expandedComments.remove(id)
        } else {
            expandedComments.insert(id)
        }
    }
}

// MARK: - SourceImportRow

/// One row, taking plain values rather than the plan, so SwiftUI can skip the rows a tap
/// didn't change. A pack can carry a few thousand entries and every tap republishes the
/// plan; rebuilding each row's body from the observed object would make one tap O(pack).
private struct SourceImportRow: View {
    let name: String
    let state: SourceImportItemState
    let comment: String?
    let isSelected: Bool
    let isCommentExpanded: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onToggleComment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Button(action: onToggle) {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundColor(isSelected ? DSColor.accent : Color(UIColor.systemGray3))
                            .accessibilityHidden(true)
                        Text(name)
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: DSSpacing.xs)
                        stateBadge
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityValue(Self.stateTitle(state))
                .accessibilityAddTraits(
                    isSelected ? [.isButton, .isSelected] : .isButton
                )

                Button(action: onEdit) {
                    Image(systemName: "curlybraces")
                        .foregroundColor(DSColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("編輯來源 JSON"))
            }
            .frame(minHeight: DSLayout.minimumTapTarget)

            if let comment {
                Button(action: onToggleComment) {
                    Text(comment)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(isCommentExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("源註釋"))
                .accessibilityValue(comment)
                .accessibilityHint(localized(isCommentExpanded ? "收合註釋" : "展開註釋"))
            }
        }
    }

    private var stateBadge: some View {
        Text(Self.stateTitle(state))
            .font(DSFont.caption2)
            .foregroundColor(Self.stateColor(state))
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 2)
            .background(Self.stateColor(state).opacity(0.12))
            .clipShape(Capsule())
            // The badge text already names the state; VoiceOver reads it as the row's value.
            .accessibilityHidden(true)
    }

    /// Context-qualified keys: bare 「新增」 is the *action* "Add" elsewhere in the app, which
    /// reads wrong on a badge describing what an entry is.
    static func stateTitle(_ state: SourceImportItemState) -> String {
        switch state {
        case .new: return localized("匯入狀態：新增")
        case .update: return localized("匯入狀態：更新")
        case .existing: return localized("匯入狀態：已有")
        }
    }

    private static func stateColor(_ state: SourceImportItemState) -> Color {
        switch state {
        case .new: return DSColor.accent
        case .update: return DSColor.warning
        case .existing: return DSColor.textSecondary
        }
    }
}
