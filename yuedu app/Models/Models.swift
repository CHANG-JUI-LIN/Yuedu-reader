import Combine
import Foundation
// MARK: - HTML → 純文字
import SwiftSoup
import SwiftUI
import UIKit

// MARK: - 書籍章節 (🟢修改1：加上 Codable，並將 let 改為 var，讓 EPUB 可以存成 JSON)

struct BookChapter: Identifiable, Codable {
    var id = UUID()
    var index: Int
    var title: String
    var content: String
    var href: String = ""  // EPUB 章節路徑，用於渲染 baseURL
    var level: Int = 0  // TOC 縮排層級（0=頂層，1=子章節，…）
}

// MARK: - 線上章節參考

// MARK: - 書籤

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let pageIndex: Int  // 在全部頁面中的索引
    let date: Date
    var note: String
    let excerpt: String  // 書籤位置前幾個字的摘錄

    init(
        chapterIndex: Int, chapterTitle: String, pageIndex: Int,
        note: String = "", excerpt: String = ""
    ) {
        self.id = UUID()
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.date = Date()
        self.note = note
        self.excerpt = excerpt
    }
}

// MARK: - 書籍模型
struct ReadingBook: Identifiable, Codable {
    let id: UUID
    var title: String
    var author: String
    var source: String  // "local", "local_epub" 或 URL 字串
    var contentFilename: String  // 本地書：Documents 的檔名；線上書：空字串
    var contentPipelineKind: BookPipelineKind
    var currentPosition: Double  // 0.0 ~ 1.0
    var addedDate: Date

    // 線上書源欄位
    var isOnline: Bool
    var bookSourceId: UUID?
    var bookInfoURL: String?
    var tocURL: String?
    var runtimeVariables: [String: String]?
    var onlineChapters: [OnlineChapterRef]?

    // 書籤
    var bookmarks: [Bookmark] = []

    // 封面圖片路徑（Documents 目錄下的相對檔名，如 "xxx_cover.jpg"）
    var coverImagePath: String?
    var rendererPreference: BookRendererPreference
    var compatibilityState: BookCompatibilityState
    var offlineDownloadState: BookOfflineDownloadState
    var downloadedChapterCount: Int

    init(
        title: String, author: String = "未知作者",
        source: String = "local", contentFilename: String
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.source = source
        self.contentFilename = contentFilename
        self.contentPipelineKind = Self.inferPipelineKind(
            source: source,
            contentFilename: contentFilename,
            isOnline: false
        )
        self.currentPosition = 0.0
        self.addedDate = Date()
        self.isOnline = false
        self.bookSourceId = nil
        self.bookInfoURL = nil
        self.tocURL = nil
        self.runtimeVariables = nil
        self.onlineChapters = nil
        self.bookmarks = []
        self.coverImagePath = nil
        self.rendererPreference = .defaultWeb
        self.compatibilityState = .defaultWeb
        self.offlineDownloadState = .none
        self.downloadedChapterCount = 0
    }

    // 自訂 Decoder：舊資料缺少新欄位時使用預設值，不崩潰
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        source = try c.decode(String.self, forKey: .source)
        contentFilename = try c.decode(String.self, forKey: .contentFilename)
        contentPipelineKind =
            (try? c.decode(BookPipelineKind.self, forKey: .contentPipelineKind))
            ?? Self.inferPipelineKind(
                source: source,
                contentFilename: contentFilename,
                isOnline: (try? c.decode(Bool.self, forKey: .isOnline)) ?? false
            )
        currentPosition = try c.decode(Double.self, forKey: .currentPosition)
        addedDate = try c.decode(Date.self, forKey: .addedDate)
        isOnline = (try? c.decode(Bool.self, forKey: .isOnline)) ?? false
        bookSourceId = try? c.decode(UUID.self, forKey: .bookSourceId)
        bookInfoURL = try? c.decode(String.self, forKey: .bookInfoURL)
        tocURL = try? c.decode(String.self, forKey: .tocURL)
        runtimeVariables = try? c.decode([String: String].self, forKey: .runtimeVariables)
        onlineChapters = try? c.decode([OnlineChapterRef].self, forKey: .onlineChapters)
        bookmarks = (try? c.decode([Bookmark].self, forKey: .bookmarks)) ?? []
        coverImagePath = try? c.decode(String.self, forKey: .coverImagePath)
        rendererPreference =
            (try? c.decode(BookRendererPreference.self, forKey: .rendererPreference))
            ?? .defaultWeb
        compatibilityState =
            (try? c.decode(BookCompatibilityState.self, forKey: .compatibilityState))
            ?? .defaultWeb
        offlineDownloadState =
            (try? c.decode(BookOfflineDownloadState.self, forKey: .offlineDownloadState))
            ?? .none
        downloadedChapterCount = (try? c.decode(Int.self, forKey: .downloadedChapterCount)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, source, contentFilename, contentPipelineKind, currentPosition, addedDate
        case isOnline, bookSourceId, bookInfoURL, tocURL, runtimeVariables, onlineChapters, bookmarks
        case coverImagePath, rendererPreference, compatibilityState
        case offlineDownloadState, downloadedChapterCount
    }

