import SwiftUI

// MARK: - Book Source Editor

struct BookSourceEditView: View {
    @State private var source: BookSource
    let onSave: (BookSource) -> Void
    @Environment(\.presentationMode) var dismiss
    @State private var showDebugger = false
    @State private var showRuleDebugger = false
    @ObservedObject private var gs = GlobalSettings.shared

    init(source: BookSource, onSave: @escaping (BookSource) -> Void) {
        _source = State(initialValue: source)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                searchSection
                searchRuleSection
                bookInfoSection
                tocSection
                contentSection
                headerSection
                advancedSection
            }
            .navigationTitle(source.bookSourceName.isEmpty ? localized("新建書源") : source.bookSourceName)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { dismiss.wrappedValue.dismiss() }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            onSave(source)
                            dismiss.wrappedValue.dismiss()
                        } label: {
                            Label(localized("儲存"), systemImage: "checkmark")
                        }
                        .disabled(
                            source.bookSourceName.trimmingCharacters(in: .whitespaces).isEmpty
                                || source.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button { showRuleDebugger = true } label: {
                            Label(localized("調試規則"), systemImage: "ladybug")
                        }
                        .disabled(
                            source.bookSourceName.trimmingCharacters(in: .whitespaces).isEmpty
                                || source.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button { showDebugger = true } label: {
                            Label(localized("網路日誌"), systemImage: "network")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showDebugger) {
                BookSourceDebugView()
            }
            .sheet(isPresented: $showRuleDebugger) {
                BookSourceRuleDebugView(source: source)
            }
        }
    }

    // MARK: Basic Info
    private var basicSection: some View {
        Section(header: Text(localized("基本資訊"))) {
            ruleField(localized("書源名稱"), placeholder: localized("如：某某小說網"), text: $source.bookSourceName)
            ruleField(localized("書源地址"), placeholder: "https://example.com", text: $source.bookSourceUrl)
            ruleField(localized("書源分組"), placeholder: localized("如：玄幻、言情"), text: $source.bookSourceGroup)
            Toggle(localized("啟用"), isOn: $source.enabled)
        }
    }

    // MARK: Search Settings
    private var searchSection: some View {
        Section(
            header: Text(localized("搜索設定")),
            footer: Text(localized("{{key}} 為搜索關鍵字佔位符。POST 格式：URL,POST,body"))
        ) {
            ruleField(
                localized("搜索 URL"), placeholder: "https://example.com/search?q={{key}}",
                text: $source.searchUrl)
        }
    }

    // MARK: Search Rules
    private var searchRuleSection: some View {
        Section(
            header: Text(localized("搜索結果規則")),
            footer: Text(localized("CSS 選擇器示例：ul.book-list li\n屬性提取：a@href、img@src"))
        ) {
            ruleField(localized("書籍列表"), placeholder: "ul.book-list li", text: $source.ruleSearch.bookList)
            ruleField(localized("書名"), placeholder: "h3.title@text", text: $source.ruleSearch.name)
            ruleField(localized("作者"), placeholder: ".author@text", text: $source.ruleSearch.author)
            ruleField(localized("封面"), placeholder: "img@src", text: $source.ruleSearch.coverUrl)
            ruleField(localized("簡介"), placeholder: ".intro@text", text: $source.ruleSearch.intro)
            ruleField(localized("書籍 URL"), placeholder: "a@href", text: $source.ruleSearch.bookUrl)
            ruleField(
                localized("最新章節"), placeholder: ".last-chapter@text", text: $source.ruleSearch.lastChapter)
        }
    }

    // MARK: Book Detail Rules
    private var bookInfoSection: some View {
        Section(
            header: Text(localized("書籍詳情規則")),
            footer: Text(localized("目錄 URL 留空則使用書籍 URL"))
        ) {
            ruleField(localized("書名"), placeholder: "h1@text", text: $source.ruleBookInfo.name)
            ruleField(localized("作者"), placeholder: ".author@text", text: $source.ruleBookInfo.author)
            ruleField(localized("封面"), placeholder: ".cover img@src", text: $source.ruleBookInfo.coverUrl)
            ruleField(localized("簡介"), placeholder: "#intro@text", text: $source.ruleBookInfo.intro)
            ruleField(localized("目錄 URL"), placeholder: localized("留空使用書籍頁 URL"), text: $source.ruleBookInfo.tocUrl)
        }
    }

    // MARK: TOC Rules
    private var tocSection: some View {
        Section(
            header: Text(localized("目錄規則")),
            footer: Text(localized("preUpdateJs：載入目錄頁後先執行此 JS 再解析。章節列表：CSS 選擇器。"))
        ) {
            ruleField(localized("目錄前置 JS"), placeholder: localized("載入目錄頁後先執行再解析（可留空）"), text: $source.ruleToc.preUpdateJs)
            ruleField(localized("章節列表"), placeholder: "#chapter-list a", text: $source.ruleToc.chapterList)
            ruleField(localized("章節名"), placeholder: "@text", text: $source.ruleToc.chapterName)
            ruleField(localized("章節 URL"), placeholder: "@href", text: $source.ruleToc.chapterUrl)
            ruleField(localized("下一頁 URL"), placeholder: ".next@href", text: $source.ruleToc.nextTocUrl)
        }
    }

    // MARK: Content Rules
    private var contentSection: some View {
        Section(
            header: Text(localized("正文規則")),
            footer: Text(localized("替換規則每行格式：regex@@@replacement（空 replacement 表示刪除）"))
        ) {
            ruleField(localized("正文"), placeholder: "#chapter-content", text: $source.ruleContent.content)
            ruleField(
                localized("下一頁 URL"), placeholder: ".next-page@href", text: $source.ruleContent.nextContentUrl)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("替換規則")).font(.caption).foregroundColor(DSColor.textSecondary)
                TextEditor(text: $source.ruleContent.replaceRegex)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 80)
            }
        }
    }

    // MARK: Custom Headers
    private var headerSection: some View {
        Section(
            header: Text(localized("自定 HTTP Header")),
            footer: Text(localized("JSON 格式，如：{\"Cookie\":\"...\"}"))
        ) {
            TextEditor(text: $source.header)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 70)
        }
    }

    // MARK: Advanced (Legado Compatibility)
    private var advancedSection: some View {
        Section(
            header: Text(localized("進階")),
            footer: Text(localized("loginCheckJs：搜尋取得 HTML 後執行，回傳 true 表示需登入，不解析結果。"))
        ) {
            ruleField(localized("登入頁 URL"), placeholder: "https://...", text: $source.loginUrl)
            ruleField(localized("登入檢查 JS"), placeholder: "document.querySelector('.login')", text: $source.loginCheckJs)
        }
    }

    // MARK: Form Field
    @ViewBuilder
    private func ruleField(_ label: String, placeholder: String, text: Binding<String>) -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(DSColor.textSecondary)
            TextField(placeholder, text: text)
                .font(.system(size: 14, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
        .padding(.vertical, 2)
    }
}
