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
    /// Source shown in the read-only 查看詳情 sheet.
    @State private var infoSource: BookSource? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Leading slot for the 置頂／置底 pin icon, matching the old warning bar + checkbox
    /// padding so source names keep their horizontal position.
    private let pinSlotWidth = DSSpacing.lg + DSSpacing.xs

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

    /// Sentinel ids for the built-in 置頂／置底 groups — kept distinct from any user group
    /// name, so a group literally named 置頂 cannot collide with them.
    private static let topPinnedGroupID = "yuedu.pin-group.top"
    private static let bottomPinnedGroupID = "yuedu.pin-group.bottom"

    /// One row group in the management list. Every displayed source belongs to exactly one
    /// group: pinned sources land in the built-in 置頂／置底 groups, the rest use their
    /// `bookSourceGroup` — and sources without one land in the built-in 默認分組 (Legado's
    /// default group — ungrouped sources are never left flat).
    private struct BookSourceRowGroup: Identifiable {
        let id: String
        let name: String
        let sources: [BookSource]

        /// 置頂／置底 are synthetic buckets built from pin state, not from `bookSourceGroup`.
        /// Renaming, merging, or deleting "the group" is meaningless for them, so their menu
        /// only offers the operations that act on the member sources.
        var isPinGroup: Bool {
            id == BookSourceListView.topPinnedGroupID || id == BookSourceListView.bottomPinnedGroupID
        }

        var sourceIds: Set<UUID> { Set(sources.map(\.id)) }
    }

    /// A group snapshot frozen at the moment its menu item was tapped, so the delete alert
    /// acts on exactly what the user saw — the live list can be re-grouped by the very edit
    /// they are confirming.
    private struct PendingGroupAction: Identifiable {
        let id: String
        let name: String
        let sourceIds: Set<UUID>
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
                id: Self.topPinnedGroupID, name: localized("置頂組"), sources: topPinned))
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
                id: Self.bottomPinnedGroupID, name: localized("置底組"), sources: bottomPinned))
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
        if store.sources.contains(where: { store.pinRecord(for: $0.id)?.position == .top }) {
            ids.insert(Self.topPinnedGroupID)
        }
        if store.sources.contains(where: { store.pinRecord(for: $0.id)?.position == .bottom }) {
            ids.insert(Self.bottomPinnedGroupID)
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
                                exportShareLink(
                                    label: localized("匯出選中"),
                                    filenameLabel: localized("選中書源"),
                                    sources: store.sources.filter { selectedIds.contains($0.id) }
                                )
                            }
                            exportShareLink(
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
            .overlay(alignment: .top) {
                if let msg = importSuccess {
                    toastBanner(msg, color: .green)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { importSuccess = nil }
                            }
                        }
                }
                if let err = importError {
                    toastBanner(err, color: .red)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { importError = nil }
                            }
                        }
                }
                if let msg = checkToast {
                    toastBanner(msg, color: DSColor.accent)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { checkToast = nil }
                            }
                        }
                }
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

    /// Native share row for 匯出 …（儲存到「檔案」／AirDrop／…）. See `BookSourceExportFile` for
    /// why this is a `ShareLink` and not a `.fileExporter`.
    private func exportShareLink(
        label: String, filenameLabel: String, sources: [BookSource]
    ) -> some View {
        let file = BookSourceExportFile(
            filename: BookSourceExportFile.filename(for: filenameLabel), sources: sources)
        return ShareLink(item: file, preview: SharePreview(file.filename)) {
            Label(label, systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Source List
    private var sourceList: some View {
        ScrollViewReader { proxy in
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

                if usesGroupedLayout {
                    // Plain header row + conditional child rows instead of `DisclosureGroup`:
                    // SwiftUI pins its disclosure indicator to the trailing edge on iOS and
                    // offers no way to move it (row insets shift the label, not the chevron),
                    // and a custom `DisclosureGroupStyle` would collapse the whole group into
                    // one List row — losing per-source separators, insets, and lazy rows.
                    ForEach(displayedGroups) { group in
                        sourceGroupHeaderRow(group)
                        if expandedGroups.contains(group.id) {
                            ForEach(group.sources) { source in
                                sourceRowListEntry(source)
                            }
                        }
                    }
                } else {
                    ForEach(displayedSources) { source in
                        sourceRowListEntry(source)
                    }
                }
            }
            .listStyle(.plain)
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

    @ViewBuilder
    private func sourceRowListEntry(_ source: BookSource) -> some View {
        sourceRow(source: source)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.visible)
    }

    private func sourceGroupHeaderRow(_ group: BookSourceRowGroup) -> some View {
        sourceGroupHeader(group)
            .listRowInsets(
                EdgeInsets(top: 0, leading: DSSpacing.md, bottom: 0, trailing: DSSpacing.md))
            .listRowSeparator(.hidden)
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

    /// 「› 分組名 12 ⋯」 — the chevron leads the title (Legado's layout) and the whole title
    /// area toggles the group; the trailing menu holds the group-level operations.
    private func sourceGroupHeader(_ group: BookSourceRowGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        return HStack(spacing: DSSpacing.xs) {
            Button {
                toggleGroupExpansion(group.id)
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundColor(DSColor.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: DSSpacing.md)
                        .accessibilityHidden(true)
                    Text(group.name)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(group.sources.count)")
                        .font(DSFont.fixed(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name)，\(group.sources.count)")
            .accessibilityValue(localized(expanded ? "已展開" : "已收合"))
            .accessibilityHint(localized("點兩下展開或收合分組"))
            .accessibilityAddTraits(.isHeader)

            sourceGroupMenu(group)
        }
    }

    /// 分組操作 menu — Legado's group actions. Rename / merge / delete are hidden for the
    /// synthetic 置頂／置底 buckets, which have no `bookSourceGroup` to act on.
    private func sourceGroupMenu(_ group: BookSourceRowGroup) -> some View {
        Menu {
            if !group.isPinGroup {
                Button {
                    beginRenamingGroup(group)
                } label: {
                    Label(localized("重命名分組"), systemImage: "pencil")
                }
                let targets = mergeTargets(for: group)
                if !targets.isEmpty {
                    Menu {
                        ForEach(targets, id: \.self) { target in
                            Button(target) {
                                mergeGroup(group, into: target)
                            }
                        }
                    } label: {
                        Label(localized("合併到其他分組"), systemImage: "arrow.triangle.merge")
                    }
                }
                Divider()
            }
            Button {
                store.setEnabledByUser(ids: group.sourceIds, enabled: true)
            } label: {
                Label(localized("啟用全部"), systemImage: "play.circle")
            }
            Button {
                store.setEnabledByUser(ids: group.sourceIds, enabled: false)
            } label: {
                Label(localized("停用全部"), systemImage: "pause.circle")
            }
            Divider()
            Button {
                selectedIds.formUnion(group.sourceIds)
            } label: {
                Label(localized("選擇該分組"), systemImage: "checkmark.circle")
            }
            exportShareLink(
                label: localized("匯出該分組"),
                filenameLabel: group.name,
                sources: group.sources
            )
            Button {
                copyGroupToPasteboard(group)
            } label: {
                Label(localized("複製該分組到剪貼簿"), systemImage: "doc.on.doc")
            }
            if !group.isPinGroup {
                Divider()
                Button(role: .destructive) {
                    deletingGroup = PendingGroupAction(
                        id: group.id, name: group.name, sourceIds: group.sourceIds)
                } label: {
                    Label(localized("刪除該分組"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.toolbarIcon)
                .foregroundColor(DSColor.textSecondary)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("分組操作"))
    }

    // MARK: - Group Operations

    /// Groups this one can merge into: every other named group, plus the built-in default
    /// group (merging there just clears `bookSourceGroup`).
    private func mergeTargets(for group: BookSourceRowGroup) -> [String] {
        var targets = store.groupNames.filter { $0 != group.name }
        if group.name != defaultGroupName {
            targets.append(defaultGroupName)
        }
        return targets
    }

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

    /// 移動到分組 submenu for one source: the other existing groups, 移出分組, and a text
    /// entry for a group that doesn't exist yet.
    private func moveToGroupMenu(_ source: BookSource) -> some View {
        let current = source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = store.groupNames.filter { $0 != current }
        return Menu {
            ForEach(others, id: \.self) { name in
                Button(name) {
                    applyGroupName(name, to: [source.id])
                }
            }
            if !others.isEmpty {
                Divider()
            }
            if !current.isEmpty {
                Button {
                    applyGroupName(defaultGroupName, to: [source.id])
                } label: {
                    Label(localized("移出分組"), systemImage: "folder.badge.minus")
                }
            }
            Button {
                beginMovingToNewGroup(source)
            } label: {
                Label(localized("新增分組…"), systemImage: "folder.badge.plus")
            }
        } label: {
            Label(localized("移動到分組"), systemImage: "folder")
        }
    }

    private func mergeGroup(_ group: BookSourceRowGroup, into target: String) {
        applyGroupName(target, to: group.sourceIds)
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
            store.delete(ids: pending.sourceIds)
        }
    }

    /// One VoiceOver element per source.
    ///
    /// The row packs five separate controls (核取方塊 / 啟用開關 / 編輯 / 更多) around three
    /// lines of text, so unmerged it cost eight swipes per source and announced bare SF
    /// Symbol names ("square", "square.and.pencil", "ellipsis") for four of them. Merging
    /// means every control has to come back as a rotor action — see `sourceRotorActions`
    /// — and the 網址 moves to rotor custom content so it isn't re-read on every swipe.
    /// Rules in `docs/design.md` §7.
    @ViewBuilder
    private func sourceRow(source: BookSource) -> some View {
        let row = sourceRowContent(source: source)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sourceAccessibilityLabel(source))
            .accessibilityValue(sourceAccessibilityValue(source))
            .accessibilityAddTraits(sourceAccessibilityTraits(source))
            .accessibilityHint(localized("點兩下切換啟用狀態"))
            .accessibilityAction { store.toggle(id: source.id) }
            .accessibilityActions { sourceRotorActions(source) }

        if source.bookSourceUrl.isEmpty {
            row
        } else {
            row.accessibilityCustomContent(
                Text(localized("網址")),
                Text(source.bookSourceUrl)
            )
        }
    }

    /// The row's VoiceOver name: 書源名稱（分組）, matching the first visible line.
    private func sourceAccessibilityLabel(_ source: BookSource) -> String {
        let name = source.bookSourceName.isEmpty
            ? localized("未命名書源")
            : source.bookSourceName
        guard !source.bookSourceGroup.isEmpty else { return name }
        return "\(name)（\(source.bookSourceGroup)）"
    }

    /// State the row shows visually: the 啟用 toggle, the pin marker, and the validation badge.
    /// Selection is carried by the `.isSelected` trait instead, so it isn't said twice.
    private func sourceAccessibilityValue(_ source: BookSource) -> String {
        var parts = [localized(source.enabled ? "已啟用" : "已停用")]
        if let position = store.pinRecord(for: source.id)?.position {
            parts.append(localized(position == .top ? "已置頂" : "已置底"))
        }
        if let health = healthChecker.healthById[source.id]?.health {
            parts.append(sourceHealthText(health))
        }
        return parts.joined(separator: "，")
    }

    /// `.isSelected` is what carries the leading checkbox — VoiceOver says 「已選取」 for it,
    /// so the value line stays about 啟用 state only.
    private func sourceAccessibilityTraits(_ source: BookSource) -> AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if selectedIds.contains(source.id) {
            traits.insert(.isSelected)
        }
        return traits
    }

    private func sourceHealthText(_ health: SourceHealth) -> String {
        switch health {
        case .passed:       return localized("驗證通過")
        case .fetchError:   return localized("抓取異常")
        case .contentError: return localized("正文異常")
        }
    }

    /// Everything the row's buttons and menu can do, as rotor actions. Must stay in sync
    /// with the visible controls in `sourceRowContent` — the merged element is the only
    /// way VoiceOver can reach any of them.
    @ViewBuilder
    private func sourceRotorActions(_ source: BookSource) -> some View {
        Button(localized(selectedIds.contains(source.id) ? "取消選取" : "選取")) {
            toggleSelection(source.id)
        }
        Button(localized("查看詳情")) {
            infoSource = source
        }
        Button(localized("測試書源")) {
            presentCheckOptions(for: [source])
        }
        Button(localized("編輯")) {
            editingSource = source
        }
        Button(localized("複製 JSON")) {
            copySourceJSON(source)
        }
        if !source.loginUrl.isEmpty {
            Button(localized("Cookie 驗證登入")) {
                loginSource = source
            }
        }
        Button(localized("設置源變量")) {
            variableEditingSource = source
        }
        // The menu's 移動到分組 is a submenu of every group name, which a rotor can't express.
        // Typing the destination covers the same ground: an existing name merges into it.
        Button(localized("移動到新分組")) {
            beginMovingToNewGroup(source)
        }
        if !source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(localized("移出分組")) {
                applyGroupName(defaultGroupName, to: [source.id])
            }
        }
        if store.pinRecord(for: source.id)?.position == .top {
            Button(localized("取消置頂")) {
                unpinSource(source, announcement: localized("已取消置頂"))
            }
        } else {
            Button(localized("置頂")) {
                pinSourceToTop(source)
            }
        }
        if store.pinRecord(for: source.id)?.position == .bottom {
            Button(localized("取消置底")) {
                unpinSource(source, announcement: localized("已取消置底"))
            }
        } else {
            Button(localized("置底")) {
                pinSourceToBottom(source)
            }
        }
        Button(localized("刪除"), role: .destructive) {
            selectedIds.remove(source.id)
            store.delete(id: source.id)
        }
    }

    @ViewBuilder
    private func sourceRowContent(source: BookSource) -> some View {
        HStack(spacing: 0) {
            pinIndicator(for: source)

            Button {
                toggleSelection(source.id)
            } label: {
                Image(
                    systemName: selectedIds.contains(source.id) ? "checkmark.square.fill" : "square"
                )
                .font(DSFont.fixed(size: 20))
                .foregroundColor(
                    selectedIds.contains(source.id) ? DSColor.accent : Color(UIColor.systemGray3))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName.isEmpty ? localized("未命名書源") : source.bookSourceName)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(source.enabled ? .primary : .secondary)
                        .lineLimit(1)

                    if !source.bookSourceGroup.isEmpty {
                        Text("(\(source.bookSourceGroup))")
                            .font(DSFont.fixed(size: 13))
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                if !source.bookSourceUrl.isEmpty {
                    Text(source.bookSourceUrl)
                        .font(DSFont.fixed(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)
                }
                SourceValidationBadge(summary: healthChecker.healthById[source.id])
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "",
                isOn: Binding(
                    get: { source.enabled },
                    set: { _ in store.toggle(id: source.id) }
                )
            )
            .labelsHidden()
            .scaleEffect(0.85)
            .padding(.trailing, 4)

            Button {
                editingSource = source
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Menu {
                Button {
                    infoSource = source
                } label: {
                    Label(localized("查看詳情"), systemImage: "info.circle")
                }
                Button {
                    presentCheckOptions(for: [source])
                } label: {
                    Label(localized("測試書源"), systemImage: "stethoscope")
                }
                Button {
                    editingSource = source
                } label: {
                    Label(localized("編輯"), systemImage: "pencil")
                }
                if !source.loginUrl.isEmpty {
                    Button {
                        loginSource = source
                    } label: {
                        Label(localized("Cookie 驗證登入"), systemImage: "key.fill")
                    }
                }
                Button {
                    toggleSelection(source.id)
                } label: {
                    Label(
                        localized(selectedIds.contains(source.id) ? "取消選取" : "選取此書源"),
                        systemImage: selectedIds.contains(source.id)
                            ? "checkmark.circle.fill" : "checkmark.circle")
                }
                Divider()
                Button {
                    store.toggle(id: source.id)
                } label: {
                    Label(
                        localized(source.enabled ? "停用" : "啟用"),
                        systemImage: source.enabled ? "pause.circle" : "play.circle")
                }
                moveToGroupMenu(source)
                Button {
                    variableEditingSource = source
                } label: {
                    Label(localized("設置源變量"), systemImage: "curlybraces")
                }
                Divider()
                exportShareLink(
                    label: localized("匯出書源檔案"),
                    filenameLabel: source.bookSourceName.isEmpty
                        ? localized("未命名書源") : source.bookSourceName,
                    sources: [source]
                )
                Button {
                    copySourceJSON(source)
                } label: {
                    Label(localized("複製 JSON"), systemImage: "doc.on.doc")
                }
                Divider()
                if store.pinRecord(for: source.id)?.position == .top {
                    Button {
                        unpinSource(source, announcement: localized("已取消置頂"))
                    } label: {
                        Label(localized("取消置頂"), systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        pinSourceToTop(source)
                    } label: {
                        Label(localized("置頂"), systemImage: "arrow.up.to.line")
                    }
                }
                if store.pinRecord(for: source.id)?.position == .bottom {
                    Button {
                        unpinSource(source, announcement: localized("已取消置底"))
                    } label: {
                        Label(localized("取消置底"), systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        pinSourceToBottom(source)
                    } label: {
                        Label(localized("置底"), systemImage: "arrow.down.to.line")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    selectedIds.remove(source.id)
                    store.delete(id: source.id)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(90))
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 14)
        .opacity(source.enabled ? 1 : 0.6)
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
        .background(Color(UIColor.systemBackground))
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

    /// 置頂／置底 marker: a pin icon instead of the old warning-colored bar, so only sources
    /// the user explicitly pinned carry an indicator (the first unpinned source does not).
    @ViewBuilder
    private func pinIndicator(for source: BookSource) -> some View {
        if let record = store.pinRecord(for: source.id) {
            Image(systemName: "pin.fill")
                .font(DSFont.fixed(size: 12))
                .foregroundColor(DSColor.accent)
                .rotationEffect(.degrees(record.position == .bottom ? 180 : 0))
                .frame(width: pinSlotWidth)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: pinSlotWidth)
                .accessibilityHidden(true)
        }
    }

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

    // MARK: - Utilities
    @ViewBuilder
    private func toastBanner(_ msg: String, color: Color) -> some View {
        Text(msg)
            .font(DSFont.caption).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(color.opacity(0.9)).clipShape(Capsule())
            .padding(.top, 8)
    }
}

#Preview {
    BookSourceListView()
}
