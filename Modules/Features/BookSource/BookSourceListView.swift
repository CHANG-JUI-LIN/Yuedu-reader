import SwiftUI
import UniformTypeIdentifiers

private enum BookSourceImportPresentationRoute: Hashable {
    /// 手動新增 — an empty source in the editor. Sequenced with the imports because it is now
    /// reached from the same 「+」 menu, and on iOS 17 that menu can swallow its sheet too.
    case add
    case local
    case network
}

private enum BookSourceFileImportRoute: Hashable {
    case document
}

// MARK: - Book Source List (Legado Style)

struct BookSourceListView: View {
    var embedsNavigationStack = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var bookStore: BookStore
    /// Not observed: everything the screen draws from the library comes from `model`, which
    /// rebuilds once per library change instead of once per render.
    private let store: BookSourceStore
    @StateObject private var model: BookSourceManagementModel
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showAdd = false
    @State private var editingSource: BookSource? = nil
    @State private var showImport = false
    @State private var showImportFile = false
    @State private var showFirstLevelImportFile = false
    @State private var bookSourceFileImportSequence =
        DismissalSequencedPresentation<BookSourceFileImportRoute>()
    @State private var importJSON = ""
    @State private var importError: String? = nil
    @State private var importSuccess: String? = nil
    @State private var showNetworkImport = false
    /// Owns the import confirmation list for every manual route into this screen.
    @StateObject private var importCoordinator = BookSourceImportCoordinator()
    /// Parsed sources waiting for the sheet in front of them to finish dismissing before the
    /// confirmation list can be presented. Same ordering constraint as 書源驗證 below.
    @State private var queuedImportSources: [BookSource]?
    @State private var importURLString = ""
    @State private var networkImportLoading = false
    @State private var showLegacyImportChooser = false
    @State private var legacyImportSequence =
        DismissalSequencedPresentation<BookSourceImportPresentationRoute>()
    @State private var loginSource: BookSource? = nil
    @State private var variableEditingSource: BookSource? = nil
    @Environment(\.presentationMode) var dismiss

    @State private var showDeleteConfirm = false
    @State private var showMoreMenu = false
    @State private var showSourceCheck = false
    /// The sources a 書源驗證 options sheet was opened for, frozen when it was opened and
    /// handed to the sheet as its item. The sheet used to read a separate `@State` array
    /// that `body` never read, so SwiftUI built the sheet from the previous render's
    /// snapshot — the first time, an empty array: 「將對 0 個書源」 and a disabled 開始驗證.
    @State private var pendingCheck: PendingSourceCheck? = nil
    /// Set by 開始驗證; the run starts once the options sheet has fully dismissed.
    @State private var confirmedCheck: ConfirmedSourceCheck? = nil
    @State private var showGroupByDomainConfirm = false
    // Shared instance so a check keeps running in the background after this screen is dismissed.
    @ObservedObject private var healthChecker: BookSourceHealthChecker
    @State private var checkToast: String? = nil
    @State private var showDisclaimer = false
    /// Pending 重命名分組 / 移動到新分組 text entry, plus its draft name.
    @State private var groupNaming: PendingGroupNaming? = nil
    @State private var groupNameText = ""
    /// Group the 刪除該分組 confirmation is about to delete.
    @State private var deletingGroup: PendingGroupAction? = nil
    /// Pending 移動到分組 / 合併到其他分組 pick, shown as a searchable group list.
    @State private var groupPicking: PendingGroupPick? = nil
    /// Source shown in the read-only 查看詳情 sheet.
    @State private var infoSource: BookSource? = nil
    /// 匯出 payload waiting for this screen's first-level share sheet. Book-source
    /// management is pushed before iOS 18, so this sheet is a first-level
    /// presentation. See `MenuShareLinkPresentationPolicy`.
    @State private var pendingExport: PendingShareExport<BookSourceExportFile>? = nil

