import SwiftUI
import UniformTypeIdentifiers

private enum BookSourceImportPresentationRoute: Hashable {
    /// 手動新增 — an empty source in the editor. Sequenced with the imports because it is now
    /// reached from the same 「+」 menu, and on iOS 17 that menu can swallow its sheet too.
    case add
    case local
    case network
}

// MARK: - Book Source List (Legado Style)

struct BookSourceListView: View {
    var embedsNavigationStack = true

    @ObservedObject private var store = BookSourceStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showAdd = false
    @State private var editingSource: BookSource? = nil
    @State private var showImport = false
    @State private var showImportFile = false
    @State private var importJSON = ""
    @State private var importError: String? = nil
    @State private var importSuccess: String? = nil
    @State private var showNetworkImport = false
    @State private var importURLString = ""
    @State private var networkImportLoading = false
    @State private var showLegacyImportChooser = false
    @State private var legacyImportSequence =
        DismissalSequencedPresentation<BookSourceImportPresentationRoute>()
    @State private var loginSource: BookSource? = nil
    @State private var variableEditingSource: BookSource? = nil
    @Environment(\.presentationMode) var dismiss

    @State private var selectedIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var showDeleteConfirm = false
    @State private var showMoreMenu = false
    @State private var showSourceCheck = false
    @State private var showCheckOptions = false
    @State private var pendingCheckSources: [BookSource] = []
    @State private var pendingStartPolicy: BookSourceCheckPolicy? = nil
    @State private var showGroupByDomainConfirm = false
    // Shared instance so a check keeps running in the background after this screen is dismissed.
    @ObservedObject private var healthChecker = BookSourceHealthChecker.shared
    @State private var checkToast: String? = nil
    @State private var validationFilter: ValidationListFilter = .all
    @State private var showDisclaimer = false
    /// Set by 置頂／置底 so the list follows the row to its new position.
    @State private var scrollTargetId: UUID? = nil
    /// Non-empty book-source groups the user has expanded. Seeded with every group on
    /// appear so nothing starts hidden; searching flattens the layout regardless.
    @State private var expandedGroups: Set<String> = []
    /// Pending 重命名分組 / 移動到新分組 text entry, plus its draft name.
    @State private var groupNaming: PendingGroupNaming? = nil
    @State private var groupNameText = ""
    /// Group the 刪除該分組 confirmation is about to delete.
    @State private var deletingGroup: PendingGroupAction? = nil
    /// Pending 移動到分組 / 合併到其他分組 pick, shown as a searchable group list.
    @State private var groupPicking: PendingGroupPick? = nil
    /// Source shown in the read-only 查看詳情 sheet.
    @State private var infoSource: BookSource? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var checkSources: [BookSource] {
        if !selectedIds.isEmpty {
            store.sources.filter { selectedIds.contains($0.id) }
        } else {
            store.sources.filter { $0.enabled }
        }
    }

    private var displayedSources: [BookSource] {
        switch validationFilter {
        case .all:
            return filteredSources
        case .fetchError:
            return filteredSources.filter { healthChecker.healthById[$0.id]?.health == .fetchError }
        case .contentError:
            return filteredSources.filter { healthChecker.healthById[$0.id]?.health == .contentError }
        }
    }

    private var filteredSources: [BookSource] {
        if searchText.isEmpty { return store.sources }
        let q = searchText.lowercased()
        return store.sources.filter {
            $0.bookSourceName.lowercased().contains(q) || $0.bookSourceUrl.lowercased().contains(q)
                || $0.bookSourceGroup.lowercased().contains(q)
        }
    }

    /// A group snapshot frozen at the moment its menu item was tapped, so the delete alert
    /// acts on exactly what the user saw — the live list can be re-grouped by the very edit
    /// they are confirming.
    private struct PendingGroupAction: Identifiable {
        let id: String
        let name: String
        let sourceIds: Set<UUID>
    }

