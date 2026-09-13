import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add Book Entry
struct AddBookView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTab = 0

    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
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
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .bookshelf)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                }
            }
        }
    }
}

// MARK: - File Import Tab
struct FileImportTab: View {
    @EnvironmentObject var store: BookStore
    var onDismiss: () -> Void
    @State private var showFilePicker = false
    @State private var importTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var currentFile = ""
    @State private var completedCount = 0
    @State private var totalCount = 0
    @State private var errorMsg: String?

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                HintCard(
                    icon: "doc.text", title: localized("支援格式：TXT / Markdown / JSON / EPUB / PDF / CBZ / ZIP / 音訊"),
                    detail: localized("支援純文字（.txt / .md / .markdown / .json）、電子書（.epub）、PDF（.pdf）、本地漫畫（.cbz / .zip）與音訊（.mp3 / .m4a / .m4b / .aac / .flac / .wav）格式。選取後系統自動識別內容。"))

                Button {
                    showFilePicker = true
                } label: {
                    VStack(spacing: DSSpacing.md) {
                        Image(systemName: "folder.badge.plus")
                            .font(DSFont.fixed(size: 44)).foregroundColor(DSColor.accent)
                            .accessibilityHidden(true)
                        Text(localized("點擊選取 TXT / EPUB / PDF / 漫畫 / 音訊文件"))
                            .font(DSFont.headline).foregroundColor(DSColor.accent)
                        Text(localized("從文件 App、iCloud、本機儲存等選取"))
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(DSSpacing.xxl)
                    .background(DSColor.accentLight)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                DSColor.accent.opacity(0.4),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                }
                .buttonStyle(.plain)
                .accessibilityHint(localized("選取多本書籍"))
                .disabled(isLoading)

                if isLoading {
                    ProgressView(value: Double(completedCount), total: Double(max(1, totalCount))) {
                        Text(currentFile).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                    }
                    .accessibilityValue("\(completedCount) / \(totalCount)")
                }
                if let errorMsg {
                    Text(localized("匯入失敗：") + errorMsg)
                        .font(DSFont.caption).foregroundColor(DSColor.destructive).padding()
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [
            .plainText, UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText, .json, .epub, .pdf,
            UTType(filenameExtension: "cbz") ?? .data, .zip, .audio,
            .mpeg4Audio, UTType(filenameExtension: "m4b") ?? .audio,
            UTType(filenameExtension: "flac") ?? .audio
        ], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                isLoading = true
                errorMsg = nil
                completedCount = 0
                totalCount = urls.count
                importTask = Task { @MainActor in
                    defer { isLoading = false }
                    do {
                        let imported = try await LocalBookImportService.importBooks(at: urls, store: store) { index, filename in
                            completedCount = index
                            currentFile = filename
                        }
                        completedCount = urls.count
                        if imported.failures.isEmpty { onDismiss() }
                        else { errorMsg = imported.failures.joined(separator: "\n") }
                    } catch is CancellationError {
                        // Completed imports remain on the shelf; no staged files
                        // or uncommitted confirmation state outlive this view.
                    } catch {
                        errorMsg = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMsg = error.localizedDescription
            }
        }
        .interactiveDismissDisabled(isLoading)
        .onDisappear { importTask?.cancel() }
    }

    static func stagedCopy(of url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = url.lastPathComponent
        let destination = directory.appendingPathComponent(
            name.isEmpty ? UUID().uuidString : name
        )
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Remove a staged file together with the directory created to hold it.
    ///
    /// Deleting a parent directory is only safe for a URL this type staged, so the
    /// shape is verified rather than assumed: one UUID-named directory directly
    /// inside the temp directory. Anything else deletes just the file.
    static func removeStagedFile(at url: URL) {
        let directory = url.deletingLastPathComponent()
        let isStagingDirectory = UUID(uuidString: directory.lastPathComponent) != nil
            && directory.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL

        try? FileManager.default.removeItem(at: isStagingDirectory ? directory : url)
    }

}

// MARK: - URL Import Tab
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
                            .background(DSColor.accent).foregroundColor(.white)
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

// MARK: - Hint Card
struct HintCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(DSFont.title2).foregroundColor(DSColor.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DSFont.subheadline.weight(.semibold))
                Text(detail).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
            }
            Spacer()
        }
        .padding()
        .background(DSColor.accent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#Preview{
        AddBookView()
            .environmentObject(BookStore())
}
