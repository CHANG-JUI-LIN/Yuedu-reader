import SwiftUI

// MARK: - Results section

/// The 其他來源配置 section of a 換源 sheet — rows, progress, empty and error states — the same
/// on the reader's sheet and on 作品詳情's. Each row switches on a tap, and a long press offers
/// Legado's 置頂／置底／編輯來源配置／停用／刪除.
struct ChangeSourceResultsSection: View {
    @ObservedObject var search: ChangeSourceSearch
    /// The origin a tap is switching to, for its row's 正在載入目錄….
    var pendingOriginID: UUID?
    /// One switch at a time: a second tap would cancel the first.
    var isSwitching = false
    let onSelect: (BookOrigin) -> Void

    @State private var pendingDeletion: BookOrigin?

    var body: some View {
        let shown = search.displayedOrigins
        Section {
            if !shown.isEmpty {
                ForEach(shown) { origin in
                    row(origin)
                }
                if search.isSearching {
                    ChangeSourceProgressRow(progress: search.progress)
                }
            } else if search.isSearching {
                ChangeSourceProgressRow(progress: search.progress)
            } else if !search.origins.isEmpty {
                // 篩選 hid every result: say so, not 「暫無其他來源配置」.
                Text(localized("沒有符合篩選的來源配置"))
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                Text(localized("暫無其他來源配置"))
                    .foregroundStyle(DSColor.textSecondary)
            }
        } header: {
            Text(localized("其他來源配置"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if let err = search.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .dsSectionFooter(color: DSColor.destructive)
            }
        }
        .changeSourceEmptyGroupAlert(search: search)
    }

    private func row(_ origin: BookOrigin) -> some View {
        let key = ChangeSourceSearch.key(origin)
        return ChangeSourceOriginRow(
            origin: origin,
            lastChapter: search.lastChapter(of: origin),
            probe: search.probes[key],
            showsWordCount: search.loadWordCount,
            isProbing: search.probing.contains(key),
            isFailed: search.isFailed(origin),
            isPending: pendingOriginID == origin.id,
            kind: origin.inferredContentKind(),
            score: search.bookScore(of: origin),
            onScore: { search.setBookScore($0, for: origin) },
            action: { onSelect(origin) }
        )
        .disabled(isSwitching)
        .contextMenu {
            ChangeSourceSourceActions(search: search, sourceId: origin.sourceId) {
                pendingDeletion = origin
            }
        }
        .changeSourceDeleteConfirmation(
            sourceName: origin.sourceName,
            isPresented: Binding(
                get: { pendingDeletion?.id == origin.id },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            onDelete: { search.deleteSource(id: origin.sourceId) }
        )
    }
}

// MARK: - The source in use

/// 目前來源: where the book is read from now, checked. A 來源配置 there takes the same long
/// press as the results; deleting it is Legado's `deleteSource` on the book's own origin,
/// which switches to the first result that loads (`onDeletedCurrent`).
struct ChangeSourceCurrentSection: View {
    @ObservedObject var search: ChangeSourceSearch
    let name: String
    let lastChapter: String?
    /// The 來源配置 the book reads from; nil for a book read from anywhere else.
    let source: BookSource?
    let onDeletedCurrent: () -> Void

    @State private var confirmsDeletion = false

    var body: some View {
        Section(localized("目前來源")) {
            HStack {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(name)
                        .foregroundStyle(DSColor.textPrimary)
                    if let lastChapter, !lastChapter.isEmpty {
                        Text(lastChapter)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(DSFont.body.weight(.semibold))
                    .foregroundStyle(DSColor.accent)
                    // The tick is the visual form of 「使用中」; the `.isSelected` trait below
                    // says it, so leaving it focusable only got the symbol name read out.
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)
            .contextMenu {
                if let source {
                    ChangeSourceSourceActions(search: search, sourceId: source.id) {
                        confirmsDeletion = true
                    }
                }
            }
            .changeSourceDeleteConfirmation(
                sourceName: source?.bookSourceName ?? name,
                isPresented: $confirmsDeletion,
                onDelete: {
                    guard let source else { return }
                    search.deleteSource(id: source.id)
                    onDeletedCurrent()
                }
            )
        }
    }
}

// MARK: - Row

/// One origin: its 來源配置, the author it gave, its latest chapter, and with 加載字數 the
/// chapter it read; 👍/👎 on the trailing edge, then the switch state.
struct ChangeSourceOriginRow: View {
    let origin: BookOrigin
    let lastChapter: String
    let probe: ChangeSourceProbe?
    let showsWordCount: Bool
    let isProbing: Bool
    let isFailed: Bool
    let isPending: Bool
    let kind: OnlineBookContentKind
    let score: Int
    let onScore: (Int) -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: action) {
                HStack(spacing: DSSpacing.sm) {
                    details
                    Spacer(minLength: DSSpacing.xs)
                    status
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(accessibilityValue)
            .accessibilityAction(named: Text(localized(score > 0 ? "取消讚" : "讚"))) {
                onScore(score > 0 ? 0 : 1)
            }
            .accessibilityAction(named: Text(localized(score < 0 ? "取消踩" : "踩"))) {
                onScore(score < 0 ? 0 : -1)
            }
            scoreButtons
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(spacing: DSSpacing.sm) {
                Text(origin.sourceName)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                if let kindLabel = ChangeSourceKindLabel.text(for: kind) {
                    Text(kindLabel)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, DSSpacing.xxs)
                        .background(DSColor.surfaceTertiary, in: Capsule())
                }
            }
            let author = origin.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty {
                Text(author)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            // Aggregation sources share one sourceName across channels; the latest chapter
            // tells them apart.
            if !lastChapter.isEmpty {
                Text(lastChapter)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if showsWordCount, let line = ChangeSourceWordCountText.line(for: probe) {
                Text(line)
                    .font(DSFont.caption)
                    .foregroundStyle(probe?.wordCount == -1 ? DSColor.destructive : DSColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isPending {
            // The tap is being worked on. Without this the sheet sat completely unchanged
            // while the TOC downloaded, which reads as "nothing happened".
            HStack(spacing: DSSpacing.xs) {
                ProgressView()
                Text(localized("正在載入目錄…"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        } else if isFailed {
            Text(localized("載入失敗"))
                .font(DSFont.caption2)
                .foregroundStyle(DSColor.destructive)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xxs)
                .background(Capsule().fill(DSColor.destructive.opacity(0.12)))
        } else if isProbing {
            ProgressView()
                .accessibilityLabel(localized("正在載入"))
        } else {
            Image(systemName: "chevron.right")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .accessibilityHidden(true)   // 純裝飾，否則旁白念出 "chevron.right"
        }
    }

    /// Legado's 👍/👎: both while unscored, only the chosen one after; tapping it again clears.
    /// VoiceOver reaches them as the row's actions instead (see `body`).
    private var scoreButtons: some View {
        HStack(spacing: 0) {
            if score >= 0 {
                Button { onScore(score > 0 ? 0 : 1) } label: {
                    Image(systemName: score > 0 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle(score > 0 ? DSColor.accent : DSColor.textSecondary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
            }
            if score <= 0 {
                Button { onScore(score < 0 ? 0 : -1) } label: {
                    Image(systemName: score < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(score < 0 ? DSColor.accent : DSColor.textSecondary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(DSFont.body)
        .buttonStyle(.borderless)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let kindLabel = ChangeSourceKindLabel.text(for: kind) { parts.append(kindLabel) }
        if score > 0 { parts.append(localized("已讚")) }
        if score < 0 { parts.append(localized("已踩")) }
        return parts.joined(separator: ", ")
    }
}

enum ChangeSourceKindLabel {
    /// The kind, when it is not plain text: a different kind asks before switching.
    static func text(for kind: OnlineBookContentKind) -> String? {
        switch kind {
        case .text: nil
        case .audio: localized("有聲書")
        case .manga: localized("漫畫")
        case .video: localized("影片")
        }
    }
}

enum ChangeSourceWordCountText {
    /// Legado's 「[章節序] 標題 字數：N」 and 響應時間 line.
    static func line(for probe: ChangeSourceProbe?) -> String? {
        guard let probe, let count = probe.wordCount else { return nil }
        // 「[序] 標題」 has no words to translate.
        let chapter = probe.chapterIndex.map { index in
            "[\(index + 1)] \(probe.chapterTitle ?? "")"
        }
        var parts: [String] = chapter.map { [$0] } ?? []
        if count >= 0 {
            parts.append(String(format: localized("%d 字"), count))
        } else {
            parts.append(localized("取不到字數"))
        }
        if let ms = probe.respondMs {
            parts.append(String(format: localized("%d 毫秒"), ms))
        }
        return parts.joined(separator: " · ")
    }
}

/// While the fan-out runs: how many of the searched 來源配置 are done (Legado's 換源 progress).
struct ChangeSourceProgressRow: View {
    let progress: ChangeSourceSearch.Progress

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(String(format: localized("已搜尋 %1$d／%2$d 個來源配置"), progress.finished, progress.total))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Long-press actions

/// Legado's change_source_item.xml menu, for one 來源配置. 刪除 asks first (`onDelete` shows the
/// confirmation, on the row the long press was on).
struct ChangeSourceSourceActions: View {
    let search: ChangeSourceSearch
    let sourceId: UUID
    let onDelete: () -> Void

    var body: some View {
        Button { search.pinToTop(sourceId: sourceId) } label: {
            Label(localized("置頂"), systemImage: "arrow.up.to.line")
        }
        Button { search.pinToBottom(sourceId: sourceId) } label: {
            Label(localized("置底"), systemImage: "arrow.down.to.line")
        }
        if let source = BookSourceStore.shared.source(id: sourceId) {
            // A sheet from a context menu, as 探索's 編輯 (`bookSourceActionSheets`); here it is
            // nested under the 換源 sheet, as its 設置源變量 editor already is.
            Button { search.editingSource = source } label: {
                Label(localized("編輯來源配置"), systemImage: "square.and.pencil")
            }
        }
        Button { search.disableSource(id: sourceId) } label: {
            Label(localized("停用來源配置"), systemImage: "nosign")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label(localized("刪除來源配置"), systemImage: "trash")
        }
    }
}

extension View {
    /// 刪除's confirmation, on the row the long press was on (as `bookSourceDeleteConfirmation`),
    /// so on iOS 26+ its popover points at that row.
    func changeSourceDeleteConfirmation(
        sourceName: String,
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        confirmationDialog(localized("刪除來源配置"), isPresented: isPresented, titleVisibility: .visible) {
            Button(localized("刪除"), role: .destructive, action: onDelete)
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(sourceName)
        }
    }

    /// Legado's 搜索結果為空 prompt after a search scoped to one group found nothing.
    func changeSourceEmptyGroupAlert(search: ChangeSourceSearch) -> some View {
        alert(
            localized("搜尋結果為空"),
            isPresented: Binding(
                get: { search.emptyGroupPrompt != nil },
                set: { if !$0 { search.emptyGroupPrompt = nil } }
            ),
            presenting: search.emptyGroupPrompt
        ) { _ in
            Button(localized("取消"), role: .cancel) {}
            Button(localized("搜尋全部")) { search.searchAllGroups() }
        } message: { group in
            Text(String(format: localized("「%@」分組沒有找到這本書，要改搜全部來源配置嗎？"), group))
        }
    }

    /// 篩選 (Legado's 換源 SearchView): the list narrows to sources or latest chapters with the text.
    func changeSourceFilter(_ search: ChangeSourceSearch) -> some View {
        modifier(ChangeSourceFilterModifier(search: search))
    }

    /// The editor 編輯來源配置 opens; saving searches that source again.
    func changeSourceEditor(_ search: ChangeSourceSearch) -> some View {
        modifier(ChangeSourceEditorModifier(search: search))
    }

    /// Legado's `book_type_different`: an origin of another kind than the book asks first.
    func changeSourceKindConfirmation(
        _ search: ChangeSourceSearch, onConfirm: @escaping (BookOrigin) -> Void
    ) -> some View {
        modifier(ChangeSourceKindConfirmationModifier(search: search, onConfirm: onConfirm))
    }
}

private struct ChangeSourceEditorModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch

    func body(content: Content) -> some View {
        content.sheet(item: $search.editingSource) { source in
            AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                BookSourceEditView(source: source) { updated in
                    search.saveEditedSource(updated)
                }
            }
        }
    }
}

private struct ChangeSourceKindConfirmationModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch
    let onConfirm: (BookOrigin) -> Void

    func body(content: Content) -> some View {
        content.sourceKindMismatchAlert(origin: $search.kindMismatchOrigin, onConfirm: onConfirm)
    }
}

extension ChangeSourceSearch {
    /// A tap on an origin: switches through `perform`, or — when the origin is of another kind
    /// than the book — asks first (`changeSourceKindConfirmation`).
    func select(_ origin: BookOrigin, perform: (BookOrigin) -> Void) {
        if let target, origin.inferredContentKind() != target.kind {
            kindMismatchOrigin = origin
        } else {
            perform(origin)
        }
    }
}

private struct ChangeSourceFilterModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch

    func body(content: Content) -> some View {
        content.searchable(
            text: $search.filterText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(localized("篩選來源配置或最新章節"))
        )
    }
}

// MARK: - Toolbar

/// Legado's start/stop: 停止 while searching, 刷新 otherwise. One `Button` whose label changes,
/// never an if/else pair — a toolbar item that changes identity flickers or drops out.
struct ChangeSourceSearchButton: View {
    @ObservedObject var search: ChangeSourceSearch
    /// Also run on 刷新 (the reader searches its libraries and modules again).
    var onRefresh: () -> Void = {}

    var body: some View {
        Button {
            if !search.isSearching { onRefresh() }
            search.toggleSearch()
        } label: {
            Label(localized(search.isSearching ? "停止" : "重新搜尋"),
                  systemImage: search.isSearching ? "stop.circle" : "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized(search.isSearching ? "停止" : "重新搜尋"))
    }
}

/// The 換源 options (Legado change_source.xml): 分組, 校驗作者, 加載詳情, 換源時載入目錄,
/// 加載字數, then the host's own items. Nothing here presents a modal, so it stays a native
/// `Menu` on iOS 17 too (Technotes/iOS17MenuModalPresentation.md).
struct ChangeSourceOptionsMenu<Extra: View>: View {
    @ObservedObject var search: ChangeSourceSearch
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { search.group }, set: { search.setGroup($0) })) {
                Text(localized("全部來源配置")).tag("")
                ForEach(groupChoices, id: \.self) { group in
                    Text(group).tag(group)
                }
            } label: {
                Label(groupTitle, systemImage: "folder")
            }
            .pickerStyle(.menu)
            Toggle(isOn: Binding(get: { search.checkAuthor }, set: { search.setCheckAuthor($0) })) {
                Label(localized("校驗作者"), systemImage: "person.text.rectangle")
            }
            Toggle(isOn: Binding(get: { search.loadInfo }, set: { search.setLoadInfo($0) })) {
                Label(localized("載入詳情"), systemImage: "info.circle")
            }
            Toggle(isOn: Binding(get: { search.loadToc }, set: { search.setLoadToc($0) })) {
                Label(localized("換源時載入目錄"), systemImage: "list.bullet")
            }
            Toggle(isOn: Binding(get: { search.loadWordCount }, set: { search.setLoadWordCount($0) })) {
                Label(localized("載入字數"), systemImage: "textformat.123")
            }
            extra()
        } label: {
            Label(localized("更多"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized("更多"))
    }

    /// The saved group stays offered even when no enabled source is in it any more.
    private var groupChoices: [String] {
        let groups = search.availableGroups
        let saved = search.group
        return saved.isEmpty || groups.contains(saved) ? groups : groups + [saved]
    }

    private var groupTitle: String {
        search.group.isEmpty
            ? localized("分組")
            : String(format: localized("分組（%@）"), search.group)
    }
}

extension ChangeSourceOptionsMenu where Extra == EmptyView {
    init(search: ChangeSourceSearch) {
        self.init(search: search, extra: { EmptyView() })
    }
}

// MARK: - Previews

// The seeded lists (`ChangeSourceSearch.preview`) exist in Debug builds only.
#if DEBUG
#Preview("換源結果") {
    let origins = [
        ChangeSourceSearch.previewOrigin("筆趣閣"),
        ChangeSourceSearch.previewOrigin("起點中文網", last: "第 1450 章 大結局"),
        ChangeSourceSearch.previewOrigin("聚合有聲", kind: "有聲"),
    ]
    let probes = [
        ChangeSourceSearch.key(origins[0]): ChangeSourceProbe(
            chapterIndex: 41, chapterTitle: "第 42 章 星斗大森林", wordCount: 3215, respondMs: 820),
        ChangeSourceSearch.key(origins[1]): ChangeSourceProbe(
            chapterIndex: 41, chapterTitle: "第 42 章", wordCount: -1, respondMs: 60_000, failure: "逾時"),
    ]
    let search = ChangeSourceSearch.preview(
        origins: origins, probes: probes, searching: true,
        progress: .init(finished: 120, total: 459))
    return NavigationStack {
        List {
            ChangeSourceResultsSection(search: search, onSelect: { _ in })
        }
        .changeSourceFilter(search)
        .navigationTitle(localized("換源"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                ChangeSourceSearchButton(search: search)
                ChangeSourceOptionsMenu(search: search)
            }
        }
    }
}

#Preview("換源列，加載字數與評分") {
    let origin = ChangeSourceSearch.previewOrigin("筆趣閣")
    return List {
        ChangeSourceOriginRow(
            origin: origin, lastChapter: origin.lastChapter,
            probe: ChangeSourceProbe(chapterIndex: 41, chapterTitle: "第 42 章 星斗大森林", wordCount: 3215, respondMs: 820),
            showsWordCount: true, isProbing: false, isFailed: false, isPending: false,
            kind: .text, score: 1, onScore: { _ in }, action: {})
        ChangeSourceOriginRow(
            origin: origin, lastChapter: origin.lastChapter,
            probe: ChangeSourceProbe(chapterIndex: 41, chapterTitle: "第 42 章", wordCount: -1, respondMs: 60_000),
            showsWordCount: true, isProbing: false, isFailed: true, isPending: false,
            kind: .audio, score: -1, onScore: { _ in }, action: {})
    }
}

#Preview("換源結果，空的分組") {
    let search = ChangeSourceSearch.preview(origins: [])
    return NavigationStack {
        List {
            ChangeSourceResultsSection(search: search, onSelect: { _ in })
        }
        .navigationTitle(localized("換源"))
        .toolbarTitleDisplayMode(.inline)
    }
}
#endif