    private static func inferPipelineKind(
        source: String,
        contentFilename: String,
        isOnline: Bool
    ) -> BookPipelineKind {
        if isOnline { return .html }
        if source == "local_epub" || contentFilename.hasSuffix("_epub.json")
            || contentFilename.hasSuffix(".epub")
        {
            return .epub
        }
        if contentFilename.hasSuffix(".html")
            || contentFilename.hasSuffix(".htm")
            || contentFilename.hasSuffix(".xhtml")
        {
            return .html
        }
        return .txt
    }
}

extension ReadingBook {
    var resolvedPipelineKind: BookPipelineKind {
        if isOnline { return .html }
        if source == "local_epub" || contentFilename.hasSuffix("_epub.json") {
            return .epub
        }
        return contentPipelineKind
    }

    var isLegacyParsedEPUB: Bool {
        contentFilename.hasSuffix("_epub.json")
    }
}

enum BookPipelineKind: String, Codable {
    case epub
    case txt
    case html
}

enum BookRendererPreference: String, Codable {
    case defaultWeb
    case forcedLegacy
    case forcedWeb
}

enum BookCompatibilityState: String, Codable {
    case defaultWeb
    case autoFallback
    case forcedLegacy
    case quarantined
}

enum BookOfflineDownloadState: String, Codable {
    case none
    case downloading
    case available
    case failed
}

enum BookResourceRole: String, Codable {
    case content
    case stylesheet
    case font
    case image
    case cover
    case unknown
}

enum PageRenderState: Equatable {
    case missing
    case loading
    case thumbnail
    case full
    case failed
}

struct BookResource: Codable, Equatable {
    let href: String
    let mediaType: String
    let role: BookResourceRole
}

struct BookSpineItem: Codable, Equatable {
    let href: String
    let title: String
    let mediaType: String
}

struct BookManifest: Codable, Equatable {
    let title: String
    let author: String
    let pipelineKind: BookPipelineKind
    let spine: [BookSpineItem]
    let resources: [BookResource]
    let toc: [EPUBTocEntry]
}

struct EPUBCSSResource {
    let content: String
    let baseDir: URL
}

struct EPUBChapterRaw {
    let href: String
    let title: String
    let html: String
    let cssEntries: [EPUBCSSResource]
    let baseURL: URL
    let mediaType: String

    init(
        href: String,
        title: String,
        html: String,
        cssEntries: [EPUBCSSResource] = [],
        baseURL: URL,
        mediaType: String = "application/xhtml+xml"
    ) {
        self.href = href
        self.title = title
        self.html = html
        self.cssEntries = cssEntries
        self.baseURL = baseURL
        self.mediaType = mediaType
    }
}

struct EPUBTocEntry: Codable, Equatable {
    let href: String
    let title: String
    let level: Int
}

struct EPUBParsedBook {
    let title: String
    let author: String
    let chapters: [EPUBChapterRaw]
    let basePath: URL
    let coverImageURL: URL?
    let tocEntries: [EPUBTocEntry]

    static func placeholder(title: String, author: String, basePath: URL) -> EPUBParsedBook {
        EPUBParsedBook(
            title: title,
            author: author,
            chapters: [],
            basePath: basePath,
            coverImageURL: nil,
            tocEntries: []
        )
    }

    func makePackage(
        pipelineKind: BookPipelineKind,
        originalSourceURL: URL?
    ) -> BookPackage {
        let manifest = BookManifest(
            title: title,
            author: author,
            pipelineKind: pipelineKind,
            spine: chapters.map { chapter in
                BookSpineItem(
                    href: chapter.href,
                    title: chapter.title,
                    mediaType: chapter.mediaType
                )
            },
            resources: [],
            toc: tocEntries
        )

        return BookPackage(
            title: title,
            author: author,
            pipelineKind: pipelineKind,
            basePath: basePath,
            originalSourceURL: originalSourceURL,
            manifest: manifest,
            parsedBook: self
        )
    }
}