    /// `store` and `healthChecker` are injectable so scale tests can drive a
    /// 50,000-source library without touching the user's own.
    init(
        embedsNavigationStack: Bool = true,
        store: BookSourceStore = .shared,
        healthChecker: BookSourceHealthChecker? = nil
    ) {
        let healthChecker = healthChecker ?? .shared
        self.embedsNavigationStack = embedsNavigationStack
        self.store = store
        _healthChecker = ObservedObject(wrappedValue: healthChecker)
        _model = StateObject(
            wrappedValue: BookSourceManagementModel(store: store, healthChecker: healthChecker))
    }

    /// What 書源驗證 runs on: the selection, or every enabled source when nothing is selected.
    private var checkSources: [BookSource] {
        let selected = model.selectedIDs
        if !selected.isEmpty {
            return store.sources.filter { selected.contains($0.id) }
        } else {
            return store.sources.filter { $0.enabled }
        }
    }

    private struct PendingSourceCheck: Identifiable {
        let id = UUID()
        let sources: [BookSource]
    }

    private struct ConfirmedSourceCheck {
        let policy: BookSourceCheckPolicy
        let sources: [BookSource]
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
        model.defaultGroupName
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
                    if model.counts.total == 0 {
                        emptyView
                    } else {
                        sourceList
                    }

                    Divider()

