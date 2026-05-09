import Combine
import Foundation
import OSLog
import SwiftSoup
import SwiftUI
import UIKit
import ReadiumShared

class BookStore: ObservableObject, BookProvider {
    @Published var books: [ReadingBook] = []

    // Legacy UserDefaults key kept only for one-time migration.
    private let legacyMetaKey = "yd_books_meta"
    private var saveWorkItem: DispatchWorkItem?

    /// Persistent storage location for the book-library JSON.
    /// Stored in Documents so it is included in iTunes / iCloud backups and is
    /// excluded from the UserDefaults domain plist (which is loaded synchronously
    /// at launch into memory in its entirety).
    static var booksMetaFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("books_meta.json")
    }

    init() { loadMeta() }

    // MARK: 讀取書籍正文
    func content(for book: ReadingBook) -> String {
        let url = documentsURL(for: book.contentFilename)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func package(forLocalBook book: ReadingBook) throws -> BookPackage {
        switch book.resolvedPipelineKind {
        case .epub:
            let epubFilename = book.contentFilename.hasSuffix(".epub")
                ? book.contentFilename
                : book.contentFilename.replacingOccurrences(of: "_epub.json", with: ".epub")
            let epubURL = documentsURL(for: epubFilename)
            let placeholder = EPUBParsedBook.placeholder(
                title: book.title,
                author: book.author,
                basePath: epubURL.deletingLastPathComponent()
            )
            return placeholder.makePackage(pipelineKind: .epub, originalSourceURL: epubURL)
        case .html:
            throw ReaderError.unsupportedFormat("HTML 渲染尚待 CoreText 遷移完成，目前不支援")
        case .txt:
            throw ReaderError.unsupportedFormat("TXT 渲染尚待 CoreText 遷移完成，目前不支援")
        }
    }

    // MARK: 章節解析 (獨立區分 EPUB 與 TXT)
    func chapters(for book: ReadingBook) -> [BookChapter] {
        if book.isOnline, let refs = book.onlineChapters {
            // 線上書：從章節引用轉換，content 從快取讀取（空 = 尚未載入）
            return refs.map { ref in
                let cached = BookSourceFetcher.shared.loadCachedChapterSync(
                    bookId: book.id, chapterIndex: ref.index)
                return BookChapter(index: ref.index, title: ref.title, content: cached ?? "")
            }
        }

        // 🛑 核心：如果是 EPUB，不走 TXT 解析器
        // 新格式（epub.js 方案）：contentFilename 直接是 .epub，由閱讀器的 JS 引擎解析 TOC
        if book.resolvedPipelineKind == .epub {
            // 舊格式：曾解析為 _epub.json
            if book.isLegacyParsedEPUB {
                let url = documentsURL(for: book.contentFilename)
                if let data = try? Data(contentsOf: url),
                    let decoded = try? JSONDecoder().decode([BookChapter].self, from: data)
                {
                    return decoded
                }
            }
            // 新格式 / 舊格式解析失敗：回傳佔位章節，epub.js 的 onTOC 回調會在閱讀器啟動後更新
            return [BookChapter(index: 0, title: book.title, content: "")]
        }

        if book.resolvedPipelineKind == .html {
            return [BookChapter(index: 0, title: book.title, content: "")]
        }

        // 如果是傳統 TXT，回傳純文字內容（實際渲染走 CoreText TXT 引擎）
        return [BookChapter(index: 0, title: book.title, content: content(for: book))]
    }

    // MARK: 匯入 TXT 檔案
    @discardableResult
    func importTxt(url: URL, title: String? = nil) throws -> ReadingBook {
        let bookTitle = title ?? url.deletingPathExtension().lastPathComponent
        return try importLocalTextFile(
            url: url,
            title: bookTitle,
            author: "未知作者",
            fileExtension: "txt"
        )
    }

    @discardableResult
    func importMarkdown(
        url: URL,
        title: String? = nil,
        author: String = "未知作者"
    ) throws -> ReadingBook {
        let bookTitle = title ?? url.deletingPathExtension().lastPathComponent
        let ext = normalizedMarkdownExtension(url.pathExtension.lowercased())
        return try importLocalTextFile(
            url: url,
            title: bookTitle,
            author: author,
            fileExtension: ext
        )
    }

    private func importLocalTextFile(
        url: URL,
        title: String,
        author: String,
        fileExtension: String
    ) throws -> ReadingBook {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let destURL = documentsURL(for: filename)

        // Probe encoding using first 4KB
        let probeData: Data
        if let handle = try? FileHandle(forReadingFrom: url) {
            probeData = handle.readData(ofLength: 4096)
            try? handle.close()
        } else {
            probeData = Data()
        }

        if probeData.isEmpty || String(data: probeData, encoding: .utf8) != nil {
            // Fast path: file is UTF-8 (or empty) — direct copy, no memory overhead
            try FileManager.default.copyItem(at: url, to: destURL)
        } else {
            // Slow path: non-UTF-8 (Big5/GBK) — stream-transcode to UTF-8
            try streamTranscodeToUTF8(source: url, destination: destURL)
        }

        // Validate the copied file is readable
        guard let mapped = try? TXTFileReader.readMappedTextFile(url: destURL),
              !mapped.string(in: 0..<min(128, mapped.byteCount)).isEmpty || mapped.byteCount == 0
        else {
            do {
                try FileManager.default.removeItem(at: destURL)
            } catch {
                Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove item at \(destURL): \(error)")
            }
            throw TXTFileReaderError.encodingNotSupported
        }

        var book = ReadingBook(title: title, author: author, source: "local", contentFilename: filename)
        book.contentPipelineKind = .txt
        books.insert(book, at: 0)
        saveMeta()
        return book
    }

    private func normalizedMarkdownExtension(_ ext: String) -> String {
        switch ext {
        case "markdown":
            return "markdown"
        default:
            return "md"
        }
    }

    private func streamTranscodeToUTF8(source: URL, destination: URL) throws {
        guard let inputStream = InputStream(url: source) else {
            throw TXTFileReaderError.encodingNotSupported
        }
        guard let outputStream = OutputStream(url: destination, append: false) else {
            throw TXTFileReaderError.encodingNotSupported
        }

        inputStream.open()
        outputStream.open()
        defer { inputStream.close(); outputStream.close() }

        // Detect encoding from first 128KB
        let probeSize = 128 * 1024
        var probeBuffer = [UInt8](repeating: 0, count: probeSize)
        let probeRead = inputStream.read(&probeBuffer, maxLength: probeSize)
        guard probeRead > 0 else { return }

        let probeData = Data(probeBuffer[0..<probeRead])
        let big5Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let sourceEncoding: String.Encoding
        if String(data: probeData, encoding: big5Encoding) != nil {
            sourceEncoding = big5Encoding
        } else if String(data: probeData, encoding: gbkEncoding) != nil {
            sourceEncoding = gbkEncoding
        } else {
            sourceEncoding = .utf8
        }

        // Re-open source stream from beginning (InputStream can't seek, so close and reopen)
        inputStream.close()
        guard let freshInput = InputStream(url: source) else { throw TXTFileReaderError.encodingNotSupported }
        freshInput.open()
        defer { freshInput.close() }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var leftover = Data()

        while freshInput.hasBytesAvailable {
            let readCount = freshInput.read(&buffer, maxLength: bufferSize)
            guard readCount > 0 else { break }
            let chunk = leftover + Data(buffer[0..<readCount])
            leftover = Data()

            if let decoded = String(data: chunk, encoding: sourceEncoding) {
                if let utf8Data = decoded.data(using: .utf8) {
                    utf8Data.withUnsafeBytes { ptr in
                        if let base = ptr.bindMemory(to: UInt8.self).baseAddress {
                            _ = outputStream.write(base, maxLength: utf8Data.count)
                        }
                    }
                }
            } else if chunk.count > 4 {
                // Keep last 3 bytes for next chunk (multi-byte boundary recovery)
                let safeEnd = chunk.count - 3
                let safe = chunk.subdata(in: 0..<safeEnd)
                leftover = chunk.subdata(in: safeEnd..<chunk.count)
                if let decoded = String(data: safe, encoding: sourceEncoding),
                   let utf8Data = decoded.data(using: .utf8) {
                    utf8Data.withUnsafeBytes { ptr in
                        if let base = ptr.bindMemory(to: UInt8.self).baseAddress {
                            _ = outputStream.write(base, maxLength: utf8Data.count)
                        }
                    }
                }
            }
        }

        // Flush leftover
        if !leftover.isEmpty, let decoded = String(data: leftover, encoding: sourceEncoding),
           let utf8Data = decoded.data(using: .utf8) {
            utf8Data.withUnsafeBytes { ptr in
                if let base = ptr.bindMemory(to: UInt8.self).baseAddress {
                    _ = outputStream.write(base, maxLength: utf8Data.count)
                }
            }
        }
    }

    // MARK: 修改3：匯入 EPUB 檔案
    @discardableResult
    func importEpub(url: URL, title: String? = nil) async throws -> ReadingBook {
        let importStartUptime = ProcessInfo.processInfo.systemUptime
        func importTrace(_ message: String) {
            let line = "[ImportTrace][BookStore.importEpub] \(message)"
            print(line)
            NSLog("%@", line)
        }

        // 0. 產生 UUID 作為新檔名
        let uuid = UUID().uuidString
        let filename = "\(uuid).epub"
        let destURL = documentsURL(for: filename)
        var coverFilename: String? = nil
        let sourceSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        importTrace(
            "begin source=\(url.lastPathComponent) sourceSizeBytes=\(sourceSizeBytes) dest=\(filename)"
        )

        func cleanupImportedFiles() {
            if FileManager.default.fileExists(atPath: destURL.path) {
                do {
                try FileManager.default.removeItem(at: destURL)
            } catch {
                Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove item at \(destURL): \(error)")
            }
            }
            if let coverFilename {
                let coverURL = documentsURL(for: coverFilename)
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    do {
                        try FileManager.default.removeItem(at: coverURL)
                    } catch {
                        Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove cover image at \(coverURL): \(error)")
                    }
                }
            }
        }

        do {
            try Task.checkCancellation()

            // 1. 複製 EPUB 檔案到 Documents 目錄
            let copyStart = ProcessInfo.processInfo.systemUptime
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)
            importTrace(
                "stage=copy done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - copyStart) * 1000))"
            )
            try Task.checkCancellation()

            // 2. 提取封面與元數據（合併處理以避免重複解析 EPUB ZIP 與 XML）
            let metadataStart = ProcessInfo.processInfo.systemUptime
            let session = try? await PublicationSession.open(sourceURL: destURL)
            importTrace(
                "stage=metadataOpen done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metadataStart) * 1000)) chapters=\(session?.chapters.count ?? 0)"
            )
            try Task.checkCancellation()

            let coverStart = ProcessInfo.processInfo.systemUptime
            if let coverResult = await session?.publication.cover(), case .success(let optionalImage) = coverResult, let coverImage = optionalImage {
                let coverName = "\(uuid)_cover.jpg"
                let coverURL = documentsURL(for: coverName)
                // 將封面轉為 JPEG 儲存（壓縮節省空間）
                if let jpegData = coverImage.jpegData(compressionQuality: 0.85) {
                    do {
                        try jpegData.write(to: coverURL)
                    } catch {
                        Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to write cover image at \(coverURL): \(error)")
                    }
                    coverFilename = coverName
                }
            }
            importTrace(
                "stage=coverExtract done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - coverStart) * 1000)) hasCover=\(coverFilename != nil)"
            )
            try Task.checkCancellation()

            // 3. 建立書籍模型
            let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent
            let parsedTitle = session?.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parsedAuthor = session?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bookTitle = parsedTitle.isEmpty ? fallbackTitle : parsedTitle
            let author = parsedAuthor.isEmpty ? "未知" : parsedAuthor
            var book = ReadingBook(
                title: bookTitle,
                author: author,
                source: "local_epub",
                contentFilename: filename
            )
            book.contentPipelineKind = .epub
            book.coverImagePath = coverFilename
            let finalBook = book

            try Task.checkCancellation()
            let persistStart = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                self.books.insert(finalBook, at: 0)
                self.saveMeta()
            }
            importTrace(
                "stage=persist done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - persistStart) * 1000)) totalElapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - importStartUptime) * 1000))"
            )
            return finalBook
        } catch is CancellationError {
            importTrace("cancelled totalElapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - importStartUptime) * 1000))")
            cleanupImportedFiles()
            throw CancellationError()
        }
    }

    // MARK: 匯入網頁文字
    @discardableResult
    func importWeb(
        content: String,
        title: String,
        author: String = "網路書籍",
        sourceURL: String,
        format: ImportedBookContentFormat = .plainText
    ) throws -> ReadingBook {
        return try saveBook(
            title: title,
            author: author,
            content: content,
            source: sourceURL,
            format: format
        )
    }

    // MARK: 更新閱讀進度
    func updatePosition(bookId: UUID, position: Double) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            books[idx].currentPosition = position
            saveMeta()
        }
    }

    func updateLastOpened(bookId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].lastOpenedDate = Date()
        saveMeta()
    }

    func setRendererPreference(bookId: UUID, preference: BookRendererPreference) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].rendererPreference = preference
        saveMeta()
    }

    func setCompatibilityState(bookId: UUID, state: BookCompatibilityState) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].compatibilityState = state
        saveMeta()
    }

    func setOfflineDownloadState(
        bookId: UUID,
        state: BookOfflineDownloadState,
        downloadedChapterCount: Int? = nil
    ) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].offlineDownloadState = state
        if let downloadedChapterCount {
            books[idx].downloadedChapterCount = downloadedChapterCount
        }
        saveMeta()
    }

    // MARK: 書籤管理

    func addBookmark(bookId: UUID, bookmark: Bookmark) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        // 避免同一穩定座標重複書籤。Topbar 書籤會寫入章首座標，所以同章共用一個。
        if books[idx].bookmarks.contains(where: { $0.hasSameStableLocation(as: bookmark) }) { return }
        books[idx].bookmarks.append(bookmark)
        books[idx].bookmarks = books[idx].bookmarks.sortedByStablePosition()
        saveMeta()
    }

    func removeBookmark(bookId: UUID, bookmarkId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].bookmarks.removeAll { $0.id == bookmarkId }
        saveMeta()
    }

    func toggleBookmark(
        bookId: UUID, chapterIndex: Int, chapterTitle: String,
        position: CoreTextReadingPosition, excerpt: String
    ) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        if let bmIdx = books[idx].bookmarks.firstIndex(where: { $0.position == position }) {
            books[idx].bookmarks.remove(at: bmIdx)
        } else {
            let bm = Bookmark(
                chapterIndex: chapterIndex, chapterTitle: chapterTitle,
                position: position, excerpt: excerpt)
            books[idx].bookmarks.append(bm)
            books[idx].bookmarks = books[idx].bookmarks.sortedByStablePosition()
        }
        saveMeta()
    }

    func addUnderlineBookmark(
        bookId: UUID,
        chapterIndex: Int,
        chapterTitle: String,
        position: CoreTextReadingPosition,
        length: Int,
        excerpt: String
    ) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        let safeLength = max(1, length)
        if books[idx].bookmarks.contains(where: {
            $0.kind == .underline && $0.position == position && $0.length == safeLength
        }) {
            return
        }
        let bookmark = Bookmark(
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            position: position,
            length: safeLength,
            kind: .underline,
            excerpt: excerpt
        )
        books[idx].bookmarks.append(bookmark)
        books[idx].bookmarks = books[idx].bookmarks.sortedByStablePosition()
        saveMeta()
    }

    func isBookmark(bookId: UUID, position: CoreTextReadingPosition) -> Bool {
        books.first(where: { $0.id == bookId })?.bookmarks.contains(where: {
            $0.position == position
        }) ?? false
    }

    func isChapterStartBookmarked(bookId: UUID, chapterIndex: Int) -> Bool {
        isBookmark(bookId: bookId, position: .chapterStart(chapterIndex))
    }

    // MARK: 增量更新書籍正文（下載中斷保護用）
    func updateBookContent(bookId: UUID, rawText: String) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        let filename = books[idx].contentFilename
        let fileURL = documentsURL(for: filename)
        do {
            try rawText.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to write raw text chapter to \(fileURL): \(error)")
        }
    }

    // MARK: 編輯書籍資訊
    func updateBook(bookId: UUID, title: String, author: String) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            books[idx].title = title.isEmpty ? books[idx].title : title
            books[idx].author = author.isEmpty ? books[idx].author : author
            saveMeta()
        }
    }

    // MARK: 書架分組
    var allGroups: [String] {
        let groups = books.compactMap { $0.group.isEmpty ? nil : $0.group }
        return Array(Set(groups)).sorted()
    }

    func setGroup(_ group: String, for bookId: UUID) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            books[idx].group = group
            saveMeta()
        }
    }

    // MARK: 刪除書籍
    /// 將指定 id 的書籍移到 `targetId` 之前；`targetId == nil` 代表移到最後。
    /// 用於拖曳排序，會保留多筆移動順序。
    func moveBooks(ids: [UUID], before targetId: UUID?) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        // 依目前 books 順序保留 moving 內部相對順序
        let moving = books.filter { idSet.contains($0.id) }
        var rest = books.filter { !idSet.contains($0.id) }
        if let targetId, let idx = rest.firstIndex(where: { $0.id == targetId }) {
            rest.insert(contentsOf: moving, at: idx)
        } else {
            rest.append(contentsOf: moving)
        }
        books = rest
        saveMeta()
    }

    func delete(bookId: UUID) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            let book = books[idx]
            if book.isOnline {
                // 刪除快取目錄
                let cacheDir = documentsURL(for: "online_cache/\(bookId.uuidString)")
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                } catch {
                    Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove cache directory \(cacheDir): \(error)")
                }
            } else {
                do {
                    let fileUrl = documentsURL(for: book.contentFilename)
                    try FileManager.default.removeItem(at: fileUrl)
                } catch {
                    Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove document file \(book.contentFilename): \(error)")
                }
                TXTChapterParser.deleteCachedIndexes(bookId: bookId)
                // 同步刪除 EPUB 字型資源目錄
                if book.isLegacyParsedEPUB {
                    let assetsDir = book.contentFilename.replacingOccurrences(
                        of: "_epub.json", with: "_epub_assets")
                    do {
                        let assetsUrl = documentsURL(for: assetsDir)
                        try FileManager.default.removeItem(at: assetsUrl)
                    } catch {
                        Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove assets directory \(assetsDir): \(error)")
                    }
                }
            }
            books.remove(at: idx)
            saveMeta()
        }
    }

    // MARK: 新增線上書籍（書源）
    @discardableResult
    func addOnlineBook(
        name: String, author: String,
        sourceId: UUID, bookInfoURL: String, tocURL: String? = nil,
        runtimeVariables: [String: String]? = nil,
        chapters: [OnlineChapterRef]
    ) -> ReadingBook {
        var book = ReadingBook(
            title: name, author: author, source: bookInfoURL, contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.bookSourceId = sourceId
        book.bookInfoURL = bookInfoURL
        book.tocURL = tocURL
        book.runtimeVariables = runtimeVariables
        book.onlineChapters = chapters
        books.insert(book, at: 0)
        saveMeta()
        return book
    }

    // MARK: 新增瀏覽器轉碼書（無書源，按 URL 懶加載）
    @discardableResult
    func addWebBrowsedBook(
        name: String, author: String,
        sourceURL: String,
        chapters: [OnlineChapterRef]
    ) -> ReadingBook {
        var book = ReadingBook(title: name, author: author, source: sourceURL, contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.bookSourceId = nil  // nil 表示瀏覽器轉碼書，不依賴書源
        book.bookInfoURL = sourceURL
        book.onlineChapters = chapters
        books.insert(book, at: 0)
        saveMeta()
        return book
    }

    // MARK: 更新已快取章節
    func updateCachedChapter(bookId: UUID, chapterIndex: Int, filename: String) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }),
            var chapters = books[idx].onlineChapters
        else { return }
        if let ci = chapters.firstIndex(where: { $0.index == chapterIndex }) {
            chapters[ci].cachedFilename = filename
            books[idx].onlineChapters = chapters
            saveMeta()
        }
    }

    func clearCachedChapter(bookId: UUID, chapterIndex: Int) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }),
            var chapters = books[idx].onlineChapters
        else { return }
        if let ci = chapters.firstIndex(where: { $0.index == chapterIndex }) {
            chapters[ci].cachedFilename = nil
            books[idx].onlineChapters = chapters
            saveMeta()
        }
    }

    /// 清掉整本書所有章節的 cachedFilename 標記（不動 offlineDownloadState）。
    /// 用於 refresh 時搭配 `clearAllChapterCache` 一次重置全書 cache 狀態。
    func clearAllCachedChapterFilenames(bookId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }),
            var chapters = books[idx].onlineChapters
        else { return }
        var changed = false
        for i in chapters.indices where chapters[i].cachedFilename != nil {
            chapters[i].cachedFilename = nil
            changed = true
        }
        guard changed else { return }
        books[idx].onlineChapters = chapters
        saveMeta()
    }

    func clearOnlineDownload(bookId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        let cacheDir = documentsURL(for: "online_cache/\(bookId.uuidString)")
        do {
            try FileManager.default.removeItem(at: cacheDir)
        } catch {
            Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to remove cache directory \(cacheDir): \(error)")
        }
        if var chapters = books[idx].onlineChapters {
            for chapterIndex in chapters.indices {
                chapters[chapterIndex].cachedFilename = nil
            }
            books[idx].onlineChapters = chapters
        }
        books[idx].offlineDownloadState = .none
        books[idx].downloadedChapterCount = 0
        saveMeta()
    }

    // MARK: 更新線上書的目錄章節（漸進式 TOC 加載完成後呼叫）
    func updateOnlineChapters(bookId: UUID, chapters: [OnlineChapterRef]) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].onlineChapters = chapters
        saveMeta()
    }

    // MARK: 換源（更新線上書的書源與目錄，並清空章節快取）
    /// 將指定書籍切換到新書源：拉取新目錄、更新 bookSourceId/bookInfoURL/onlineChapters、清空該書章節快取。
    func updateOnlineBookSource(bookId: UUID, origin: BookOrigin) async throws {
        guard let source = BookSourceStore.shared.sources.first(where: { $0.id == origin.sourceId })
        else {
            throw NSError(
                domain: "BookStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到書源"])
        }
        let tocPackage = try await BookSourceFetcher.shared.fetchTOCPackage(
            tocUrl: origin.tocUrl, source: source, runtimeVariables: origin.runtimeVariables)
        await MainActor.run {
            guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
            books[idx].bookSourceId = origin.sourceId
            books[idx].bookInfoURL = origin.bookUrl
            books[idx].tocURL = origin.tocUrl
            books[idx].runtimeVariables = origin.runtimeVariables
            books[idx].onlineChapters = tocPackage.chapters
            saveMeta()
        }
        BookSourceFetcher.shared.clearAllChapterCache(bookId: bookId)
    }

    @discardableResult
    func refreshOnlineBookMetadata(
        bookId: UUID,
        forceInfoRefresh: Bool = false,
        bookSourceFetcher: any BookSourceFetching = LiveBookSourceFetcher(bookSourceFetcher: BookSourceFetcher.shared),
        onFirstChaptersReady: (@MainActor (ReadingBook) -> Void)? = nil
    ) async throws -> ReadingBook {
        guard let snapshot = await MainActor.run(body: {
            books.first(where: { $0.id == bookId && $0.isOnline })
        }) else {
            throw NSError(
                domain: "BookStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "找不到線上書籍"])
        }

        guard let sourceId = snapshot.bookSourceId else {
            return snapshot
        }
        guard let source = await MainActor.run(body: {
            BookSourceStore.shared.sources.first(where: { $0.id == sourceId })
        }) else {
            throw NSError(
                domain: "BookStore", code: -3, userInfo: [NSLocalizedDescriptionKey: "找不到書源"])
        }

        let bookURL = normalizedOnlineValue(snapshot.bookInfoURL ?? snapshot.source)
        guard !bookURL.isEmpty else {
            throw NSError(
                domain: "BookStore", code: -4, userInfo: [NSLocalizedDescriptionKey: "缺少書籍詳情頁 URL"])
        }

        var runtimeVariables = snapshot.runtimeVariables
        var tocURL = normalizedOnlineValue(snapshot.tocURL)
        var infoPackage: BookInfoPackage?

        if forceInfoRefresh || tocURL.isEmpty {
            let fetchedInfo = try await bookSourceFetcher.fetchBookInfoPackage(
                url: bookURL,
                source: source,
                runtimeVariables: runtimeVariables
            )
            infoPackage = fetchedInfo
            if let fetchedRuntime = fetchedInfo.runtimeVariables, !fetchedRuntime.isEmpty {
                runtimeVariables = fetchedRuntime
            }
            let discoveredTOC = normalizedOnlineValue(fetchedInfo.tocUrl)
            if !discoveredTOC.isEmpty {
                tocURL = discoveredTOC
            }
        }

        if tocURL.isEmpty {
            tocURL = bookURL
        }

        let progressiveTOCURL = tocURL
        let progressiveRuntimeVariables = runtimeVariables
        let progressiveInfoPackage = infoPackage

        let tocPackage = try await bookSourceFetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: { [weak self] firstChapters in
                guard let self else { return }
                Task { @MainActor in
                    guard let idx = self.books.firstIndex(where: { $0.id == bookId }) else { return }

                    let previousTitle = self.books[idx].title
                    let previousAuthor = self.books[idx].author
                    let existingChapters = self.books[idx].onlineChapters ?? []
                    let mergedChapters = self.mergeOnlineChapters(existing: existingChapters, refreshed: firstChapters)
                    let chaptersChanged = self.chapterListChanged(existing: existingChapters, refreshed: firstChapters)
                    let tocChanged = self.normalizedOnlineValue(self.books[idx].tocURL) != progressiveTOCURL
                    let runtimeChanged = (self.books[idx].runtimeVariables ?? [:]) != (progressiveRuntimeVariables ?? [:])

                    self.books[idx].bookSourceId = source.id
                    self.books[idx].bookInfoURL = bookURL
                    self.books[idx].tocURL = progressiveTOCURL
                    self.books[idx].runtimeVariables = progressiveRuntimeVariables
                    self.books[idx].onlineChapters = mergedChapters

                    if let progressiveInfoPackage {
                        let resolvedName = self.normalizedOnlineValue(progressiveInfoPackage.name)
                        let resolvedAuthor = self.normalizedOnlineValue(progressiveInfoPackage.author)
                        if !resolvedName.isEmpty {
                            self.books[idx].title = resolvedName
                        }
                        if !resolvedAuthor.isEmpty {
                            self.books[idx].author = resolvedAuthor
                        }
                    }

                    let titleChanged = previousTitle != self.books[idx].title
                    let authorChanged = previousAuthor != self.books[idx].author
                    if runtimeChanged || chaptersChanged || tocChanged || titleChanged || authorChanged {
                        self.saveMeta()
                    }
                    onFirstChaptersReady?(self.books[idx])
                }
            }
        )
        if let fetchedRuntime = tocPackage.runtimeVariables, !fetchedRuntime.isEmpty {
            runtimeVariables = fetchedRuntime
        }

        let finalTOCURL = tocURL
        let finalRuntimeVariables = runtimeVariables
        let finalInfoPackage = infoPackage

        let updateResult = await MainActor.run { () -> (ReadingBook, Bool)? in
            guard let idx = books.firstIndex(where: { $0.id == bookId }) else {
                return nil
            }

            let existingChapters = books[idx].onlineChapters ?? []
            let mergedChapters = mergeOnlineChapters(existing: existingChapters, refreshed: tocPackage.chapters)
            let chaptersChanged = chapterListChanged(existing: existingChapters, refreshed: tocPackage.chapters)
            let tocChanged = normalizedOnlineValue(books[idx].tocURL) != finalTOCURL
            let runtimeChanged = (books[idx].runtimeVariables ?? [:]) != (finalRuntimeVariables ?? [:])
            let previousTitle = books[idx].title
            let previousAuthor = books[idx].author

            books[idx].bookSourceId = source.id
            books[idx].bookInfoURL = bookURL
            books[idx].tocURL = finalTOCURL
            books[idx].runtimeVariables = finalRuntimeVariables
            books[idx].onlineChapters = mergedChapters

            if let finalInfoPackage {
                let resolvedName = normalizedOnlineValue(finalInfoPackage.name)
                let resolvedAuthor = normalizedOnlineValue(finalInfoPackage.author)
                if !resolvedName.isEmpty {
                    books[idx].title = resolvedName
                }
                if !resolvedAuthor.isEmpty {
                    books[idx].author = resolvedAuthor
                }
            }

            let titleChanged = previousTitle != books[idx].title
            let authorChanged = previousAuthor != books[idx].author

            if runtimeChanged || chaptersChanged || tocChanged || titleChanged || authorChanged {
                saveMeta()
            }
            return (books[idx], chaptersChanged || tocChanged)
        }

        guard let (updated, shouldClearCache) = updateResult else {
            return snapshot
        }

        if shouldClearCache {
            BookSourceFetcher.shared.clearAllChapterCache(bookId: bookId)
        }

        return updated
    }

    // MARK: 私有方法
    private func saveBook(
        title: String,
        author: String,
        content: String,
        source: String,
        format: ImportedBookContentFormat = .plainText
    ) throws -> ReadingBook {
        let filename = "\(UUID().uuidString).\(format.fileExtension)"
        let fileURL = documentsURL(for: filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        var book = ReadingBook(
            title: title, author: author, source: source, contentFilename: filename)
        book.contentPipelineKind = (format == .html) ? .html : .txt
        books.insert(book, at: 0)
        saveMeta()
        return book
    }

    private func documentsURL(for filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    func localEPUBURL(for book: ReadingBook) -> URL {
        let epubFilename = book.contentFilename.hasSuffix(".epub")
            ? book.contentFilename
            : book.contentFilename.replacingOccurrences(of: "_epub.json", with: ".epub")
        return documentsURL(for: epubFilename)
    }

    private func saveMeta() {
        saveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(self.books) else { return }
            try? data.write(to: BookStore.booksMetaFileURL, options: .atomic)
        }

        saveWorkItem = workItem
        // 延遲 2 秒寫入（防抖機制）避免頻繁觸發卡頓
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func loadMeta() {
        // Prefer the file-based store.
        if let data = try? Data(contentsOf: BookStore.booksMetaFileURL),
           let decoded = try? JSONDecoder().decode([ReadingBook].self, from: data)
        {
            books = decoded
            sanitizePersistedChapterURLs()
            return
        }

        // One-time migration: pull legacy data out of UserDefaults, write to disk,
        // then remove the UserDefaults entry so it no longer inflates the plist.
        if let data = UserDefaults.standard.data(forKey: legacyMetaKey),
           let decoded = try? JSONDecoder().decode([ReadingBook].self, from: data)
        {
            books = decoded
            sanitizePersistedChapterURLs()
            if let migrated = try? JSONEncoder().encode(books) {
                try? migrated.write(to: BookStore.booksMetaFileURL, options: .atomic)
            }
            UserDefaults.standard.removeObject(forKey: legacyMetaKey)
        }
    }

    /// 清理所有已持久化線上書籍的章節 URL，將包含 HTML 標籤的 URL 替換為乾淨的 href
    private func sanitizePersistedChapterURLs() {
        var needsSave = false
        for i in books.indices {
            guard books[i].isOnline, var chapters = books[i].onlineChapters else { continue }
            var bookChanged = false
            for j in chapters.indices {
                let original = chapters[j].url
                let sanitized = RuleEngine.sanitizeExtractedURL(original)
                if sanitized != original {
                    chapters[j].url = sanitized
                    bookChanged = true
                }
            }
            if bookChanged {
                books[i].onlineChapters = chapters
                needsSave = true
            }
        }
        if needsSave {
            saveMeta()
        }
    }

    private func normalizedOnlineValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func mergeOnlineChapters(
        existing: [OnlineChapterRef],
        refreshed: [OnlineChapterRef]
    ) -> [OnlineChapterRef] {
        let existingByIndex = Dictionary(uniqueKeysWithValues: existing.map { ($0.index, $0) })
        return refreshed.map { chapter in
            var merged = chapter
            guard let current = existingByIndex[chapter.index] else {
                return merged
            }
            if normalizedOnlineValue(current.url) == normalizedOnlineValue(chapter.url) {
                merged.cachedFilename = current.cachedFilename
            }
            if (merged.runtimeVariables == nil || merged.runtimeVariables?.isEmpty == true),
                let currentRuntime = current.runtimeVariables,
                !currentRuntime.isEmpty
            {
                merged.runtimeVariables = currentRuntime
            }
            return merged
        }
    }

    private func chapterListChanged(
        existing: [OnlineChapterRef],
        refreshed: [OnlineChapterRef]
    ) -> Bool {
        guard existing.count == refreshed.count else { return true }
        for (left, right) in zip(existing, refreshed) {
            if left.index != right.index { return true }
            if normalizedOnlineValue(left.url) != normalizedOnlineValue(right.url) { return true }
            if normalizeChapterTitle(left.title) != normalizeChapterTitle(right.title) { return true }
        }
        return false
    }

    private func normalizeChapterTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}