struct BookPackage {
    let title: String
    let author: String
    let pipelineKind: BookPipelineKind
    let basePath: URL
    let originalSourceURL: URL?
    let manifest: BookManifest
    let parsedBook: EPUBParsedBook
}

struct ChapterPackageArtifact: Codable, Equatable {
    let sourceURL: String?
    let tocTitle: String?
    let canonicalTitle: String?
    let contentChecksum: String
    let rawHTMLFilename: String?
    let normalizedHTMLFilename: String?
    let savedAt: Date
}

enum ChapterPackageState: String, Codable, Equatable {
    case cached
    case failed
}

struct ChapterPackage: Codable, Equatable {
    let bookId: UUID
    let chapterIndex: Int
    let sourceURL: String?
    let tocTitle: String?
    let canonicalTitle: String?
    let content: String
    let contentChecksum: String
    let rawHTMLFilename: String?
    let normalizedHTMLFilename: String?
    let savedAt: Date
    let state: ChapterPackageState
    let failureReason: String?

    var renderTitle: String {
        canonicalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? canonicalTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (tocTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TOCPackage: Codable {
    let sourceId: UUID
    let sourceName: String
    let tocURL: String
    let runtimeVariables: [String: String]?
    let chapters: [OnlineChapterRef]
    let rawHTMLFilename: String?
    let savedAt: Date
}

struct BookInfoPackage: Codable {
    let sourceId: UUID
    let sourceName: String
    let bookURL: String
    let name: String
    let author: String
    let intro: String
    let coverUrl: String
    let tocUrl: String
    let wordCount: String
    let lastChapter: String
    let kind: String
    let runtimeVariables: [String: String]?
    let rawHTMLFilename: String?
    let savedAt: Date

    var onlineBook: OnlineBook {
        OnlineBook(
            name: name,
            author: author,
            intro: intro,
            coverUrl: coverUrl,
            bookUrl: bookURL,
            tocUrl: tocUrl,
            wordCount: wordCount,
            lastChapter: lastChapter,
            kind: kind,
            sourceId: sourceId,
            sourceName: sourceName,
            runtimeVariables: runtimeVariables
        )
    }
}

typealias RenderPackage = BookPackage

struct ReaderRenderSettings: Equatable {
    let theme: String
    let textColor: UIColor
    let backgroundColor: UIColor
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let marginH: CGFloat
    let marginV: CGFloat
    let footerHeight: CGFloat
    let contentInsets: UIEdgeInsets
}

enum ReaderLayoutMetrics {
    static let footerHeight: CGFloat = 24
    static let footerBottomGap: CGFloat = 28
    static let footerVisualBottomPadding: CGFloat = 0
    static let minimumVerticalPadding: CGFloat = 24
    static let topSafeAreaExtra: CGFloat = 10

    static func topInset(safeTop: CGFloat) -> CGFloat {
        max(minimumVerticalPadding, safeTop + topSafeAreaExtra)
    }

    static func bottomInset(safeBottom: CGFloat, footerHeight: CGFloat = footerHeight) -> CGFloat {
        safeBottom + footerHeight + footerBottomGap
    }
}

enum ImportedBookContentFormat: Equatable {
    case plainText
    case html

    var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .html: return "html"
        }
    }
}

protocol BookIngesting {
    func ingest() throws -> BookPackage
}

final class ReaderFeatureFlags {
    static let shared = ReaderFeatureFlags()

    private let defaults = UserDefaults.standard
    private let globalWebKey = "yd_pipeline_global_web"
    private let epubWebKey = "yd_pipeline_epub_web"
    private let txtWebKey = "yd_pipeline_txt_web"
    private let htmlWebKey = "yd_pipeline_html_web"
    private let onlineProgressiveKey = "yd_pipeline_online_progressive"

    private init() {}

    var useUnifiedWebPipeline: Bool {
        get { defaults.object(forKey: globalWebKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: globalWebKey) }
    }

    var useProgressiveOnlineReading: Bool {
        get { defaults.object(forKey: onlineProgressiveKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: onlineProgressiveKey) }
    }

    func isEnabled(for kind: BookPipelineKind) -> Bool {
        guard useUnifiedWebPipeline else { return false }
        let key: String
        switch kind {
        case .epub:
            key = epubWebKey
        case .txt:
            key = txtWebKey
        case .html:
            key = htmlWebKey
        }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    func shouldUseWebPipeline(for book: ReadingBook, kind: BookPipelineKind) -> Bool {
        switch book.rendererPreference {
        case .forcedLegacy:
            return false
        case .forcedWeb:
            return true
        case .defaultWeb:
            break
        }

        switch book.compatibilityState {
        case .forcedLegacy, .autoFallback, .quarantined:
            return false
        case .defaultWeb:
            break
        }
        return isEnabled(for: kind)
    }
}

final class ReaderTelemetry {
    static let shared = ReaderTelemetry()

