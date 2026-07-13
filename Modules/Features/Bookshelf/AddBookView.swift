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
    @State private var titleInput = ""
    @State private var authorInput = ""
    @State private var pendingContent: String? = nil
    @State private var errorMsg: String? = nil
    @State private var isLoading = false
    @State private var parseTask: Task<Void, Never>? = nil
    @State private var importTask: Task<Void, Never>? = nil
    @State private var activeSessionID = UUID()
    @ObservedObject private var gs = GlobalSettings.shared

    // Stores the EPUB temporary file URL for the "Add to Shelf" button
    @State private var pendingEpubURL: URL? = nil
    @State private var pendingMarkdownURL: URL? = nil
    @State private var pendingMangaURL: URL? = nil
    @State private var pendingMangaPageCount: Int = 0
    @State private var pendingAudiobookURL: URL? = nil
    @State private var pendingAudiobookChapterCount: Int = 0
    @State private var pendingAudiobookTotalDuration: Double? = nil

    private func importTrace(_ message: String) {
        let line = "[ImportTrace][AddBookView] \(message)"
        print(line)
        NSLog("%@", line)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HintCard(
                    icon: "doc.text", title: localized("支援格式：TXT / Markdown / JSON / EPUB / CBZ / ZIP / 音訊"),
                    detail: localized("支援純文字（.txt / .md / .markdown / .json）、電子書（.epub）、本地漫畫（.cbz / .zip）與音訊（.mp3 / .m4a / .m4b / .aac / .flac / .wav）格式。選取後系統自動識別內容。"))

                if let content = pendingContent {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("確認書籍資訊")).font(DSFont.headline)
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

                        // Determine whether to show TXT word count or EPUB confirmation
                        if pendingAudiobookURL != nil {
                            Text(String(format: localized("已解析有聲書，共 %d 章"), pendingAudiobookChapterCount))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                            if let duration = pendingAudiobookTotalDuration {
                                Text(localized("總時長") + " " + formatDuration(duration))
                                    .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                            }
                        } else if pendingMangaURL != nil {
                            Text(String(format: localized("已解析漫畫，共 %d 頁"), pendingMangaPageCount))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        } else if pendingEpubURL != nil {
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
                            let mangaURLForImport = pendingMangaURL
                            let audiobookURLForImport = pendingAudiobookURL
                            let startUptime = ProcessInfo.processInfo.systemUptime

                            // Determine whether to import as EPUB, Markdown, manga, audiobook, or TXT
                            importTask = Task {
                                do {
                                    await MainActor.run {
                                        let mode: String
                                        if audiobookURLForImport != nil {
                                            mode = "audiobook"
                                        } else if mangaURLForImport != nil {
                                            mode = "manga"
                                        } else if epubURLForImport != nil {
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
                                    if let audiobookURL = audiobookURLForImport {
                                        try Task.checkCancellation()
                                        _ = try await store.importLocalAudiobook(url: audiobookURL, title: t, author: a)
                                        try Task.checkCancellation()
                                        try? FileManager.default.removeItem(at: audiobookURL)
                                    } else if let mangaURL = mangaURLForImport {
                                        try Task.checkCancellation()
                                        _ = try await store.importLocalManga(url: mangaURL, title: t, author: a)
                                        try Task.checkCancellation()
                                        try? FileManager.default.removeItem(at: mangaURL)
                                    } else if let epubURL = epubURLForImport {
                                        try Task.checkCancellation()
                                        _ = try await store.importEpub(url: epubURL, title: t, author: a)
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
                                .background(DSColor.accent).foregroundColor(.white)
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
                                .font(DSFont.fixed(size: 44)).foregroundColor(DSColor.accent)
                            Text(localized("點擊選取 TXT / EPUB / 漫畫 / 音訊文件"))
                                .font(DSFont.headline).foregroundColor(DSColor.accent)
                            Text(localized("從文件 App、iCloud、本機儲存等選取"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(32)
                        .background(DSColor.accentLight)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    DSColor.accent.opacity(0.4),
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
                UTType(filenameExtension: "cbz") ?? .data,
                UTType(filenameExtension: "zip") ?? .data,
                UTType.audio,
                UTType.mpeg4Audio,
                UTType(filenameExtension: "mp3") ?? .audio,
                UTType(filenameExtension: "m4b") ?? .audio,
                UTType(filenameExtension: "aac") ?? .audio,
                UTType(filenameExtension: "flac") ?? .audio,
                UTType(filenameExtension: "wav") ?? .audio,
            ]
        ) { result in
            switch result {
            case .success(let url):
                cancelOngoingTasks()
                cleanupPendingEpubTempFile()
                cleanupPendingMarkdownTempFile()
                cleanupPendingMangaTempFile()
                cleanupPendingAudiobookTempFile()
                let sessionID = nextSessionID()
                isLoading = true
                errorMsg = nil
                pendingEpubURL = nil
                pendingMarkdownURL = nil
                pendingMangaURL = nil
                pendingMangaPageCount = 0
                pendingAudiobookURL = nil
                pendingAudiobookChapterCount = 0
                pendingAudiobookTotalDuration = nil
                let ext = url.pathExtension.lowercased()
                let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                importTrace(
                    "picker success session=\(sessionID) ext=\(ext) sizeBytes=\(sizeBytes) path=\(url.lastPathComponent)"
                )
                if ext == "epub" {
                    importEPUB(url: url, sessionID: sessionID)
                } else if ext == "zip" {
                    importZip(url: url, sessionID: sessionID)
                } else if LocalAudiobookArchive.supports(url) {
                    importAudiobook(url: url, sessionID: sessionID)
                } else if LocalMangaArchive.supports(url) {
                    importManga(url: url, sessionID: sessionID)
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
            cleanupPendingMangaTempFile()
            cleanupPendingAudiobookTempFile()
            resetTransientState()
            activeSessionID = UUID()
        }
    }

    // MARK: - TXT Import
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

    // MARK: - EPUB Import
    private func importEPUB(url: URL, sessionID: UUID) {
        parseTask = Task(priority: .userInitiated) {
            let startUptime = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                importTrace("importEPUB stage=begin session=\(sessionID) file=\(url.lastPathComponent)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".epub")
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                if ok { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    importTrace(
                        "importEPUB stage=copyFailed session=\(sessionID) error=\(error.localizedDescription)"
                    )
                    isLoading = false
                    errorMsg = localized("無法複製 EPUB 檔案：") + error.localizedDescription
                }
                return
            }
            if ok { url.stopAccessingSecurityScopedResource() }

            // Extract metadata if possible
            var extractedTitle = url.deletingPathExtension().lastPathComponent
            var extractedAuthor = "未知作者"
            if let session = try? await PublicationSession.open(sourceURL: tempURL) {
                if !session.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    extractedTitle = session.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !session.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    extractedAuthor = session.author.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else {
                    importTrace("importEPUB stage=staleDiscarded session=\(sessionID)")
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                isLoading = false
                // Placeholder string to trigger the confirmation card UI
                pendingContent = "EPUB_READY"
                titleInput = extractedTitle
                authorInput = extractedAuthor == "未知作者" ? "" : extractedAuthor
                // Store the temp path; actual import happens when "Add to Shelf" is tapped
                pendingEpubURL = tempURL
                importTrace(
                    "importEPUB stage=prepared session=\(sessionID) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) tempFile=\(tempURL.lastPathComponent)"
                )
            }
        }
    }

    // MARK: - Local Manga Import
    private func importManga(url: URL, sessionID: UUID) {
        parseTask = Task(priority: .userInitiated) {
            let startUptime = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                importTrace("importManga stage=begin session=\(sessionID) file=\(url.lastPathComponent)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            let ext = url.pathExtension.lowercased() == "zip" ? "zip" : "cbz"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                if ok { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    importTrace(
                        "importManga stage=copyFailed session=\(sessionID) error=\(error.localizedDescription)"
                    )
                    isLoading = false
                    errorMsg = localized("無法複製漫畫檔案：") + error.localizedDescription
                }
                return
            }
            if ok { url.stopAccessingSecurityScopedResource() }

            await prepareMangaTempFile(
                tempURL,
                sessionID: sessionID,
                startUptime: startUptime,
                tracePrefix: "importManga"
            )
        }
    }

    // MARK: - Local Audiobook Import
    private func importAudiobook(url: URL, sessionID: UUID) {
        parseTask = Task(priority: .userInitiated) {
            let startUptime = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                importTrace("importAudiobook stage=begin session=\(sessionID) file=\(url.lastPathComponent)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            let ext = LocalAudiobookArchive.supports(url) ? url.pathExtension.lowercased() : "zip"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                if ok { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    importTrace(
                        "importAudiobook stage=copyFailed session=\(sessionID) error=\(error.localizedDescription)"
                    )
                    isLoading = false
                    errorMsg = localized("無法複製音訊檔案：") + error.localizedDescription
                }
                return
            }
            if ok { url.stopAccessingSecurityScopedResource() }

            await prepareAudiobookTempFile(
                tempURL,
                sessionID: sessionID,
                startUptime: startUptime,
                tracePrefix: "importAudiobook"
            )
        }
    }

    private func importZip(url: URL, sessionID: UUID) {
        parseTask = Task(priority: .userInitiated) {
            let startUptime = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                importTrace("importZip stage=begin session=\(sessionID) file=\(url.lastPathComponent)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".zip")
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                if ok { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    importTrace(
                        "importZip stage=copyFailed session=\(sessionID) error=\(error.localizedDescription)"
                    )
                    isLoading = false
                    errorMsg = localized("無法複製壓縮檔案：") + error.localizedDescription
                }
                return
            }
            if ok { url.stopAccessingSecurityScopedResource() }

            if await LocalAudiobookArchive.zipContainsAudio(tempURL) {
                await prepareAudiobookTempFile(
                    tempURL,
                    sessionID: sessionID,
                    startUptime: startUptime,
                    tracePrefix: "importZipAudio"
                )
            } else {
                await prepareMangaTempFile(
                    tempURL,
                    sessionID: sessionID,
                    startUptime: startUptime,
                    tracePrefix: "importZipManga"
                )
            }
        }
    }

    private func prepareMangaTempFile(
        _ tempURL: URL,
        sessionID: UUID,
        startUptime: TimeInterval,
        tracePrefix: String
    ) async {
        do {
            let info = try await LocalMangaArchive.inspect(url: tempURL)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else {
                    importTrace("\(tracePrefix) stage=staleDiscarded session=\(sessionID)")
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                isLoading = false
                pendingContent = "MANGA_READY"
                pendingMangaURL = tempURL
                pendingMangaPageCount = info.pageCount
                titleInput = info.title
                authorInput = info.author == localized("未知作者") ? "" : info.author
                importTrace(
                    "\(tracePrefix) stage=prepared session=\(sessionID) pages=\(info.pageCount) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) tempFile=\(tempURL.lastPathComponent)"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else { return }
                importTrace(
                    "\(tracePrefix) stage=parseFailed session=\(sessionID) error=\(error.localizedDescription)"
                )
                isLoading = false
                errorMsg = localized("匯入失敗：") + error.localizedDescription
            }
        }
    }

    private func prepareAudiobookTempFile(
        _ tempURL: URL,
        sessionID: UUID,
        startUptime: TimeInterval,
        tracePrefix: String
    ) async {
        do {
            let info = try await LocalAudiobookArchive.inspect(url: tempURL)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else {
                    importTrace("\(tracePrefix) stage=staleDiscarded session=\(sessionID)")
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                isLoading = false
                pendingContent = "AUDIOBOOK_READY"
                pendingAudiobookURL = tempURL
                pendingAudiobookChapterCount = info.chapterCount
                pendingAudiobookTotalDuration = info.totalDurationSeconds
                titleInput = info.title
                authorInput = info.author == localized("未知作者") ? "" : info.author
                importTrace(
                    "\(tracePrefix) stage=prepared session=\(sessionID) chapters=\(info.chapterCount) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000)) tempFile=\(tempURL.lastPathComponent)"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            await MainActor.run {
                guard AddBookImportGuard.shouldApplyResult(
                    activeSessionID: activeSessionID,
                    resultSessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else { return }
                importTrace(
                    "\(tracePrefix) stage=parseFailed session=\(sessionID) error=\(error.localizedDescription)"
                )
                isLoading = false
                errorMsg = localized("匯入失敗：") + error.localizedDescription
            }
        }
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

    private func cleanupPendingMangaTempFile() {
        if let url = pendingMangaURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupPendingAudiobookTempFile() {
        if let url = pendingAudiobookURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
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
        pendingMangaURL = nil
        pendingMangaPageCount = 0
        pendingAudiobookURL = nil
        pendingAudiobookChapterCount = 0
        pendingAudiobookTotalDuration = nil
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
