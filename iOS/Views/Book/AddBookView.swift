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
                    Picker(localized("方式"), selection: $selectedTab) {
                        Text(localized("匯入文件")).tag(0)
                        Text(localized("網址匯入")).tag(1)
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
            .navigationTitle(localized("添加書籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { presentationMode.wrappedValue.dismiss() }
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
    @State private var parseTask: Task<Void, Never>? = nil
    @State private var importTask: Task<Void, Never>? = nil
    @State private var activeSessionID = UUID()
    @ObservedObject private var gs = GlobalSettings.shared

    // 新增：用來記住 EPUB 檔案的暫存路徑，給「加入書架」按鈕使用
    @State private var pendingEpubURL: URL? = nil
    @State private var pendingMarkdownURL: URL? = nil

    private func importTrace(_ message: String) {
        let line = "[ImportTrace][AddBookView] \(message)"
        print(line)
        NSLog("%@", line)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HintCard(
                    icon: "doc.text", title: localized("支援格式：TXT / Markdown / JSON / EPUB"),
                    detail: localized("支援純文字（.txt / .md / .markdown / .json）與電子書（.epub）格式。選取後系統自動識別章節結構。"))

                if let content = pendingContent {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("確認書籍資訊")).font(.headline)
                        TextField(localized("書名"), text: $titleInput)
                            .padding(12)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if !authorInput.isEmpty {
                            TextField(localized("作者"), text: $authorInput)
                                .padding(12)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        //  判斷顯示的是 TXT 字數還是 EPUB 提示
                        if pendingEpubURL != nil {
                            Text(localized("已解析 EPUB 結構，點擊下方按鈕匯入"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        } else {
                            Text(localized("已讀取") + " \(content.count) " + localized("字"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)

                            let summaryBase = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !summaryBase.isEmpty {
                                let preview = String(summaryBase.prefix(280))
                                let suffix = summaryBase.count > 280 ? "…" : ""
                                Text(preview + suffix)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                                    .lineLimit(4)
                            }
                        }

                        Button {
                            let t = titleInput.trimmingCharacters(in: .whitespaces)
                            let a =
                                authorInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? localized("未知作者") : authorInput

                            isLoading = true
                            errorMsg = nil
                            cancelOngoingTasks()
                            let sessionID = nextSessionID()
                            let epubURLForImport = pendingEpubURL
                            let markdownURLForImport = pendingMarkdownURL
                            let startUptime = ProcessInfo.processInfo.systemUptime

                            // 🟢 核心修改：判斷是存成 EPUB 還是 TXT
                            importTask = Task {
                                do {
                                    await MainActor.run {
                                        let mode: String
                                        if epubURLForImport != nil {
                                            mode = "epub"
                                        } else if markdownURLForImport != nil {
                                            mode = "markdown"
                                        } else {
                                            mode = "txt"
                                        }
                                        importTrace(
                                            "confirmImport begin session=\(sessionID) mode=\(mode) title=\(t)"
                                        )
                                    }
                                    if let epubURL = epubURLForImport {
                                        try Task.checkCancellation()
                                        _ = try await store.importEpub(url: epubURL, title: t)
                                        try Task.checkCancellation()
                                        try? FileManager.default.removeItem(at: epubURL)
                                    } else if let markdownURL = markdownURLForImport {
                                        try Task.checkCancellation()
                                        _ = try store.importMarkdown(url: markdownURL, title: t, author: a)
                                    } else {
                                        try Task.checkCancellation()
                                        _ = try store.importWeb(
                                            content: content, title: t, author: a, sourceURL: "local"
                                        )
                                    }

                                    await MainActor.run {
                                        guard AddBookImportGuard.shouldApplyResult(
                                            activeSessionID: activeSessionID,
                                            resultSessionID: sessionID,
                                            isCancelled: Task.isCancelled
                                        ) else { return }
                                        importTrace(
                                            "confirmImport success session=\(sessionID) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000))"
                                        )
                                        isLoading = false
                                        onDismiss()
                                    }
                                } catch is CancellationError {
                                    await MainActor.run {
                                        guard activeSessionID == sessionID else { return }
                                        importTrace("confirmImport cancelled session=\(sessionID)")
                                        isLoading = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        guard AddBookImportGuard.shouldApplyResult(
                                            activeSessionID: activeSessionID,
                                            resultSessionID: sessionID,
                                            isCancelled: Task.isCancelled
                                        ) else { return }
                                        importTrace(
                                            "confirmImport failed session=\(sessionID) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) error=\(error.localizedDescription)"
                                        )
                                        isLoading = false
                                        errorMsg = localized("匯入失敗：") + error.localizedDescription
                                    }
                                }
                            }
                        } label: {
                            Label(localized("加入書架"), systemImage: "books.vertical")
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue).foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
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
                            Text(localized("點擊選取 TXT / EPUB 文件"))
                                .font(.headline).foregroundColor(DSColor.accent)
                            Text(localized("從文件 App、iCloud、本機儲存等選取"))
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
                    .disabled(isLoading)
                }

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(localized("讀取中...")).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
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
            allowedContentTypes: [
                UTType.plainText,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "markdown") ?? .plainText,
                .json,
                UTType.epub,
            ]
        ) { result in
            switch result {
            case .success(let url):
                cancelOngoingTasks()
                cleanupPendingEpubTempFile()
                cleanupPendingMarkdownTempFile()
                let sessionID = nextSessionID()
                isLoading = true
                errorMsg = nil
                pendingEpubURL = nil  // 每次選檔先清空
                pendingMarkdownURL = nil
                let ext = url.pathExtension.lowercased()
                let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                importTrace(
                    "picker success session=\(sessionID) ext=\(ext) sizeBytes=\(sizeBytes) path=\(url.lastPathComponent)"
                )
                if ext == "epub" {
                    importEPUB(url: url, sessionID: sessionID)
                } else {
                    importTXT(url: url, sessionID: sessionID)
                }
            case .failure(let err):
                importTrace("picker failure error=\(err.localizedDescription)")
                isLoading = false
                errorMsg = localized("選取失敗：") + "\(err.localizedDescription)"
            }
        }
        .onDisappear {
            cancelOngoingTasks()
            cleanupPendingEpubTempFile()
            cleanupPendingMarkdownTempFile()
            resetTransientState()
            activeSessionID = UUID()
        }
    }

    // MARK: - TXT 匯入
    private func importTXT(url: URL, sessionID: UUID) {
        parseTask = Task(priority: .userInitiated) {
            let startUptime = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                importTrace("importTXT begin session=\(sessionID) file=\(url.lastPathComponent)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            let isMarkdownFile = ext == "md" || ext == "markdown"
            let parsed = try? await BookParserRegistry.parse(url: url)
            let text = parsed?.storageText
            let name = url.deletingPathExtension().lastPathComponent
            let markdownTempURL: URL?
            if isMarkdownFile, text != nil {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".\(ext == "markdown" ? "markdown" : "md")")
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    markdownTempURL = tempURL
                } catch {
                    markdownTempURL = nil
                    await MainActor.run {
                        importTrace(
                            "importTXT markdownCopyFailed session=\(sessionID) error=\(error.localizedDescription)"
                        )
                    }
                }
            } else {
                markdownTempURL = nil
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else { return }
                isLoading = false
                importTrace(
                    "importTXT parsed session=\(sessionID) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) textChars=\(text?.count ?? 0)"
                )
                if let t = text {
                    if isMarkdownFile, markdownTempURL == nil {
                        pendingContent = nil
                        errorMsg = localized("無法準備 Markdown 檔案，請重試")
                        return
                    }
                    pendingContent = t
                    pendingMarkdownURL = markdownTempURL
                    let parsedTitle = parsed?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    titleInput = parsedTitle.isEmpty ? name : parsedTitle
                    authorInput = parsed?.author == "未知作者" ? "" : (parsed?.author ?? "")
                } else {
                    errorMsg = localized("無法讀取文件，請確認格式為 TXT / Markdown / JSON")
                }
            }
        }
    }

    // MARK: - EPUB 匯入
    private func importEPUB(url: URL, sessionID: UUID) {
        let startUptime = ProcessInfo.processInfo.systemUptime
        importTrace("importEPUB stage=begin session=\(sessionID) file=\(url.lastPathComponent)")
        let ok = url.startAccessingSecurityScopedResource()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            if ok { url.stopAccessingSecurityScopedResource() }
            importTrace(
                "importEPUB stage=copyFailed session=\(sessionID) error=\(error.localizedDescription)"
            )
            DispatchQueue.main.async {
                isLoading = false
                errorMsg = "無法複製 EPUB 檔案：\(error.localizedDescription)"
            }
            return
        }
        if ok { url.stopAccessingSecurityScopedResource() }

        guard AddBookImportGuard.shouldApplyResult(
            activeSessionID: activeSessionID,
            resultSessionID: sessionID,
            isCancelled: false
        ) else {
            importTrace("importEPUB stage=staleDiscarded session=\(sessionID)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        isLoading = false
        pendingContent = "EPUB_READY"  // 假字串，只為了觸發 UI 顯示確認卡片
        titleInput = url.deletingPathExtension().lastPathComponent
        authorInput = "未知作者"
        pendingEpubURL = tempURL  // 把路徑存起來，按下「加入書架」時再真正匯入
        importTrace(
            "importEPUB stage=prepared session=\(sessionID) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) tempFile=\(tempURL.lastPathComponent)"
        )
    }

    private func nextSessionID() -> UUID {
        let id = UUID()
        activeSessionID = id
        return id
    }

    private func cancelOngoingTasks() {
        parseTask?.cancel()
        parseTask = nil
        importTask?.cancel()
        importTask = nil
    }

    private func cleanupPendingEpubTempFile() {
        if let url = pendingEpubURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupPendingMarkdownTempFile() {
        if let url = pendingMarkdownURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func resetTransientState() {
        showFilePicker = false
        titleInput = ""
        authorInput = ""
        pendingContent = nil
        errorMsg = nil
        isLoading = false
        pendingEpubURL = nil
        pendingMarkdownURL = nil
    }
}

// MARK: - 網址匯入頁
struct URLImportTab: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var dependencies
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
                    title: localized("網址匯入"),
                    detail: localized("輸入小說網頁網址，系統抓取頁面文字。建議選用有純文字章節頁面的網站。"))

                VStack(alignment: .leading, spacing: 8) {
                    Label(localized("網址"), systemImage: "link")
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
                        Label(localized("書名"), systemImage: "text.book.closed")
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        TextField(localized("書名（必填）"), text: $titleInput)
                            .padding(12).background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Label(localized("作者"), systemImage: "person")
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        TextField(localized("作者（選填）"), text: $authorInput)
                            .padding(12).background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if let preview = fetchedPreviewText {
                            Text(localized("已抓取約") + " \(preview.count) " + localized("字"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        if !detectedTOCRefs.isEmpty {
                            Text(localized("偵測到章節目錄：") + " \(detectedTOCRefs.count) " + localized("章，將以線上書模式導入"))
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                        }
                    }
                }

                if isLoading { ProgressView(localized("正在抓取頁面…")) }
                if let err = errorMsg {
                    Text(err).font(DSFont.caption).foregroundColor(.red).padding(.horizontal)
                }

                if fetchedContent == nil {
                    Button {
                        fetchURL()
                    } label: {
                        Label(localized("抓取頁面"), systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                } else {
                    Button {
                        saveWebBook()
                    } label: {
                        Label(localized("加入書架"), systemImage: "books.vertical")
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
            errorMsg = localized("網址格式不正確")
            return
        }
        isLoading = true
        errorMsg = nil
        detectedTOCRefs = []

        Task {
            do {
                let html = try await dependencies.webContentFetcher.fetchHTML(
                    url: url,
                    method: "GET",
                    body: nil,
                    headers: [:],
                    baseURL: url.absoluteString,
                    bodyCharset: nil,
                    allowInteractiveChallengeOn503: false
                )
                let text = WebNovelParser.extractContent(html: html, pageURL: url.absoluteString)
                let refs = WebNovelParser.parseTOCRefs(html: html, pageURL: url.absoluteString)

                await MainActor.run {
                    isLoading = false
                    if text.count < 120 && refs.isEmpty {
                        errorMsg = localized("抓取到的文字太少，網站可能不支援直接抓取")
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
                    errorMsg = localized("抓取失敗：") + error.localizedDescription
                }
            }
        }
    }

    private func saveWebBook() {
        guard let content = fetchedContent else { return }
        let title = titleInput.trimmingCharacters(in: .whitespaces)
        let author =
            authorInput.trimmingCharacters(in: .whitespaces).isEmpty
            ? localized("網路書籍") : authorInput

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
#Preview{
        AddBookView()
            .environmentObject(BookStore())
}