    /// A pending 移動到分組 / 合併到其他分組, frozen when its menu row was tapped so the sheet
    /// acts on exactly what the user saw — the live list can be re-grouped by the very edit
    /// being made (same contract as `PendingGroupAction`).
    private struct PendingGroupPick: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let sourceIds: Set<UUID>
        let candidates: [BookSourceGroupCandidate]
        /// The group these sources are leaving, so the sheet doesn't offer to re-create it.
        let excluded: String
        let defaultGroupTitle: String?
        let allowsNewGroup: Bool
    }

    /// A pending group-name entry — 重命名分組 for a whole group, or 移動到新分組 for one
    /// source. Both write the same field through `applyGroupName`, so they share one alert.
    private struct PendingGroupNaming: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let sourceIds: Set<UUID>
        /// The name the entry must differ from to be worth writing.
        let currentName: String
    }

    /// Legado keeps sources with an empty `bookSourceGroup` in a built-in default group;
    /// mirror that instead of scattering them as bare rows.
    private var defaultGroupName: String {
        localized("默認分組")
    }

    /// Group layout: the 置頂 group first, then the named `bookSourceGroup` groups (pinned
    /// sources excluded — they live in the pin groups now), then the 置底 group. Pin groups
    /// keep array order, which is pinnedAt newest-first. Group members are accumulated per
    /// name, so interleaved sources of the same group render under one contiguous header.
    private var displayedGroups: [BookSourceRowGroup] {
        let topPinned = displayedSources.filter { store.pinRecord(for: $0.id)?.position == .top }
        let bottomPinned = displayedSources.filter { store.pinRecord(for: $0.id)?.position == .bottom }
        var groups: [BookSourceRowGroup] = []
        if !topPinned.isEmpty {
            groups.append(BookSourceRowGroup(
                id: BookSourceRowGroup.topPinnedID, name: localized("置頂組"), sources: topPinned))
        }
        var names: [String] = []
        var byName: [String: [BookSource]] = [:]
        for source in displayedSources where store.pinRecord(for: source.id) == nil {
            let name = source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.isEmpty ? defaultGroupName : name
            if byName[key] == nil { names.append(key) }
            byName[key, default: []].append(source)
        }
        groups.append(contentsOf: names.map {
            BookSourceRowGroup(id: $0, name: $0, sources: byName[$0] ?? [])
        })
        if !bottomPinned.isEmpty {
            groups.append(BookSourceRowGroup(
                id: BookSourceRowGroup.bottomPinnedID, name: localized("置底組"),
                sources: bottomPinned))
        }
        return groups
    }

    /// Searching flattens the grouped layout so matching sources stay visible no matter
    /// which group they belong to; the filter row's grouping toggle flattens it on demand.
    private var usesGroupedLayout: Bool {
        searchText.isEmpty && gs.bookSourceListGrouped
    }

    /// Every group id (named groups, the built-in default group, and the pin groups when
    /// pinned sources exist), re-checked so newly imported or edited groups are seeded
    /// expanded instead of hidden behind a collapsed header.
    private var allGroupIDs: Set<String> {
        var ids = Set(store.sources.map {
            $0.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        if store.sources.contains(where: {
            $0.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            ids.insert(defaultGroupName)
        }
        // Read the pin table directly instead of scanning every source for a pin: the
        // scan was O(sources) twice per body evaluation, and pins are a handful of rows.
        if store.pinRecords.values.contains(where: { $0.position == .top }) {
            ids.insert(BookSourceRowGroup.topPinnedID)
        }
        if store.pinRecords.values.contains(where: { $0.position == .bottom }) {
            ids.insert(BookSourceRowGroup.bottomPinnedID)
        }
        return ids
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    managementContent
                }
            } else {
                managementContent
            }
        }
    }

    private var managementContent: some View {
        AdaptiveSheetContainer(maxWidth: DSLayout.readableWideWidth) {
                VStack(spacing: 0) {
                    if store.sources.isEmpty {
                        emptyView
                    } else {
                        sourceList
                    }

                    Divider()

                    bottomToolbar
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .navigationTitle(localized("書源管理"))
            .toolbarTitleDisplayMode(.inline)
            .pageBackgroundToolbar(for: .settings)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索書源")
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    addSourceToolbarControl
                    Menu {
                        Button {
                            enableAll()
                        } label: {
                            Label(localized("全部啟用"), systemImage: "checkmark.circle")
                        }
                        Button {
                            disableAll()
                        } label: {
                            Label(localized("全部停用"), systemImage: "xmark.circle")
                        }
                        Divider()
                        Menu {
                            if !selectedIds.isEmpty {
                                BookSourceExportShareLink(
                                    label: localized("匯出選中"),
                                    filenameLabel: localized("選中書源"),
                                    sources: store.sources.filter { selectedIds.contains($0.id) }
                                )
                            }
                            BookSourceExportShareLink(
                                label: localized("匯出全部"),
                                filenameLabel: localized("全部書源"),
                                sources: store.sources
                            )
                            Divider()
                            Button {
                                copySelectedToPasteboard()
                            } label: {
                                Label(localized("複製選中到剪貼簿"), systemImage: "doc.on.doc")
                            }
                            .disabled(selectedIds.isEmpty)
                            Button {
                                copyAllToPasteboard()
                            } label: {
                                Label(localized("複製全部到剪貼簿"), systemImage: "doc.on.doc.fill")
                            }
                        } label: {
                            Label(localized("匯出"), systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button {
                            presentCheckOptions()
                        } label: {
                            Label(localized("書源驗證"), systemImage: "stethoscope")
                        }
                        Divider()
                        Button {
                            showGroupByDomainConfirm = true
                        } label: {
                            Label(localized("按域名分組"), systemImage: "globe")
                        }
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label(localized("粘貼源"), systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(localized("更多"))
                }
            }
            .sheet(
                isPresented: $showLegacyImportChooser,
                onDismiss: presentLegacyImportAfterChooserDismissal
            ) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("新增書源"),
                        actions: [
                            DismissalSequencedAction(
                                route: .add,
                                title: localized("手動新增"),
                                systemImage: "square.and.pencil"
                            ),
                            DismissalSequencedAction(
                                route: .local,
                                title: localized("本地導入"),
                                systemImage: "doc.badge.plus"
                            ),
                            DismissalSequencedAction(
                                route: .network,
                                title: localized("網路導入"),
                                systemImage: "network"
                            ),
                        ],
                        onSelect: { legacyImportSequence.select($0) }
                    )
                }
            }
            .sheet(isPresented: $showAdd) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                    BookSourceEditView(source: BookSource()) { src in
                        store.add(src)
                    }
                }
            }
            .sheet(item: $infoSource) { src in
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    BookSourceInfoSheet(
                        source: src, validation: healthChecker.healthById[src.id])
                }
            }
            .sheet(item: $editingSource) { src in
                AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                    BookSourceEditView(source: src) { updated in
                        store.update(updated)
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    importSheet
                }
            }
            .sheet(isPresented: $showNetworkImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    networkImportSheet
                }
            }
            .sheet(item: $loginSource) { src in
                if src.loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    BookSourceLoginWebView(source: src) {
                        loginSource = nil
                    }
                } else {
                    BookSourceFormLoginView(source: src) {
                        loginSource = nil
                    }
                }
            }
            .sheet(item: $groupPicking) { pick in
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    BookSourceGroupPickerSheet(
                        title: pick.title,
                        subtitle: pick.subtitle,
                        candidates: pick.candidates,
                        excluded: pick.excluded,
                        defaultGroupTitle: pick.defaultGroupTitle,
                        defaultGroupName: defaultGroupName,
                        allowsNewGroup: pick.allowsNewGroup
                    ) { name in
                        applyGroupName(name, to: pick.sourceIds)
                    }
                }
            }
            .sheet(item: $variableEditingSource) { src in
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    RuntimeVariableEditorView(
                        title: localized("設置源變量"),
                        comment: src.variableComment,
                        initialValue: BookSourceRuntimeStateStore.shared
                            .sourceVariableJSON(for: src.bookSourceUrl) ?? ""
                    ) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(
                            trimmed.isEmpty ? nil : trimmed,
                            for: src.bookSourceUrl
                        )
                        return nil
                    }
                }
            }
            .sheet(isPresented: $showCheckOptions, onDismiss: {
                // Start (and open the results sheet) only AFTER the options sheet has fully
                // dismissed — presenting a second sheet on the same frame as the first dismisses
                // is unreliable in SwiftUI.
                if let policy = pendingStartPolicy {
                    pendingStartPolicy = nil
                    startCheck(with: policy, sources: pendingCheckSources)
                }
            }) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    BookSourceCheckOptionsView(
                        sourceCount: pendingCheckSources.count,
                        initialPolicy: healthChecker.policy
                    ) { policy in
                        pendingStartPolicy = policy
                    }
                }
            }
            .sheet(isPresented: $showSourceCheck) {
                BookSourceCheckView(checker: healthChecker)
            }
            .alert(
                localized("按域名分組"),
                isPresented: $showGroupByDomainConfirm
            ) {
                Button(localized("取消"), role: .cancel) {}
                Button(localized("確定")) {
                    let changed = store.groupByDomain()
                    withAnimation {
                        importSuccess =
                            localized("已按域名分組") + " \(changed) " + localized("個書源")
                    }
                }
            } message: {
                Text(localized("按域名分組將覆蓋現有分組，確定繼續？"))
            }
            .alert(localized("確認刪除"), isPresented: $showDeleteConfirm) {
                Button(localized("取消"), role: .cancel) {}
                Button(localized("刪除"), role: .destructive) {
                    deleteSelected()
                }
            } message: {
                Text(localized("確定要刪除選中的") + " \(selectedIds.count) " + localized("個書源嗎？"))
            }
            .alert(
                groupNaming?.title ?? localized("分組名稱"),
                isPresented: Binding(
                    get: { groupNaming != nil },
                    set: { if !$0 { groupNaming = nil } }
                )
            ) {
                TextField(localized("分組名稱"), text: $groupNameText)
                Button(localized("取消"), role: .cancel) { groupNaming = nil }
                Button(localized("確定")) { commitGroupNaming() }
            } message: {
                if let pending = groupNaming {
                    Text(pending.subtitle)
                }
            }
            .alert(
                localized("刪除該分組"),
                isPresented: Binding(
                    get: { deletingGroup != nil },
                    set: { if !$0 { deletingGroup = nil } }
                )
            ) {
                Button(localized("取消"), role: .cancel) { deletingGroup = nil }
                Button(localized("刪除"), role: .destructive) {
                    if let pending = deletingGroup { deleteGroup(pending) }
                    deletingGroup = nil
                }
            } message: {
                if let pending = deletingGroup {
                    Text(
                        localized("確定要刪除分組") + "「\(pending.name)」" + localized("及其中的")
                            + " \(pending.sourceIds.count) " + localized("個書源嗎？"))
                }
            }
            .alert(
                messageAlertTitle,
                isPresented: Binding(
                    get: { importError != nil || importSuccess != nil || checkToast != nil },
                    set: { isPresented in
                        if !isPresented {
                            importError = nil
                            importSuccess = nil
                            checkToast = nil
                        }
                    }
                )
            ) {
                Button(localized("確定"), role: .cancel) {}
            } message: {
                Text(importError ?? importSuccess ?? checkToast ?? "")
            }
            .overlay(alignment: .top) {
                if healthChecker.isRunning {
                    HStack(spacing: DSSpacing.sm) {
                        ProgressView().scaleEffect(0.8)
                        Text(localized("驗證中…"))
                            .font(DSFont.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.accent.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(.top, DSSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .fullScreenCover(isPresented: $showDisclaimer) {
                SourceDisclaimerView {
                    gs.sourceDisclaimerAccepted = true
                    showDisclaimer = false
                }
            }
            .onAppear {
                expandedGroups.formUnion(allGroupIDs)
                if !gs.sourceDisclaimerAccepted {
                    showDisclaimer = true
                }
            }
            .onChange(of: store.sources.map(\.id)) { _, sourceIds in
                selectedIds.formIntersection(Set(sourceIds))
            }
            .onChange(of: allGroupIDs) { _, ids in
                expandedGroups.formUnion(ids)
            }
    }

    /// One 「+」 entry for 手動新增 and both import routes — the separate ⤓ button is gone.
    /// The iOS 17 compatibility path still applies: every destination behind it is a sheet or
    /// document picker, which a still-dismissing menu can drop.
    @ViewBuilder
    private var addSourceToolbarControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyImportSequence.cancel()
                showLegacyImportChooser = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(localized("新增書源"))
        } else {
            Menu {
                Button {
                    showAdd = true
                } label: {
                    Label(localized("手動新增"), systemImage: "square.and.pencil")
                }
                Divider()
                Button {
                    showImport = true
                } label: {
                    Label(localized("本地導入"), systemImage: "doc.badge.plus")
                }
                Button {
                    showNetworkImport = true
                } label: {
                    Label(localized("網路導入"), systemImage: "network")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(localized("新增書源"))
        }
    }

    private func presentLegacyImportAfterChooserDismissal() {
        guard let route = legacyImportSequence.consumeAfterDismissal() else {
            return
        }
        switch route {
        case .add:
            showAdd = true
        case .local:
            showImport = true
        case .network:
            showNetworkImport = true
        }
    }

    // MARK: - Source List

    private var sourceList: some View {
        let rowActions = self.rowActions
        let groupActions = self.groupActions
        return ScrollViewReader { proxy in
            List {
                Section {
                    SourceValidationListHeader(
                        sources: store.sources,
                        healthById: healthChecker.healthById,
                        filter: $validationFilter,
                        grouped: $gs.bookSourceListGrouped
                    )
                }
                .listRowSeparator(.hidden)
                // Clear, not a surface: `statsCard` and the filter chips paint their own,
                // so a row background here would put a second full-width slab behind them
                // — the block that read as an opaque header above a see-through list.
                .listRowBackground(Color.clear)

                if usesGroupedLayout {
                    // Plain header row + conditional child rows instead of `DisclosureGroup`:
                    // SwiftUI pins its disclosure indicator to the trailing edge on iOS and
                    // offers no way to move it (row insets shift the label, not the chevron),
                    // and a custom `DisclosureGroupStyle` would collapse the whole group into
                    // one List row — losing per-source separators, insets, and lazy rows.
                    ForEach(displayedGroups) { group in
                        BookSourceGroupHeaderRow(
                            group: group,
                            expanded: expandedGroups.contains(group.id),
                            actions: groupActions
                        )
                        .listRowInsets(
                            EdgeInsets(
                                top: 0, leading: DSSpacing.md, bottom: 0, trailing: DSSpacing.md))
                        .listRowSeparator(.hidden)
                        .interfaceSectionSurface()

                        if expandedGroups.contains(group.id) {
                            ForEach(group.sources) { source in
                                sourceRowListEntry(source, actions: rowActions)
                            }
                        }
                    }
                } else {
                    ForEach(displayedSources) { source in
                        sourceRowListEntry(source, actions: rowActions)
                    }
                }
            }
            .listStyle(.plain)
            // Hiding the list's own background is only half of it: a `.plain` row still
            // paints an opaque `systemBackground` unless it is handed a row background,
            // which left the source rows as a white slab between the glass search bar
            // above and the toolbar below. Every row instead wears `interfaceSectionSurface`,
            // so the list follows 毛玻璃／分組卡片／透明度 like the rest of the screen. Same
            // treatment in 語音朗讀設定, which is built from the same list + bottom-bar shell.
            .scrollContentBackground(.hidden)
            .onChange(of: scrollTargetId) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTargetId = nil
            }
        }
    }

    /// Only the row modifiers live here — the row itself is `BookSourceRow`, a separate
    /// `View` struct so `List` defers building its menus and rotor actions until the row
    /// scrolls in. See the note at the top of `BookSourceRowViews.swift`.
    private func sourceRowListEntry(
        _ source: BookSource, actions: BookSourceRowActions
    ) -> some View {
        BookSourceRow(
            source: source,
            isSelected: selectedIds.contains(source.id),
            pin: store.pinRecord(for: source.id)?.position,
            health: healthChecker.healthById[source.id],
            defaultGroupName: defaultGroupName,
            actions: actions
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.visible)
        .interfaceSectionSurface()
    }

    // MARK: - Row & Group Actions

    /// Built once per body evaluation and shared by every row, so constructing a row costs
    /// a handful of closure retains instead of reaching back into this view's state.
    private var rowActions: BookSourceRowActions {
        BookSourceRowActions(
            toggleSelection: { self.toggleSelection($0) },
            toggleEnabled: { self.store.toggle(id: $0) },
            showInfo: { self.infoSource = $0 },
            test: { self.presentCheckOptions(for: [$0]) },
            edit: { self.editingSource = $0 },
            copyJSON: { self.copySourceJSON($0) },
            login: { self.loginSource = $0 },
            editVariables: { self.variableEditingSource = $0 },
            applyGroupName: { self.applyGroupName($0, to: $1) },
            pickGroup: { self.beginPickingGroup(for: $0) },
            moveToNewGroup: { self.beginMovingToNewGroup($0) },
            pinToTop: { self.pinSourceToTop($0) },
            pinToBottom: { self.pinSourceToBottom($0) },
            unpin: { self.unpinSource($0, announcement: $1) },
            delete: { source in
                self.selectedIds.remove(source.id)
                self.store.delete(id: source.id)
            }
        )
    }

    private var groupActions: BookSourceGroupActions {
        BookSourceGroupActions(
            toggleExpansion: { self.toggleGroupExpansion($0) },
            rename: { self.beginRenamingGroup($0) },
            pickMergeTarget: { self.beginPickingMergeTarget(for: $0) },
            setEnabled: { self.store.setEnabledByUser(ids: $0, enabled: $1) },
            select: { self.selectedIds.formUnion($0) },
            copyToPasteboard: { self.copyGroupToPasteboard($0) },
            delete: { group in
                self.deletingGroup = PendingGroupAction(
                    id: group.id, name: group.name, sourceIds: group.sourceIds)
            }
        )
    }

    private func toggleGroupExpansion(_ id: String) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            if expandedGroups.contains(id) {
                expandedGroups.remove(id)
            } else {
                expandedGroups.insert(id)
            }
        }
    }

    // MARK: - Group Operations

    private func beginRenamingGroup(_ group: BookSourceRowGroup) {
        // 默認分組 is a display-only label for sources with no group, so the field starts
        // empty rather than pre-filled with a name that was never stored.
        groupNameText = group.name == defaultGroupName ? "" : group.name
        groupNaming = PendingGroupNaming(
            id: group.id,
            title: localized("重命名分組"),
            subtitle: group.name + " · \(group.sources.count) " + localized("個書源"),
            sourceIds: group.sourceIds,
            currentName: group.name
        )
    }

    /// 移動到分組 ▸ 新增分組… — typing an existing group's name merges the source into it,
    /// so this doubles as "move somewhere not in the list".
    private func beginMovingToNewGroup(_ source: BookSource) {
        groupNameText = ""
        groupNaming = PendingGroupNaming(
            id: source.id.uuidString,
            title: localized("移動到新分組"),
            subtitle: source.bookSourceName.isEmpty
                ? localized("未命名書源") : source.bookSourceName,
            sourceIds: [source.id],
            currentName: source.bookSourceGroup
        )
    }

    private func commitGroupNaming() {
        guard let pending = groupNaming else { return }
        groupNaming = nil
        let trimmed = groupNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != pending.currentName else { return }
        applyGroupName(trimmed, to: pending.sourceIds)
    }

    /// 移動到分組 for one source — opens the searchable group list.
    private func beginPickingGroup(for source: BookSource) {
        let current = source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        groupPicking = PendingGroupPick(
            id: source.id.uuidString,
            title: localized("移動到分組"),
            subtitle: source.bookSourceName.isEmpty
                ? localized("未命名書源") : source.bookSourceName,
            sourceIds: [source.id],
            candidates: groupCandidates(excluding: current),
            excluded: current,
            // Only a source that has a group can leave it.
            defaultGroupTitle: current.isEmpty ? nil : localized("移出分組"),
            allowsNewGroup: true
        )
    }

    /// 合併到其他分組 for a whole group — the same sheet, minus 新增分組 (重命名分組 covers
    /// moving a group to a name that doesn't exist yet).
    private func beginPickingMergeTarget(for group: BookSourceRowGroup) {
        groupPicking = PendingGroupPick(
            id: group.id,
            title: localized("合併到其他分組"),
            subtitle: group.name + " · \(group.sources.count) " + localized("個書源"),
            sourceIds: group.sourceIds,
            candidates: groupCandidates(excluding: group.name),
            excluded: group.name,
            defaultGroupTitle: group.name == defaultGroupName ? nil : defaultGroupName,
            allowsNewGroup: false
        )
    }

    private func groupCandidates(excluding excluded: String) -> [BookSourceGroupCandidate] {
        store.groupCounts(excluding: excluded).map {
            BookSourceGroupCandidate(name: $0.name, count: $0.count)
        }
    }

    /// Single write path for 重命名分組 and 合併到其他分組. The built-in default group has no
    /// stored name, so landing there means clearing `bookSourceGroup`.
    private func applyGroupName(_ name: String, to ids: Set<UUID>) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            store.setGroup(name == defaultGroupName ? "" : name, ids: ids)
        }
    }

    private func copyGroupToPasteboard(_ group: BookSourceRowGroup) {
        let json = store.exportToJSON(ids: Array(group.sourceIds))
        UIPasteboard.general.string = json
        withAnimation {
            importSuccess =
                localized("已複製") + " \(group.sources.count) " + localized("個書源到剪貼簿")
        }
    }

    private func deleteGroup(_ pending: PendingGroupAction) {
        selectedIds.subtract(pending.sourceIds)
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            // Discard the removed count explicitly: without it the closure's implicit
            // return makes `withAnimation` itself yield a value nobody reads.
            _ = store.delete(ids: pending.sourceIds)
        }
    }

    // MARK: - Bottom Toolbar
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            Button {
                toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: selectedIds.count == filteredSources.count
                            && !filteredSources.isEmpty
                            ? "checkmark.square.fill" : "square"
                    )
                    .font(DSFont.fixed(size: 18))
                    .foregroundColor(
                        selectedIds.count == filteredSources.count && !filteredSources.isEmpty
                            ? DSColor.accent : Color(UIColor.systemGray3))
                    .accessibilityHidden(true)
                    Text(localized("全選") + "(\(selectedIds.count)/\(store.sources.count))")
                        .font(DSFont.fixed(size: 13))
                        .foregroundColor(DSColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .accessibilityLabel(localized("全選"))
            .accessibilityValue("\(selectedIds.count)/\(store.sources.count)")

            Spacer()

            Button {
                invertSelection()
            } label: {
                Text(localized("反選"))
                    .font(DSFont.fixed(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer().frame(width: 10)

            Button {
                if !selectedIds.isEmpty {
                    showDeleteConfirm = true
                }
            } label: {
                Text(localized("刪除"))
                    .font(DSFont.fixed(size: 13))
                    .foregroundColor(selectedIds.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty)

            Spacer().frame(width: 10)

            Menu {
                Button {
                    enableSelected()
                } label: {
                    Label(localized("啟用選中"), systemImage: "checkmark.circle")
                }
                .disabled(selectedIds.isEmpty)
                Button {
                    disableSelected()
                } label: {
                    Label(localized("停用選中"), systemImage: "xmark.circle")
                }
                .disabled(selectedIds.isEmpty)
                Divider()
                Button {
                    presentCheckOptions()
                } label: {
                    Label(localized("書源驗證"), systemImage: "stethoscope")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(90))
            }
            .accessibilityLabel(localized("更多"))
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        // `.bar` — the same system toolbar material RSS 訂閱, 線上書詳情 and 聽書 use for
        // their bottom bars, and it honours Reduce Transparency on its own. A hardcoded
        // `systemBackground` made this bar the one piece of chrome that stayed flat white
        // no matter what the list above was wearing.
        .background(.bar)
    }

    // MARK: - Batch Operations

    private func copySourceJSON(_ source: BookSource) {
        guard let data = try? JSONEncoder().encode(source),
              let str = String(data: data, encoding: .utf8)
        else { return }
        UIPasteboard.general.string = str
        withAnimation { importSuccess = localized("已複製書源 JSON") }
    }

    // MARK: - Pinning

    /// The row leaves the viewport when it jumps to the other end of a long list, which reads
    /// as "the source disappeared", so pinning and unpinning both scroll the row back into
    /// view and announce the outcome for VoiceOver (the merged row can't show its new
    /// position on its own).
    private func pinSourceToTop(_ source: BookSource) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            store.pinToTop(id: source.id)
        }
        scrollTargetId = source.id
        UIAccessibility.post(notification: .announcement, argument: localized("已置頂"))
    }

    private func pinSourceToBottom(_ source: BookSource) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            store.pinToBottom(id: source.id)
        }
        scrollTargetId = source.id
        UIAccessibility.post(notification: .announcement, argument: localized("已置底"))
    }

    private func unpinSource(_ source: BookSource, announcement: String) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            store.unpin(id: source.id)
        }
        scrollTargetId = source.id
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func toggleSelectAll() {
        let allIds = Set(filteredSources.map { $0.id })
        if selectedIds == allIds {
            selectedIds.removeAll()
        } else {
            selectedIds = allIds
        }
    }

    private func invertSelection() {
        let allIds = Set(filteredSources.map { $0.id })
        selectedIds = allIds.subtracting(selectedIds)
    }

    private func deleteSelected() {
        let idsToDelete = selectedIds
        selectedIds.removeAll()
        store.delete(ids: idsToDelete)
    }

    private func enableSelected() {
        store.setEnabledByUser(ids: selectedIds, enabled: true)
    }

    private func disableSelected() {
        store.setEnabledByUser(ids: selectedIds, enabled: false)
    }

    private func presentCheckOptions() {
        presentCheckOptions(for: checkSources)
    }

    /// 測試書源 for an explicit set — one row's menu, or the toolbar's selection/enabled set.
    private func presentCheckOptions(for sources: [BookSource]) {
        guard !sources.isEmpty else { return }
        pendingCheckSources = sources
        showCheckOptions = true
    }

    private func startCheck(with policy: BookSourceCheckPolicy, sources: [BookSource]) {
        guard !sources.isEmpty else { return }
        healthChecker.policy = policy
        healthChecker.prepare(sources: sources)
        showSourceCheck = true
        Task {
            await healthChecker.runAll()
            if !showSourceCheck {
                let passed = healthChecker.items.filter { $0.overallPass }.count
                var msg = "\(localized("驗證完成"))：\(passed)/\(healthChecker.items.count) \(localized("通過"))"
                if let summary = healthChecker.lastSummary {
                    msg += "，\(summary)"
                }
                withAnimation { checkToast = msg }
            }
        }
    }

    private func enableAll() {
        store.setEnabledByUser(ids: Set(store.sources.map(\.id)), enabled: true)
    }

    private func disableAll() {
        store.setEnabledByUser(ids: Set(store.sources.map(\.id)), enabled: false)
    }

    private func copySelectedToPasteboard() {
        let json = store.exportToJSON(ids: Array(selectedIds))
        UIPasteboard.general.string = json
        withAnimation { importSuccess = localized("已複製") + " \(selectedIds.count) " + localized("個書源到剪貼簿") }
    }

    private func copyAllToPasteboard() {
        let json = store.exportToJSON()
        UIPasteboard.general.string = json
        withAnimation { importSuccess = localized("已複製全部") + " \(store.sources.count) " + localized("個書源到剪貼簿") }
    }

    // MARK: - Empty State
    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.circle")
                .font(DSFont.fixed(size: 64))
                .foregroundColor(Color.secondary.opacity(0.35))
            Text(localized("尚無書源"))
                .font(DSFont.title2.weight(.semibold))
            Text(localized("點擊右上角 + 手動新增\n或匯入 Legado 書源 JSON"))
                .font(DSFont.subheadline).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showImport = true
            } label: {
                Label(localized("匯入書源 JSON"), systemImage: "square.and.arrow.down")
                    .font(DSFont.headline).foregroundColor(.white)
                    .padding(.horizontal, 28).padding(.vertical, 13)
                    .background(DSColor.accent).clipShape(Capsule())
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Import Sheet
    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundColor(DSColor.accent)
                    Text(localized("貼上 Legado 格式的書源 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextEditor(text: $importJSON)
                    .font(DSFont.fixed(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .frame(maxHeight: 280)

                Button {
                    showImportFile = true
                } label: {
                    Label(localized("從文件選取 .json"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                Spacer()
            }
            .navigationTitle(localized("匯入書源"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showImport = false
                        importJSON = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        doImport(importJSON)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(importJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fileImporter(
            isPresented: $showImportFile,
            allowedContentTypes: [UTType.json, UTType.plainText,
                                  UTType(filenameExtension: "yds") ?? .data,
                                  UTType(filenameExtension: "xbs") ?? .data,
                                  UTType(filenameExtension: "mrs") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    doImportData(data, ext: url.pathExtension)
                } else {
                    importError = localized("無法讀取文件")
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
    }

    private func doImportData(_ data: Data, ext: String) {
        do {
            let count = try store.importFromData(data, fileExtension: ext)
            withAnimation {
                importSuccess = localized("成功匯入") + " \(count) " + localized("個書源")
                importJSON = ""
                showImport = false
            }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    private func doImport(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let count = try store.importFromJSON(trimmed)
            withAnimation {
                importSuccess = localized("成功匯入") + " \(count) " + localized("個書源")
                importJSON = ""
                showImport = false
            }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    // MARK: - Network Import Sheet

    private var networkImportSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundColor(DSColor.accent)
                    Text(localized("輸入書源 JSON 的網路地址，支援直接返回 JSON 的 URL。"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextField("https://example.com/booksource.json", text: $importURLString)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                if networkImportLoading {
                    ProgressView()
                        .padding(.top, 24)
                }

                Spacer()
            }
            .navigationTitle(localized("網路導入"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNetworkImport = false
                        importURLString = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        doNetworkImport()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(
                        importURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || networkImportLoading)
                }
            }
        }
    }

    private func doNetworkImport() {
        let urlString = importURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            withAnimation { importError = localized("無效的 URL") }
            return
        }
        networkImportLoading = true
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                networkImportLoading = false
                if let err = error {
                    withAnimation { importError = err.localizedDescription }
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    withAnimation { importError = localized("無法解析伺服器回應") }
                    return
                }
                showNetworkImport = false
                importURLString = ""
                doImport(text)
            }
        }.resume()
    }

    /// 粘貼源: imports the clipboard's book-source JSON (or fetches it when the
    /// clipboard holds a URL), through the same single import path as 本地導入.
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            withAnimation { importError = localized("剪貼簿為空") }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            importURLString = trimmed
            doNetworkImport()
            return
        }
        do {
            let count = try store.importFromJSON(trimmed)
            withAnimation { importSuccess = localized("成功匯入") + " \(count) " + localized("個書源") }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    // MARK: - Utilities
    private var messageAlertTitle: String {
        if importError != nil { return localized("操作失敗") }
        if checkToast != nil { return localized("書源驗證") }
        return localized("完成")
    }
}

#Preview {
    BookSourceListView()
}