                    bottomToolbar
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .navigationTitle(localized("來源配置管理"))
            .toolbarTitleDisplayMode(.inline)
            .pageBackgroundToolbar(for: .settings)
            .searchable(
                text: $model.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索來源配置")
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
                            if !model.selectedIDs.isEmpty {
                                BookSourceExportShareLink(
                                    label: localized("匯出選中"),
                                    filenameLabel: localized("選中來源配置"),
                                    sources: { [model, store] in
                                        let selected = model.selectedIDs
                                        return store.sources.filter { selected.contains($0.id) }
                                    },
                                    onHandoff: { pendingExport = $0 }
                                )
                            }
                            BookSourceExportShareLink(
                                label: localized("匯出全部"),
                                filenameLabel: localized("全部來源配置"),
                                sources: { [store] in store.sources },
                                onHandoff: { pendingExport = $0 }
                            )
                            Divider()
                            Button {
                                copySelectedToPasteboard()
                            } label: {
                                Label(localized("複製選中到剪貼簿"), systemImage: "doc.on.doc")
                            }
                            .disabled(model.selectedIDs.isEmpty)
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
                            Label(localized("來源配置驗證"), systemImage: "stethoscope")
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
                        title: localized("新增來源配置"),
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
            .sheet(item: $pendingExport) { export in
                ShareExportSheet(export: export)
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
            .sheet(
                isPresented: $showImport,
                onDismiss: handleImportSheetDismissal
            ) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    importSheet
                }
            }
            .fileImporter(
                isPresented: $showFirstLevelImportFile,
                allowedContentTypes: bookSourceImportContentTypes,
                onCompletion: handleBookSourceImportFile
            )
            .sheet(
                isPresented: $showNetworkImport,
                onDismiss: presentQueuedImportReview
            ) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    networkImportSheet
                }
            }
            .sheet(item: $importCoordinator.pending) { _ in
                BookSourceImportReviewSheet(
                    coordinator: importCoordinator,
                    onConfirm: commitImportReview,
                    onCancel: { importCoordinator.cancel() }
                )
            }
            .sheet(item: $loginSource) { src in
                BookSourceLoginSheet(source: src) { loginSource = nil }
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
                        comment: SourceVariableEditing.comment(source: src),
                        initialValue: SourceVariableEditing.currentValue(for: src)
                    ) { newValue in
                        SourceVariableEditing.save(newValue, for: src)
                        return nil
                    }
                }
            }
            // Start (and open the results sheet) only AFTER the options sheet has fully
            // dismissed — presenting a second sheet on the same frame as the first dismisses
            // is unreliable in SwiftUI.
            .sheet(item: $pendingCheck, onDismiss: startConfirmedCheck) { pending in
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    BookSourceCheckOptionsView(
                        sourceCount: pending.sources.count,
                        initialPolicy: healthChecker.policy
                    ) { policy in
                        confirmedCheck = ConfirmedSourceCheck(policy: policy, sources: pending.sources)
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
                    importSuccess =
                        String(format: localized("已按域名分組 %d 個來源配置"), changed)
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
                Text(
                    String(
                        format: localized("確定要刪除選中的 %d 個來源配置嗎？"),
                        model.selectedIDs.count))
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
                        String(
                            format: localized("確定要刪除分組「%1$@」及其中的 %2$d 個來源配置嗎？"),
                            pending.name, pending.sourceIds.count))
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
                // The animation sits on a container around the `if`, scoped to the
                // capsule: declared on the list it would animate every row too, and
                // declared on the capsule it could not animate its own arrival.
                ZStack {
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
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                    }
                }
                .animation(DSAnimation.standard, value: healthChecker.isRunning)
            }
            .fullScreenCover(isPresented: $showDisclaimer) {
                SourceDisclaimerView {
                    gs.sourceDisclaimerAccepted = true
                    showDisclaimer = false
                }
            }
            .onAppear {
                if !gs.sourceDisclaimerAccepted {
                    showDisclaimer = true
                }
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
            .accessibilityLabel(localized("新增來源配置"))
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
            .accessibilityLabel(localized("新增來源配置"))
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

    /// Rows are built only while on screen — see `HostedCollectionList` for why this is not
    /// a SwiftUI `List` any more. The rows themselves are unchanged SwiftUI views.
    private var sourceList: some View {
        let rowActions = self.rowActions
        let groupActions = self.groupActions
        return HostedCollectionList(
            items: model.items,
            contentVersion: model.contentVersion,
            animatesItemChanges: model.animatesItemChange,
            scrollRequest: model.scrollRequest,
            showsSeparator: { item in
                if case .source = item { return true }
                return false
            },
            usesSystemMargins: { $0 == .header },
            // Every row wears the 毛玻璃／分組卡片／透明度 surface across the whole cell, like
            // a `List` row's `interfaceSectionSurface()`. The header stays clear: its stats
            // card and page buttons paint their own.
            drawsCellSurface: { $0 != .header }
        ) { item in
            switch item {
            case .header:
                SourceValidationListHeader(
                    counts: model.counts,
                    filter: $model.filter,
                    grouped: $gs.bookSourceListGrouped
                )
            case .group(let id):
                if let group = model.group(id) {
                    BookSourceGroupHeaderRow(
                        group: group,
                        expanded: model.isExpanded(id),
                        actions: groupActions
                    )
                    .padding(.horizontal, DSSpacing.md)
                }
            case .source(let id):
                if let source = model.source(for: id) {
                    BookSourceRow(
                        source: source,
                        isSelected: model.isSelected(id),
                        pin: model.pin(for: id),
                        health: healthChecker.healthById[id],
                        defaultGroupName: defaultGroupName,
                        actions: rowActions
                    )
                }
            }
        }
        // Scroll under the navigation and search bars like a `List` does; the collection
        // view insets its content by the safe area it now overlaps.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Row & Group Actions

    /// Built once per body evaluation and shared by every row, so constructing a row costs
    /// a handful of closure retains instead of reaching back into this view's state.
    private var rowActions: BookSourceRowActions {
        BookSourceRowActions(
            toggleSelection: { self.model.toggleSelection($0) },
            toggleEnabled: { self.store.toggle(id: $0) },
            showInfo: { self.infoSource = $0 },
            test: { self.presentCheckOptions(for: [$0]) },
            edit: { self.editingSource = $0 },
            copyJSON: { self.copySourceJSON($0) },
            export: { self.pendingExport = $0 },
            login: { self.loginSource = $0 },
            editVariables: { self.variableEditingSource = $0 },
            applyGroupName: { self.applyGroupName($0, to: $1) },
            pickGroup: { self.beginPickingGroup(for: $0) },
            moveToNewGroup: { self.beginMovingToNewGroup($0) },
            pinToTop: { self.pinSourceToTop($0) },
            pinToBottom: { self.pinSourceToBottom($0) },
            unpin: { self.unpinSource($0, announcement: $1) },
            delete: { source in
                self.model.deselect([source.id])
                self.store.delete(id: source.id)
            }
        )
    }

    private var groupActions: BookSourceGroupActions {
        BookSourceGroupActions(
            toggleExpansion: { self.model.toggleExpansion($0) },
            rename: { self.beginRenamingGroup($0) },
            pickMergeTarget: { self.beginPickingMergeTarget(for: $0) },
            setEnabled: { self.store.setEnabledByUser(ids: $0, enabled: $1) },
            select: { self.model.select($0) },
            copyToPasteboard: { self.copyGroupToPasteboard($0) },
            export: { self.pendingExport = $0 },
            delete: { group in
                self.deletingGroup = PendingGroupAction(
                    id: group.id, name: group.name, sourceIds: group.sourceIds)
            },
            resolveSources: { self.model.sources(for: $0) }
        )
    }

    // MARK: - Group Operations

    private func beginRenamingGroup(_ group: BookSourceRowGroup) {
        // 默認分組 is a display-only label for sources with no group, so the field starts
        // empty rather than pre-filled with a name that was never stored.
        groupNameText = group.name == defaultGroupName ? "" : group.name
        groupNaming = PendingGroupNaming(
            id: group.id,
            title: localized("重命名分組"),
            subtitle: String(
                format: localized("%1$@ · %2$d 個來源配置"), group.name, group.sourceIDs.count),
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
                ? localized("未命名來源配置") : source.bookSourceName,
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
                ? localized("未命名來源配置") : source.bookSourceName,
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
            subtitle: String(
                format: localized("%1$@ · %2$d 個來源配置"), group.name, group.sourceIDs.count),
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
        model.animateNextLibraryChange()
        store.setGroup(name == defaultGroupName ? "" : name, ids: ids)
    }

    private func copyGroupToPasteboard(_ group: BookSourceRowGroup) {
        let json = store.exportToJSON(ids: group.sourceIDs)
        UIPasteboard.general.string = json
        importSuccess = String(
            format: localized("已複製 %d 個來源配置到剪貼簿"), group.sourceIDs.count)
    }

    private func deleteGroup(_ pending: PendingGroupAction) {
        model.deselect(pending.sourceIds)
        model.animateNextLibraryChange()
        // Discard the removed count explicitly: the result is only for callers that report it.
        _ = store.delete(ids: pending.sourceIds)
    }

    // MARK: - Bottom Toolbar

    /// 全選 (本頁已選/本頁總數): every count and action here is scoped to the current page —
    /// 全部／抓取異常／正文異常 plus the search text. 全選 on 抓取異常 used to select the whole
    /// library, one tap away from deleting all of it.
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            Button {
                model.toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: model.isPageFullySelected
                            ? "checkmark.square.fill" : "square"
                    )
                    .font(DSFont.fixed(size: 18))
                    .foregroundColor(
                        model.isPageFullySelected
                            ? DSColor.accent : Color(UIColor.systemGray3))
                    .accessibilityHidden(true)
                    Text(localized("全選") + "(\(model.pageSelectedCount)/\(model.pageCount))")
                        .font(DSFont.fixed(size: 13))
                        .foregroundColor(DSColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .accessibilityLabel(localized("全選"))
            .accessibilityValue("\(model.pageSelectedCount)/\(model.pageCount)")

            Spacer()

            Button {
                model.invertSelection()
            } label: {
                Text(localized("反選"))
                    .font(DSFont.fixed(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(DSColor.textPrimary)
            }
            .buttonStyle(.plain)

            Spacer().frame(width: 10)

            Button {
                if !model.selectedIDs.isEmpty {
                    showDeleteConfirm = true
                }
            } label: {
                Text(localized("刪除"))
                    .font(DSFont.fixed(size: 13))
                    .foregroundColor(model.selectedIDs.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedIDs.isEmpty)

            Spacer().frame(width: 10)

            Menu {
                Button {
                    enableSelected()
                } label: {
                    Label(localized("啟用選中"), systemImage: "checkmark.circle")
                }
                .disabled(model.selectedIDs.isEmpty)
                Button {
                    disableSelected()
                } label: {
                    Label(localized("停用選中"), systemImage: "xmark.circle")
                }
                .disabled(model.selectedIDs.isEmpty)
                Divider()
                Button {
                    presentCheckOptions()
                } label: {
                    Label(localized("來源配置驗證"), systemImage: "stethoscope")
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
        importSuccess = localized("已複製來源配置 JSON")
    }

    // MARK: - Pinning

    /// The row leaves the viewport when it jumps to the other end of a long list, which reads
    /// as "the source disappeared", so pinning and unpinning both scroll the row back into
    /// view and announce the outcome for VoiceOver (the merged row can't show its new
    /// position on its own).
    private func pinSourceToTop(_ source: BookSource) {
        model.animateNextLibraryChange()
        model.revealAfterNextRebuild(source.id)
        store.pinToTop(id: source.id)
        UIAccessibility.post(notification: .announcement, argument: localized("已置頂"))
    }

    private func pinSourceToBottom(_ source: BookSource) {
        model.animateNextLibraryChange()
        model.revealAfterNextRebuild(source.id)
        store.pinToBottom(id: source.id)
        UIAccessibility.post(notification: .announcement, argument: localized("已置底"))
    }

    private func unpinSource(_ source: BookSource, announcement: String) {
        model.animateNextLibraryChange()
        model.revealAfterNextRebuild(source.id)
        store.unpin(id: source.id)
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func deleteSelected() {
        let idsToDelete = model.selectedIDs
        model.clearSelection()
        store.delete(ids: idsToDelete)
    }

    private func enableSelected() {
        store.setEnabledByUser(ids: model.selectedIDs, enabled: true)
    }

    private func disableSelected() {
        store.setEnabledByUser(ids: model.selectedIDs, enabled: false)
    }

    private func presentCheckOptions() {
        presentCheckOptions(for: checkSources)
    }

    /// 測試書源 for an explicit set — one row's menu, or the toolbar's selection/enabled set.
    private func presentCheckOptions(for sources: [BookSource]) {
        guard !sources.isEmpty else { return }
        confirmedCheck = nil
        pendingCheck = PendingSourceCheck(sources: sources)
    }

    private func startConfirmedCheck() {
        guard let confirmed = confirmedCheck else { return }
        confirmedCheck = nil
        startCheck(with: confirmed.policy, sources: confirmed.sources)
    }

    private func startCheck(with policy: BookSourceCheckPolicy, sources: [BookSource]) {
        guard !sources.isEmpty else { return }
        healthChecker.policy = policy
        var shelfTitles: [UUID: String] = [:]
        for book in bookStore.books where book.isOnline {
            guard let sourceID = book.bookSourceId else { continue }
            let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, shelfTitles[sourceID] == nil else { continue }
            shelfTitles[sourceID] = title
        }
        healthChecker.prepare(
            sources: sources,
            preferredSearchKeywords: shelfTitles
        )
        showSourceCheck = true
        Task {
            await healthChecker.runAll()
            if !showSourceCheck {
                let passed = healthChecker.passedCount
                var msg = "\(localized("驗證完成"))：\(passed)/\(healthChecker.items.count) \(localized("通過"))"
                if let summary = healthChecker.lastSummary {
                    msg += "，\(summary)"
                }
                checkToast = msg
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
        let json = store.exportToJSON(ids: Array(model.selectedIDs))
        UIPasteboard.general.string = json
        importSuccess = String(
            format: localized("已複製 %d 個來源配置到剪貼簿"), model.selectedIDs.count)
    }

    private func copyAllToPasteboard() {
        let json = store.exportToJSON()
        UIPasteboard.general.string = json
        importSuccess = String(
            format: localized("已複製全部 %d 個來源配置到剪貼簿"), store.sources.count)
    }

    // MARK: - Empty State
    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.circle")
                .font(DSFont.fixed(size: 64))
                .foregroundStyle(DSColor.textSecondary.opacity(0.35))
            Text(localized("尚無來源配置"))
                .font(DSFont.title2.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text(localized("點擊右上角 + 手動新增\n或匯入 Legado 來源配置 JSON"))
                .font(DSFont.subheadline).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showImport = true
            } label: {
                Label(localized("匯入來源配置 JSON"), systemImage: "square.and.arrow.down")
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
                    Text(localized("貼上 Legado 格式的來源配置 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。"))
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
                    requestBookSourceFileImport()
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
            .navigationTitle(localized("匯入來源配置"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        bookSourceFileImportSequence.cancel()
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
            allowedContentTypes: bookSourceImportContentTypes,
            onCompletion: handleBookSourceImportFile
        )
    }

    private var bookSourceImportContentTypes: [UTType] {
        [
            .json,
            .plainText,
            UTType(filenameExtension: "yds") ?? .data,
            UTType(filenameExtension: "xbs") ?? .data,
            UTType(filenameExtension: "mrs") ?? .data,
        ]
    }

    private func requestBookSourceFileImport() {
        if BookSourceImportPresentationPolicy.requiresFirstLevelImporter {
            bookSourceFileImportSequence.select(.document)
            showImport = false
        } else {
            showImportFile = true
        }
    }

    private func presentBookSourceFileImporterAfterSheetDismissal() {
        guard bookSourceFileImportSequence.consumeAfterDismissal() == .document else {
            return
        }
        showFirstLevelImportFile = true
    }

    private func handleBookSourceImportFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: url) else {
                importError = localized("無法讀取文件")
                return
            }
            doImportData(data, ext: url.pathExtension)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func doImportData(_ data: Data, ext: String) {
        do {
            queueImportReview(try store.parseForImport(data: data, fileExtension: ext))
        } catch {
            importError = error.localizedDescription
        }
    }

    private func doImport(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            queueImportReview(try store.parseForImport(json: trimmed))
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Import Review

    /// Nothing is written until the user confirms: every manual route parses, then shows the
    /// confirmation list. When a sheet is still on screen the list has to wait for its real
    /// `onDismiss` — presenting on the frame the previous sheet dismisses is unreliable, the
    /// same constraint 書源驗證 works around above.
    private func queueImportReview(_ sources: [BookSource]) {
        importJSON = ""
        if showImport || showNetworkImport {
            queuedImportSources = sources
            showImport = false
            showNetworkImport = false
        } else {
            importCoordinator.present(sources: sources)
        }
    }

    private func presentQueuedImportReview() {
        guard let sources = queuedImportSources else { return }
        queuedImportSources = nil
        importCoordinator.present(sources: sources)
    }

    /// The import sheet dismisses for two different reasons — the user picked 從文件選取, or a
    /// parsed pack is waiting for review. Only one is ever pending.
    private func handleImportSheetDismissal() {
        presentBookSourceFileImporterAfterSheetDismissal()
        presentQueuedImportReview()
    }

    private func commitImportReview() {
        do {
            let count = try importCoordinator.confirmImport()
            importSuccess = String(format: localized("成功匯入 %d 個來源配置"), count)
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Network Import Sheet

    private var networkImportSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundColor(DSColor.accent)
                    Text(localized("輸入來源配置 JSON 的網路地址，支援直接返回 JSON 的 URL。"))
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
            importError = localized("無效的 URL")
            return
        }
        networkImportLoading = true
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                networkImportLoading = false
                if let err = error {
                    importError = err.localizedDescription
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    importError = localized("無法解析伺服器回應")
                    return
                }
                importURLString = ""
                // `queueImportReview` closes this sheet and sequences the review list.
                doImport(text)
            }
        }.resume()
    }

    /// 粘貼源: imports the clipboard's book-source JSON (or fetches it when the
    /// clipboard holds a URL), through the same single import path as 本地導入.
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = localized("剪貼簿為空")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            importURLString = trimmed
            doNetworkImport()
            return
        }
        do {
            queueImportReview(try store.parseForImport(json: trimmed))
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Utilities
    private var messageAlertTitle: String {
        if importError != nil { return localized("操作失敗") }
        if checkToast != nil { return localized("來源配置驗證") }
        return localized("完成")
    }
}

#Preview {
    BookSourceListView()
        .environmentObject(BookStore())
}