    private init() {}

    func log(_ event: String, attributes: [String: String] = [:]) {}
}

// MARK: - 書庫管理
class BookStore: ObservableObject {
    @Published var books: [ReadingBook] = []

    private let metaKey = "yd_books_meta"

    init() { loadMeta() }

    // MARK: 讀取書籍正文
    func content(for book: ReadingBook) -> String {
        let url = documentsURL(for: book.contentFilename)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func package(forLocalBook book: ReadingBook) throws -> BookPackage {
        let sourceURL = URL(string: book.source)
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
            fatalError("HTML rendering temporarily disabled pending CoreText migration")
        case .txt:
            fatalError("TXT rendering temporarily disabled pending CoreText migration")
        }
    }

    // MARK: 🟢修改2：章節解析 (獨立區分 EPUB 與 TXT)
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
        // 多編碼偵測（UTF-8 → BIG5 → GBK → 自動偵測）
        let text = try TXTFileReader.readTextFile(url: url)
        let bookTitle = title ?? url.deletingPathExtension().lastPathComponent
        return try saveBook(title: bookTitle, author: "未知作者", content: text, source: "local")
    }

    // MARK: 修改3：匯入 EPUB 檔案
    @discardableResult
    func importEpub(url: URL, title: String? = nil) async throws -> ReadingBook {
        // 0. 產生 UUID 作為新檔名
        let uuid = UUID().uuidString
        let filename = "\(uuid).epub"
        let destURL = documentsURL(for: filename)

        // 1. 複製 EPUB 檔案到 Documents 目錄
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: url, to: destURL)

        // 2. 提取封面圖片（在背景線程完成）
        var coverFilename: String? = nil
        if let coverImage = await EPUBBookService.shared.extractCoverImage(from: destURL) {
            let coverName = "\(uuid)_cover.jpg"
            let coverURL = documentsURL(for: coverName)
            // 將封面轉為 JPEG 儲存（壓縮節省空間）
            if let jpegData = coverImage.jpegData(compressionQuality: 0.85) {
                try? jpegData.write(to: coverURL)
                coverFilename = coverName
            }
        }

        let document = try? await BookParserRegistry.parse(url: destURL)

        // 3. 建立書籍模型
        let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent
        let parsedTitle = document?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsedAuthor = document?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        await MainActor.run {
            self.books.insert(finalBook, at: 0)
            self.saveMeta()
        }
        return finalBook
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
        // 避免同一頁重複書籤
        if books[idx].bookmarks.contains(where: { $0.pageIndex == bookmark.pageIndex }) { return }
        books[idx].bookmarks.append(bookmark)
        books[idx].bookmarks.sort { $0.pageIndex < $1.pageIndex }
        saveMeta()
    }

