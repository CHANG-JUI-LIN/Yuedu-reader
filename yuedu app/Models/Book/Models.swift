import Combine
import Foundation
import OSLog
// MARK: - HTML → 純文字
import SwiftSoup
import SwiftUI
import UIKit
import ReadiumShared

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
    enum Kind: String, Codable {
        case bookmark
        case underline
    }

    let id: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let position: CoreTextReadingPosition
    let length: Int
    let kind: Kind
    let date: Date
    var note: String
    let excerpt: String  // 書籤位置前幾個字的摘錄

    init(
        chapterIndex: Int,
        chapterTitle: String,
        position: CoreTextReadingPosition,
        length: Int = 0,
        kind: Kind = .bookmark,
        note: String = "",
        excerpt: String = "",
        id: UUID = UUID(),
        date: Date = Date()
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.position = position
        self.length = max(0, length)
        self.kind = kind
        self.date = date
        self.note = note
        self.excerpt = excerpt
    }

    var isChapterStartBookmark: Bool {
        position.spineIndex == chapterIndex && position.charOffset == 0
    }

    func hasSameStableLocation(as other: Bookmark) -> Bool {
        position == other.position
    }

    static func stablePositionSort(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        if lhs.position.spineIndex != rhs.position.spineIndex {
            return lhs.position.spineIndex < rhs.position.spineIndex
        }
        if lhs.position.charOffset != rhs.position.charOffset {
            return lhs.position.charOffset < rhs.position.charOffset
        }
        return lhs.date < rhs.date
    }

    enum CodingKeys: String, CodingKey {
        case id, chapterIndex, chapterTitle, position, length, kind, date, note, excerpt
        case spineIndex, charOffset, pageIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        chapterTitle = try c.decode(String.self, forKey: .chapterTitle)
        if let decodedPosition = try? c.decode(CoreTextReadingPosition.self, forKey: .position) {
            position = decodedPosition
        } else {
            let legacySpine = (try? c.decode(Int.self, forKey: .spineIndex)) ?? chapterIndex
            let legacyOffset = (try? c.decode(Int.self, forKey: .charOffset)) ?? 0
            position = CoreTextReadingPosition(spineIndex: legacySpine, charOffset: legacyOffset)
        }
        length = (try? c.decode(Int.self, forKey: .length)) ?? 0
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .bookmark
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        excerpt = (try? c.decode(String.self, forKey: .excerpt)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(chapterIndex, forKey: .chapterIndex)
        try c.encode(chapterTitle, forKey: .chapterTitle)
        try c.encode(position, forKey: .position)
        try c.encode(length, forKey: .length)
        try c.encode(kind, forKey: .kind)
        try c.encode(date, forKey: .date)
        try c.encode(note, forKey: .note)
        try c.encode(excerpt, forKey: .excerpt)
    }
}

extension Array where Element == Bookmark {
    func sortedByStablePosition() -> [Bookmark] {
        sorted(by: Bookmark.stablePositionSort)
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
    var lastOpenedDate: Date?

    // 線上書源欄位
    var isOnline: Bool
    var bookSourceId: UUID?
    var bookInfoURL: String?
    var tocURL: String?
    var runtimeVariables: [String: String]?
    var onlineChapters: [OnlineChapterRef]?

    // 書架分組
    var group: String = ""

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
        lastOpenedDate = try? c.decode(Date.self, forKey: .lastOpenedDate)
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
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, source, contentFilename, contentPipelineKind, currentPosition, addedDate
        case isOnline, bookSourceId, bookInfoURL, tocURL, runtimeVariables, onlineChapters, bookmarks
        case coverImagePath, rendererPreference, compatibilityState
        case offlineDownloadState, downloadedChapterCount, group, lastOpenedDate
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

    var allowsUserSelectedReaderFont: Bool {
        if isOnline { return true }
        return resolvedPipelineKind.allowsUserSelectedReaderFont
    }

    var isLegacyParsedEPUB: Bool {
        contentFilename.hasSuffix("_epub.json")
    }
}

enum BookPipelineKind: String, Codable {
    case epub
    case txt
    case html

    var allowsUserSelectedReaderFont: Bool {
        switch self {
        case .txt:
            return true
        case .epub, .html:
            return false
        }
    }
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
    let lineHeightMultiple: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let marginH: CGFloat
    let marginV: CGFloat
    let footerHeight: CGFloat
    let contentInsets: UIEdgeInsets
    var writingMode: ReaderWritingMode = .horizontal
}

enum ReaderWritingMode: String, CaseIterable, Codable {
    case horizontal
    case verticalRTL

    var isVertical: Bool {
        self == .verticalRTL
    }
}

extension ReadingBook {
    var allowsVerticalWritingMode: Bool {
        if isOnline { return true }
        return resolvedPipelineKind == .txt
    }
}

enum ReaderLayoutMetrics {
    static let footerHeight: CGFloat = 24
    static let footerBottomGap: CGFloat = 28
    /// 負值 = 把 footer 往螢幕底拉近。
    /// 原本 `= 0` 時 footer 離底邊 = safeAreaBottom（notch 機約 34pt）偏高；
    /// 設 -14 讓 footer 緊貼 home indicator 上方（約 20pt），視覺更貼底但不會蓋到。
    static let footerVisualBottomPadding: CGFloat = -14
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

// MARK: - 書架排序
enum BookSortOrder: String {
    case manual, recentlyRead, title, author
}

// MARK: - 書庫管理
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
