import SwiftUI
import UIKit

// MARK: - Book Source Editor (Legado / MD3 6-tab layout)

/// Full book source editor aligned with Legado 原版 / MD3 / Sigma: six tabs
/// (基本 / 搜索 / 發現 / 詳情 / 目錄 / 正文), every rule field exposed, each field
/// edited in a bottom-sheet editor with an insert-chips row (`@css:`, `@js:`, …).
///
/// Save validates 名稱 + URL, optionally runs Legado's rule auto-complete, and
/// leaving with unsaved changes asks for confirmation (是 = keep editing, 否 = discard).
struct BookSourceEditView: View {
    @State private var source: BookSource
    private let original: BookSource
    let onSave: (BookSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var selectedTab: EditTab = .base
    @State private var editingField: BookSourceFieldSpec? = nil
    @State private var showRuleDebugger = false
    @State private var showDebugger = false
    @State private var showVariables = false
    @State private var showDiscardConfirm = false
    @State private var pasteFeedback: String? = nil

    enum EditTab: String, CaseIterable, Identifiable {
        case base = "基本"
        case search = "搜索"
        case explore = "發現"
        case info = "詳情"
        case toc = "目錄"
        case content = "正文"
        var id: String { rawValue }
    }

    init(source: BookSource, onSave: @escaping (BookSource) -> Void) {
        _source = State(initialValue: source)
        original = source
        self.onSave = onSave
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(localized("編輯分頁"), selection: $selectedTab) {
                    ForEach(EditTab.allCases) { tab in
                        Text(localized(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))

                tabContent
            }
            .navigationTitle(source.bookSourceName.isEmpty ? localized("新建書源") : source.bookSourceName)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .interactiveDismissDisabled(isDirty)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        attemptCancel()
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        performSave()
                    } label: {
                        Label(localized("儲存"), systemImage: "checkmark")
                    }
                    .disabled(!canSave)

                    Menu {
                        Button {
                            showRuleDebugger = true
                        } label: {
                            Label(localized("調試規則"), systemImage: "ladybug")
                        }
                        .disabled(!canSave)

                        Button {
                            showDebugger = true
                        } label: {
                            Label(localized("網路日誌"), systemImage: "network")
                        }
                        Divider()
                        Toggle(isOn: $gs.bookSourceAutoComplete) {
                            Label(localized("自動補全"), systemImage: "wand.and.stars")
                        }
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label(localized("粘貼源"), systemImage: "doc.on.clipboard")
                        }
                        Button {
                            copySourceJSON()
                        } label: {
                            Label(localized("複製源"), systemImage: "doc.on.doc")
                        }
                        Button {
                            showVariables = true
                        } label: {
                            Label(localized("設置源變量"), systemImage: "curlybraces")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(localized("更多"))
                }
            }
            .sheet(item: $editingField) { spec in
                RuleEditorSheet(
                    spec: spec,
                    initialValue: source[keyPath: spec.keyPath]
                ) { newValue in
                    source[keyPath: spec.keyPath] = newValue
                }
            }
            .sheet(isPresented: $showDebugger) {
                BookSourceDebugView()
            }
            .sheet(isPresented: $showRuleDebugger) {
                BookSourceRuleDebugView(source: source)
            }
            .sheet(isPresented: $showVariables) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    RuntimeVariableEditorView(
                        title: localized("設置源變量"),
                        comment: source.variableComment,
                        initialValue: BookSourceRuntimeStateStore.shared
                            .sourceVariableJSON(for: source.bookSourceUrl) ?? ""
                    ) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(
                            trimmed.isEmpty ? nil : trimmed,
                            for: source.bookSourceUrl
                        )
                        return nil
                    }
                }
            }
            .alert(
                pasteFeedback != nil ? localized("完成") : localized("退出"),
                isPresented: Binding(
                    get: { showDiscardConfirm || pasteFeedback != nil },
                    set: { if !$0 { showDiscardConfirm = false; pasteFeedback = nil } }
                )
            ) {
                if pasteFeedback != nil {
                    Button(localized("確定"), role: .cancel) { pasteFeedback = nil }
                } else {
                    Button(localized("是")) { showDiscardConfirm = false }
                    Button(localized("否")) {
                        showDiscardConfirm = false
                        dismiss()
                    }
                }
            } message: {
                Text(pasteFeedback ?? localized("尚未保存，是否繼續編輯？"))
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .base:    baseTab
        case .search:  ruleTab(specs: FieldCatalog.search)
        case .explore: ruleTab(specs: FieldCatalog.explore)
        case .info:    ruleTab(specs: FieldCatalog.info)
        case .toc:     ruleTab(specs: FieldCatalog.toc)
        case .content: ruleTab(specs: FieldCatalog.content)
        }
    }

    // MARK: 基本

    private var baseTab: some View {
        Form {
            Section {
                Picker(localized("類型"), selection: $source.bookSourceType) {
                    Text(localized("文字")).tag(0)
                    Text(localized("音頻")).tag(1)
                    Text(localized("圖片")).tag(2)
                    Text(localized("文件")).tag(3)
                }
                .pickerStyle(.menu)
                Toggle(localized("啟用"), isOn: $source.enabled)
                Toggle(localized("發現"), isOn: $source.enabledExplore)
                // `enabledCookieJar` and `enabledReview` are deliberately NOT editable
                // here: neither gates anything in this app (see their declarations in
                // `BookSource`), so a switch for them reads as a feature toggle while
                // changing nothing. Both fields are still decoded, encoded, and handed
                // to the source's JS — only the misleading control is gone.
                Toggle(isOn: $source.presentsAndroidIdentity) {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(localized("提供裝置識別碼"))
                        Text(localized("預設開啟，書源要裝置碼時才拿得到。只有在某個書源不能被當成 Android 時才關閉。"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            .interfaceSectionSurface()

            Section {
                ForEach(FieldCatalog.base) { spec in
                    fieldRow(spec)
                }
            }
            .interfaceSectionSurface()
        }
        .listStyle(.insetGrouped)
    }

    /// 搜索 / 發現 / 詳情 / 目錄 / 正文 tabs — one section per rule group.
    private func ruleTab(specs: [BookSourceFieldSpec]) -> some View {
        Form {
            Section {
                ForEach(specs) { spec in
                    fieldRow(spec)
                }
            }
            .interfaceSectionSurface()
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Field Row

    @ViewBuilder
    private func fieldRow(_ spec: BookSourceFieldSpec) -> some View {
        Button {
            editingField = spec
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(spec.label))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                    Text(displayValue(for: spec))
                        .font(DSFont.fixed(size: 13, design: .monospaced))
                        .foregroundColor(displayValueIsEmpty(spec) ? DSColor.textSecondary.opacity(0.6) : Color.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(DSFont.caption2)
                    .foregroundColor(DSColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized(spec.label))
        .accessibilityValue(displayValue(for: spec))
        .accessibilityHint(localized("點兩下編輯規則"))
    }

    private func displayValue(for spec: BookSourceFieldSpec) -> String {
        let value = source[keyPath: spec.keyPath]
        return value.isEmpty ? spec.placeholder : value
    }

    private func displayValueIsEmpty(_ spec: BookSourceFieldSpec) -> Bool {
        source[keyPath: spec.keyPath].isEmpty
    }

    // MARK: - Save / Cancel

    private var canSave: Bool {
        !source.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDirty: Bool {
        !Self.sourcesEqual(source, original)
    }

    private func attemptCancel() {
        if isDirty {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func performSave() {
        var toSave = source
        if gs.bookSourceAutoComplete {
            toSave = Self.applyAutoComplete(toSave)
        }
        onSave(toSave)
        dismiss()
    }

    /// Legado's ruleComplete() pass: every field tagged with a completion type is
    /// completed against its parent rule (bookList / init / chapterList), exactly like
    /// `BookSourceEditActivity.getSource()`.
    private static func applyAutoComplete(_ source: BookSource) -> BookSource {
        var completed = source
        for spec in FieldCatalog.all {
            guard let type = spec.autoCompleteType else { continue }
            let preRule = spec.preRuleKeyPath.map { completed[keyPath: $0] }
            completed[keyPath: spec.keyPath] =
                RuleAutoComplete.autoComplete(completed[keyPath: spec.keyPath], preRule: preRule, type: type)
        }
        return completed
    }

    private static func sourcesEqual(_ lhs: BookSource, _ rhs: BookSource) -> Bool {
        var a = lhs
        var b = rhs
        a.lastUpdateTime = 0
        b.lastUpdateTime = 0
        let encoder = JSONEncoder()
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    // MARK: - 粘貼源 / 複製源

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteFeedback = localized("剪貼簿為空")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            Task { await fetchAndPaste(trimmed) }
            return
        }
        if let parsed = BookSourceStore.parseSources(trimmed), let first = parsed.first {
            source = first
            pasteFeedback = localized("已從剪貼簿導入書源")
        } else {
            pasteFeedback = localized("剪貼簿內容不是有效的書源")
        }
    }

    private func fetchAndPaste(_ urlString: String) async {
        guard let url = URL(string: urlString) else {
            pasteFeedback = localized("無效的 URL")
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let parsed = BookSourceStore.parseSources(text),
                  let first = parsed.first else {
                pasteFeedback = localized("無法解析伺服器回應")
                return
            }
            source = first
            pasteFeedback = localized("已從剪貼簿導入書源")
        } catch {
            pasteFeedback = error.localizedDescription
        }
    }

    private func copySourceJSON() {
        guard let data = try? JSONEncoder().encode(source),
              let str = String(data: data, encoding: .utf8) else { return }
        UIPasteboard.general.string = str
        pasteFeedback = localized("已複製書源 JSON")
    }
}

// MARK: - Field Specification

/// One editable rule field. `keyPath` points into `BookSource`; `autoCompleteType`
/// (+ `preRuleKeyPath`) reproduce Legado's per-field auto-complete mapping.
struct BookSourceFieldSpec: Identifiable {
    let id = UUID()
    let label: String
    let placeholder: String
    let helpText: String?
    let keyPath: WritableKeyPath<BookSource, String>
    let autoCompleteType: RuleAutoComplete.CompletionType?
    let preRuleKeyPath: WritableKeyPath<BookSource, String>?

    init(
        _ label: String,
        placeholder: String = "",
        helpText: String? = nil,
        keyPath: WritableKeyPath<BookSource, String>,
        autoComplete: RuleAutoComplete.CompletionType? = nil,
        preRule: WritableKeyPath<BookSource, String>? = nil
    ) {
        self.label = label
        self.placeholder = placeholder
        self.helpText = helpText
        self.keyPath = keyPath
        self.autoCompleteType = autoComplete
        self.preRuleKeyPath = preRule
    }
}

/// The full field catalog, matching the field sets of Legado 原版 / MD3 / Sigma's
/// edit screens. Static stored arrays keep the spec instances (and their ids) stable.
private enum FieldCatalog {
    // MARK: 基本 — Legado `sourceEntities`
    static let base: [BookSourceFieldSpec] = [
        BookSourceFieldSpec("書源名稱", placeholder: "如：某某小說網", keyPath: \.bookSourceName),
        BookSourceFieldSpec("書源地址", placeholder: "https://example.com", keyPath: \.bookSourceUrl),
        BookSourceFieldSpec("書源分組", placeholder: "如：玄幻、言情", keyPath: \.bookSourceGroup),
        BookSourceFieldSpec("源註釋", keyPath: \.bookSourceComment),
        BookSourceFieldSpec("登入頁 URL", placeholder: "https://...", keyPath: \.loginUrl),
        BookSourceFieldSpec("登入 UI", placeholder: "JSON", keyPath: \.loginUi),
        BookSourceFieldSpec(
            "登入檢查 JS",
            placeholder: "document.querySelector('.login')",
            helpText: "loginCheckJs：搜尋取得 HTML 後執行，回傳 true 表示需登入，不解析結果。",
            keyPath: \.loginCheckJs
        ),
        BookSourceFieldSpec("封面解密", keyPath: \.coverDecodeJs),
        BookSourceFieldSpec("書籍 URL 正則", keyPath: \.bookUrlPattern),
        BookSourceFieldSpec(
            "請求頭",
            placeholder: #"{"User-Agent":"..."}"#,
            helpText: "JSON 格式，如：{\"Cookie\":\"...\"}",
            keyPath: \.header
        ),
        BookSourceFieldSpec("變量說明", keyPath: \.variableComment),
        BookSourceFieldSpec("並發率", placeholder: "0", keyPath: \.concurrentRate),
        BookSourceFieldSpec("jsLib", keyPath: \.jsLib),
    ]

    // MARK: 搜索 — Legado `searchEntities`
    static let search: [BookSourceFieldSpec] = [
        BookSourceFieldSpec(
            "搜索 URL",
            placeholder: "https://example.com/search?q={{key}}",
            helpText: "{{key}} 為搜索關鍵字佔位符。POST 格式：URL,POST,body",
            keyPath: \.searchUrl
        ),
        BookSourceFieldSpec("校驗關鍵字", placeholder: "我的", keyPath: \.ruleSearch.checkKeyWord),
        BookSourceFieldSpec("書籍列表規則", placeholder: "ul.book-list li", keyPath: \.ruleSearch.bookList),
        BookSourceFieldSpec("書名規則", placeholder: "h3.title@text", keyPath: \.ruleSearch.name,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("作者規則", placeholder: ".author@text", keyPath: \.ruleSearch.author,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("分類規則", placeholder: ".kind@text", keyPath: \.ruleSearch.kind,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("字數規則", placeholder: ".word-count@text", keyPath: \.ruleSearch.wordCount,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("最新章節規則", placeholder: ".last-chapter@text", keyPath: \.ruleSearch.lastChapter,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("簡介規則", placeholder: ".intro@text", keyPath: \.ruleSearch.intro,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("封面規則", placeholder: "img@src", keyPath: \.ruleSearch.coverUrl,
                            autoComplete: .image, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("詳情頁 URL 規則", placeholder: "a@href", keyPath: \.ruleSearch.bookUrl,
                            autoComplete: .link, preRule: \.ruleSearch.bookList),
        BookSourceFieldSpec("更新時間規則", placeholder: ".update-time@text", keyPath: \.ruleSearch.updateTime,
                            autoComplete: .text, preRule: \.ruleSearch.bookList),
    ]

    // MARK: 發現 — Legado `findEntities`
    static let explore: [BookSourceFieldSpec] = [
        BookSourceFieldSpec("發現地址規則", placeholder: "https://example.com/category", keyPath: \.exploreUrl),
        BookSourceFieldSpec("書籍列表規則", placeholder: "ul.book-list li", keyPath: \.ruleExplore.bookList),
        BookSourceFieldSpec("書名規則", placeholder: "h3.title@text", keyPath: \.ruleExplore.name,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("作者規則", placeholder: ".author@text", keyPath: \.ruleExplore.author,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("分類規則", placeholder: ".kind@text", keyPath: \.ruleExplore.kind,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("字數規則", placeholder: ".word-count@text", keyPath: \.ruleExplore.wordCount,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("最新章節規則", placeholder: ".last-chapter@text", keyPath: \.ruleExplore.lastChapter,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("簡介規則", placeholder: ".intro@text", keyPath: \.ruleExplore.intro,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("封面規則", placeholder: "img@src", keyPath: \.ruleExplore.coverUrl,
                            autoComplete: .image, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("詳情頁 URL 規則", placeholder: "a@href", keyPath: \.ruleExplore.bookUrl,
                            autoComplete: .link, preRule: \.ruleExplore.bookList),
        BookSourceFieldSpec("更新時間規則", placeholder: ".update-time@text", keyPath: \.ruleExplore.updateTime,
                            autoComplete: .text, preRule: \.ruleExplore.bookList),
    ]

    // MARK: 詳情 — Legado `infoEntities`
    static let info: [BookSourceFieldSpec] = [
        BookSourceFieldSpec(
            "預處理規則",
            helpText: "獲取書籍詳情頁後先執行此 JS 再解析其餘規則。",
            keyPath: \.ruleBookInfo.initScript
        ),
        BookSourceFieldSpec("書名規則", placeholder: "h1@text", keyPath: \.ruleBookInfo.name,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("作者規則", placeholder: ".author@text", keyPath: \.ruleBookInfo.author,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("分類規則", placeholder: ".kind@text", keyPath: \.ruleBookInfo.kind,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("字數規則", placeholder: ".word-count@text", keyPath: \.ruleBookInfo.wordCount,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("最新章節規則", placeholder: ".last-chapter@text", keyPath: \.ruleBookInfo.lastChapter,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("簡介規則", placeholder: "#intro@text", keyPath: \.ruleBookInfo.intro,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("封面規則", placeholder: ".cover img@src", keyPath: \.ruleBookInfo.coverUrl,
                            autoComplete: .image, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec(
            "目錄 URL 規則",
            placeholder: "留空使用書籍頁 URL",
            keyPath: \.ruleBookInfo.tocUrl,
            autoComplete: .link,
            preRule: \.ruleBookInfo.initScript
        ),
        BookSourceFieldSpec("允許修改書名作者", placeholder: "true", keyPath: \.ruleBookInfo.canReName),
        BookSourceFieldSpec("下載 URL 規則", placeholder: "a@href", keyPath: \.ruleBookInfo.downloadUrls,
                            autoComplete: .text, preRule: \.ruleBookInfo.initScript),
        BookSourceFieldSpec("聽書骰子規則", keyPath: \.ruleBookInfo.ttsDice),
    ]

    // MARK: 目錄 — Legado `tocEntities`
    static let toc: [BookSourceFieldSpec] = [
        BookSourceFieldSpec(
            "更新之前 JS",
            helpText: "preUpdateJs：載入目錄頁後先執行此 JS 再解析。",
            keyPath: \.ruleToc.preUpdateJs
        ),
        BookSourceFieldSpec("章節列表規則", placeholder: "#chapter-list a", keyPath: \.ruleToc.chapterList),
        BookSourceFieldSpec("章節名稱規則", placeholder: "@text", keyPath: \.ruleToc.chapterName,
                            autoComplete: .text, preRule: \.ruleToc.chapterList),
        BookSourceFieldSpec("章節 URL 規則", placeholder: "@href", keyPath: \.ruleToc.chapterUrl,
                            autoComplete: .link, preRule: \.ruleToc.chapterList),
        BookSourceFieldSpec("格式化規則", keyPath: \.ruleToc.formatJs),
        BookSourceFieldSpec("卷標識", keyPath: \.ruleToc.isVolume),
        BookSourceFieldSpec("章節信息", keyPath: \.ruleToc.updateTime),
        BookSourceFieldSpec("VIP 標識", keyPath: \.ruleToc.isVip),
        BookSourceFieldSpec("購買標識", keyPath: \.ruleToc.isPay),
        BookSourceFieldSpec("目錄下一頁規則", placeholder: ".next@href", keyPath: \.ruleToc.nextTocUrl,
                            autoComplete: .link, preRule: \.ruleToc.chapterList),
    ]

    // MARK: 正文 — Legado `contentEntities`
    static let content: [BookSourceFieldSpec] = [
        BookSourceFieldSpec("正文規則", placeholder: "#chapter-content", keyPath: \.ruleContent.content,
                            autoComplete: .text),
        BookSourceFieldSpec("章節名稱規則", placeholder: "@text", keyPath: \.ruleContent.title),
        BookSourceFieldSpec("正文下一頁 URL 規則", placeholder: ".next-page@href", keyPath: \.ruleContent.nextContentUrl,
                            autoComplete: .link),
        BookSourceFieldSpec("WebView JS", keyPath: \.ruleContent.webJs),
        BookSourceFieldSpec("資源正則", keyPath: \.ruleContent.sourceRegex),
        BookSourceFieldSpec(
            "替換規則",
            helpText: "替換規則每行格式：regex@@@replacement（空 replacement 表示刪除）",
            keyPath: \.ruleContent.replaceRegex
        ),
        BookSourceFieldSpec("圖片樣式", keyPath: \.ruleContent.imageStyle),
        BookSourceFieldSpec("圖片解密", keyPath: \.ruleContent.imageDecode),
        BookSourceFieldSpec("購買操作", keyPath: \.ruleContent.payAction),
    ]

    static var all: [BookSourceFieldSpec] {
        base + search + explore + info + toc + content
    }
}
