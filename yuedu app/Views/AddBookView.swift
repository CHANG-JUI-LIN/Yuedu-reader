import SwiftUI
import UniformTypeIdentifiers

// MARK: - 添加書籍入口
struct AddBookView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTab = 0

    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 760) {
                VStack(spacing: 0) {
                    Picker(gs.t("方式"), selection: $selectedTab) {
                        Text(gs.t("匯入文件")).tag(0)
                        Text(gs.t("網址匯入")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    if selectedTab == 0 {
                        FileImportTab(onDismiss: { presentationMode.wrappedValue.dismiss() })
                            .environmentObject(store)
                    } else {
                        URLImportTab(onDismiss: { presentationMode.wrappedValue.dismiss() })
                            .environmentObject(store)
                    }
                    Spacer()
                }
            }
            .navigationTitle(gs.t("添加書籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("取消")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: - 文件匯入頁
struct FileImportTab: View {
    @EnvironmentObject var store: BookStore
    var onDismiss: () -> Void
    @State private var showFilePicker = false
    @State private var titleInput = ""
    @State private var authorInput = ""
    @State private var pendingContent: String? = nil
    @State private var errorMsg: String? = nil
    @State private var isLoading = false
    @ObservedObject private var gs = GlobalSettings.shared

    // 🟢 新增：用來記住 EPUB 檔案的暫存路徑，給「加入書架」按鈕使用
    @State private var pendingEpubURL: URL? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HintCard(
                    icon: "doc.text", title: gs.t("支援格式：TXT / EPUB"),
                    detail: gs.t("支援純文字（.txt）與電子書（.epub）格式。選取後系統自動識別章節結構。"))

                if let content = pendingContent {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(gs.t("確認書籍資訊")).font(.headline)
                        TextField(gs.t("書名"), text: $titleInput)
                            .padding(12)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if !authorInput.isEmpty {
                            TextField(gs.t("作者"), text: $authorInput)
                                .padding(12)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // 🟢 判斷顯示的是 TXT 字數還是 EPUB 提示
                        if pendingEpubURL != nil {
                            Text(gs.t("已解析 EPUB 結構，點擊下方按鈕匯入"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        } else {
                            Text(gs.t("已讀取") + " \(content.count) " + gs.t("字"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }

                        Button {
                            let t = titleInput.trimmingCharacters(in: .whitespaces)
                            let a =
                                authorInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? gs.t("未知作者") : authorInput

                            isLoading = true

                            // 🟢 核心修改：判斷是存成 EPUB 還是 TXT
                            Task {
                                if let epubURL = pendingEpubURL {
                                    _ = try? await store.importEpub(url: epubURL, title: t)
                                    try? FileManager.default.removeItem(at: epubURL)
                                } else {
                                    _ = try? store.importWeb(
                                        content: content, title: t, author: a, sourceURL: "local"
                                    )
                                }

                                await MainActor.run {
                                    isLoading = false
                                    onDismiss()
                                }
                            }
                        } label: {
                            Label(gs.t("加入書架"), systemImage: "books.vertical")
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue).foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Button {
                        showFilePicker = true
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 44)).foregroundColor(DSColor.accent)
                            Text(gs.t("點擊選取 TXT / EPUB 文件"))
                                .font(.headline).foregroundColor(DSColor.accent)
                            Text(gs.t("從文件 App、iCloud、本機儲存等選取"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(32)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    Color.blue.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                    }
                    .buttonStyle(.plain)
                }

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(gs.t("讀取中...")).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                    }
                }
                if let err = errorMsg {
                    Text(err).font(DSFont.caption).foregroundColor(.red).padding()
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.plainText, UTType.epub]
        ) { result in
            switch result {
            case .success(let url):
                isLoading = true
                errorMsg = nil
                pendingEpubURL = nil  // 每次選檔先清空
                let ext = url.pathExtension.lowercased()
                if ext == "epub" {
                    importEPUB(url: url)
                } else {
                    importTXT(url: url)
                }
            case .failure(let err):
                errorMsg = gs.t("選取失敗：") + "\(err.localizedDescription)"
            }
        }
    }

    // MARK: - TXT 匯入
    private func importTXT(url: URL) {
        DispatchQueue.global().async {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            // 多編碼偵測（UTF-8 → BIG5 → GBK → 自動偵測）
            let text = try? TXTFileReader.readTextFile(url: url)
            let name = url.deletingPathExtension().lastPathComponent
            DispatchQueue.main.async {
                isLoading = false
                if let t = text {
                    pendingContent = t
                    titleInput = name
                    authorInput = ""
                } else {
                    errorMsg = gs.t("無法讀取文件，請確認格式為 TXT")
                }
            }
        }
    }

    // MARK: - EPUB 匯入
    private func importEPUB(url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            if ok { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                isLoading = false
                errorMsg = "無法複製 EPUB 檔案：\(error.localizedDescription)"
            }
            return
        }
        if ok { url.stopAccessingSecurityScopedResource() }

        Task {
            await MainActor.run {
                isLoading = false
                pendingContent = "EPUB_READY"  // 假字串，只為了觸發 UI 顯示確認卡片
                titleInput = url.deletingPathExtension().lastPathComponent
                authorInput = "未知作者"
                pendingEpubURL = tempURL  // 把路徑存起來，按下「加入書架」時再真正匯入
            }
        }
    }
}

// MARK: - 網址匯入頁
struct URLImportTab: View {
    @EnvironmentObject var store: BookStore
    var onDismiss: () -> Void
    @State private var urlInput = ""
    @State private var titleInput = ""
    @State private var authorInput = ""
    @State private var fetchedContent: String? = nil
    @State private var fetchedPreviewText: String? = nil
    @State private var detectedTOCRefs: [OnlineChapterRef] = []
    @State private var isLoading = false
    @State private var errorMsg: String? = nil
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HintCard(
                    icon: "globe",
                    title: gs.t("網址匯入"),
                    detail: gs.t("輸入小說網頁網址，系統抓取頁面文字。建議選用有純文字章節頁面的網站。"))

                VStack(alignment: .leading, spacing: 8) {
                    Label(gs.t("網址"), systemImage: "link")
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                    HStack {
                        TextField("https://...", text: $urlInput)
                            .disableAutocorrection(true)
                        if !urlInput.isEmpty {
                            Button {
                                urlInput = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Color.secondary.opacity(0.6))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if fetchedContent != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(gs.t("書名"), systemImage: "text.book.closed")
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        TextField(gs.t("書名（必填）"), text: $titleInput)
                            .padding(12).background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Label(gs.t("作者"), systemImage: "person")
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        TextField(gs.t("作者（選填）"), text: $authorInput)
                            .padding(12).background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if let preview = fetchedPreviewText {
                            Text(gs.t("已抓取約") + " \(preview.count) " + gs.t("字"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        if !detectedTOCRefs.isEmpty {
                            Text(gs.t("偵測到章節目錄：") + " \(detectedTOCRefs.count) " + gs.t("章，將以線上書模式導入"))
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                }

                if isLoading { ProgressView(gs.t("正在抓取頁面…")) }
                if let err = errorMsg {
                    Text(err).font(DSFont.caption).foregroundColor(.red).padding(.horizontal)
                }

                if fetchedContent == nil {
                    Button {
                        fetchURL()
                    } label: {
                        Label(gs.t("抓取頁面"), systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                } else {
                    Button {
                        saveWebBook()
                    } label: {
                        Label(gs.t("加入書架"), systemImage: "books.vertical")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.green).foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func fetchURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMsg = gs.t("網址格式不正確")
            return
        }
        isLoading = true
        errorMsg = nil
        detectedTOCRefs = []

        Task {
            do {
                let html = try await WebFetcher.shared.fetchHTML(
                    url: url,
                    method: "GET",
                    body: nil,
                    headers: [:],
                    baseURL: url.absoluteString,
                    allowInteractiveChallengeOn503: false
                )
                let text = WebNovelParser.extractContent(html: html, pageURL: url.absoluteString)
                let refs = WebNovelParser.parseTOCRefs(html: html, pageURL: url.absoluteString)

                await MainActor.run {
                    isLoading = false
                    if text.count < 120 && refs.isEmpty {
                        errorMsg = gs.t("抓取到的文字太少，網站可能不支援直接抓取")
                        return
                    }
                    fetchedContent = html
                    fetchedPreviewText = text.isEmpty ? html.strippedHTML : text
                    detectedTOCRefs = refs
                    if titleInput.isEmpty,
                       let r = html.range(
                        of: "(?<=<title>)[^<]+(?=</title>)",
                        options: .regularExpression)
                    {
                        titleInput = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMsg = gs.t("抓取失敗：") + error.localizedDescription
                }
            }
        }
    }

    private func saveWebBook() {
        guard let content = fetchedContent else { return }
        let title = titleInput.trimmingCharacters(in: .whitespaces)
        let author =
            authorInput.trimmingCharacters(in: .whitespaces).isEmpty
            ? gs.t("網路書籍") : authorInput

        if !detectedTOCRefs.isEmpty {
            _ = store.addWebBrowsedBook(
                name: title,
                author: author,
                sourceURL: urlInput.trimmingCharacters(in: .whitespacesAndNewlines),
                chapters: detectedTOCRefs
            )
            onDismiss()
            return
        }

        _ = try? store.importWeb(
            content: content,
            title: title,
            author: author,
            sourceURL: urlInput,
            format: .html
        )
        onDismiss()
    }
}

// MARK: - 提示卡片
struct HintCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2).foregroundColor(DSColor.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