    func removeBookmark(bookId: UUID, bookmarkId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].bookmarks.removeAll { $0.id == bookmarkId }
        saveMeta()
    }

    func toggleBookmark(
        bookId: UUID, chapterIndex: Int, chapterTitle: String,
        pageIndex: Int, excerpt: String
    ) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        if let bmIdx = books[idx].bookmarks.firstIndex(where: { $0.pageIndex == pageIndex }) {
            books[idx].bookmarks.remove(at: bmIdx)
        } else {
            let bm = Bookmark(
                chapterIndex: chapterIndex, chapterTitle: chapterTitle,
                pageIndex: pageIndex, excerpt: excerpt)
            books[idx].bookmarks.append(bm)
            books[idx].bookmarks.sort { $0.pageIndex < $1.pageIndex }
        }
        saveMeta()
    }

    func isPageBookmarked(bookId: UUID, pageIndex: Int) -> Bool {
        books.first(where: { $0.id == bookId })?.bookmarks.contains(where: {
            $0.pageIndex == pageIndex
        }) ?? false
    }

    // MARK: 增量更新書籍正文（下載中斷保護用）
    func updateBookContent(bookId: UUID, rawText: String) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        let filename = books[idx].contentFilename
        let fileURL = documentsURL(for: filename)
        try? rawText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: 編輯書籍資訊
    func updateBook(bookId: UUID, title: String, author: String) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            books[idx].title = title.isEmpty ? books[idx].title : title
            books[idx].author = author.isEmpty ? books[idx].author : author
            saveMeta()
        }
    }

    // MARK: 刪除書籍
    func delete(bookId: UUID) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            let book = books[idx]
            if book.isOnline {
                // 刪除快取目錄
                let cacheDir = documentsURL(for: "online_cache/\(bookId.uuidString)")
                try? FileManager.default.removeItem(at: cacheDir)
            } else {
                try? FileManager.default.removeItem(at: documentsURL(for: book.contentFilename))
                // 同步刪除 EPUB 字型資源目錄
                if book.isLegacyParsedEPUB {
                    let assetsDir = book.contentFilename.replacingOccurrences(
                        of: "_epub.json", with: "_epub_assets")
                    try? FileManager.default.removeItem(at: documentsURL(for: assetsDir))
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

    func clearOnlineDownload(bookId: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        let cacheDir = documentsURL(for: "online_cache/\(bookId.uuidString)")
        try? FileManager.default.removeItem(at: cacheDir)
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
        forceInfoRefresh: Bool = false
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
            let fetchedInfo = try await BookSourceFetcher.shared.fetchBookInfoPackage(
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

        let tocPackage = try await BookSourceFetcher.shared.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
        if let fetchedRuntime = tocPackage.runtimeVariables, !fetchedRuntime.isEmpty {
            runtimeVariables = fetchedRuntime
        }

        let existingChapters = snapshot.onlineChapters ?? []
        let mergedChapters = mergeOnlineChapters(existing: existingChapters, refreshed: tocPackage.chapters)
        let chaptersChanged = chapterListChanged(existing: existingChapters, refreshed: tocPackage.chapters)
        let tocChanged = normalizedOnlineValue(snapshot.tocURL) != tocURL
        let runtimeChanged = (snapshot.runtimeVariables ?? [:]) != (runtimeVariables ?? [:])
        let shouldClearCache = chaptersChanged || tocChanged
        let finalTOCURL = tocURL
        let finalRuntimeVariables = runtimeVariables
        let finalInfoPackage = infoPackage

        let updated = await MainActor.run { () -> ReadingBook in
            guard let idx = books.firstIndex(where: { $0.id == bookId }) else {
                return snapshot
            }
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
            return books[idx]
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
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: metaKey)
        }
    }

    private func loadMeta() {
        if let data = UserDefaults.standard.data(forKey: metaKey),
            let decoded = try? JSONDecoder().decode([ReadingBook].self, from: data)
        {
            books = decoded
            // 修復舊版殘留的 HTML 片段 URL（如 <a href="...">第1章</a>）
            sanitizePersistedChapterURLs()
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
                let sanitized = DefaultWebNovelParserService.shared.sanitizeExtractedURL(original)
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

extension String {
    /// 將 HTML 轉為保留段落邊界的純文字。
    /// 塊級元素（p, div, br, h1-h6, li, tr, blockquote）轉為換行，
    /// 行內元素直接移除標籤。保留語意結構供後續 splitIntoParagraphs 使用。
    var strippedHTML: String {
        do {
            let doc = try SwiftSoup.parse(self)
            // 移除 script / style / noscript 避免噪音
            try doc.select("script, style, noscript, iframe").remove()
            let root: SwiftSoup.Element = doc.body() ?? doc
            return HTMLTextExtractor.extractPreservingBlocks(root)
        } catch {
            return self
        }
    }
}

/// HTML → 純文字提取器，遞迴遍歷 DOM 並在塊級元素邊界插入換行
private enum HTMLTextExtractor {
    static let blockTags: Set<String> = [
        "p", "div", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "tr", "blockquote", "section", "article",
        "dt", "dd", "figcaption", "pre", "header", "footer",
    ]

    static func extractPreservingBlocks(_ element: SwiftSoup.Element) -> String {
        var result = ""
        for node in element.getChildNodes() {
            if let textNode = node as? SwiftSoup.TextNode {
                result += textNode.getWholeText()
            } else if let child = node as? SwiftSoup.Element {
                let tag = child.tagName().lowercased()
                if tag == "br" {
                    result += "\n"
                } else if blockTags.contains(tag) {
                    // 塊級元素：前後加換行
                    if !result.isEmpty && !result.hasSuffix("\n") {
                        result += "\n"
                    }
                    result += extractPreservingBlocks(child)
                    if !result.hasSuffix("\n") {
                        result += "\n"
                    }
                } else {
                    // 行內元素：直接提取文字
                    result += extractPreservingBlocks(child)
                }
            }
        }
        return result
    }
}
