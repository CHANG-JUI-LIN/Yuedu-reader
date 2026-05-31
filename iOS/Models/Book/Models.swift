import Combine
import Foundation
import OSLog
// MARK: - HTML to Plain Text
import SwiftSoup
import SwiftUI
import UIKit
import ReadiumShared

// MARK: - Book Chapter

struct BookChapter: Identifiable, Codable {
    var id = UUID()
    var index: Int
    var title: String
    var content: String
    var href: String = ""  // EPUB chapter path, used as the rendering baseURL
    var level: Int = 0  // TOC indentation level (0 = top, 1 = sub-chapter, …)
    var fragment: String? = nil  // EPUB TOC anchor within the spine file (the part after '#')
}

// MARK: - Online Chapter Reference

// MARK: - Bookmark

struct Bookmark: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case bookmark
        case underline
        case highlight
    }

    let id: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let position: CoreTextReadingPosition
    let length: Int
    let kind: Kind
    let date: Date
    var note: String
    let excerpt: String
    let annotationStyle: AnnotationStyle?
    let annotationColor: AnnotationColor?

    init(
        chapterIndex: Int,
        chapterTitle: String,
        position: CoreTextReadingPosition,
        length: Int = 0,
        kind: Kind = .bookmark,
        note: String = "",
        excerpt: String = "",
        id: UUID = UUID(),
        date: Date = Date(),
        annotationStyle: AnnotationStyle? = nil,
        annotationColor: AnnotationColor? = nil
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
        self.annotationStyle = annotationStyle
        self.annotationColor = annotationColor
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
        case annotationStyle, annotationColor
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
        annotationStyle = try? c.decode(AnnotationStyle.self, forKey: .annotationStyle)
        annotationColor = try? c.decode(AnnotationColor.self, forKey: .annotationColor)
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
        try c.encodeIfPresent(annotationStyle, forKey: .annotationStyle)
        try c.encodeIfPresent(annotationColor, forKey: .annotationColor)
    }
}

extension Array where Element == Bookmark {
    func sortedByStablePosition() -> [Bookmark] {
        sorted(by: Bookmark.stablePositionSort)
    }
}

// MARK: - Book Model

struct ReadingBook: Identifiable, Codable {
    let id: UUID
    var title: String
    var author: String
    var source: String  // "local", "local_epub", or a URL string
    var contentFilename: String  // Local book: filename in Documents; online book: empty string
    var contentPipelineKind: BookPipelineKind
    var currentPosition: Double  // 0.0 ~ 1.0
    var addedDate: Date
    var lastOpenedDate: Date?

    // Online book-source fields
    var isOnline: Bool
    var bookSourceId: UUID?
    var bookInfoURL: String?
    var tocURL: String?
    var runtimeVariables: [String: String]?
    var onlineChapters: [OnlineChapterRef]?

    // Bookshelf grouping
    var group: String = ""

    // Bookmarks
    var bookmarks: [Bookmark] = []

    // Cover image path (relative filename under Documents, e.g. "xxx_cover.jpg")
    var coverImagePath: String?
    var rendererPreference: BookRendererPreference
    var compatibilityState: BookCompatibilityState
    var offlineDownloadState: BookOfflineDownloadState
    var downloadedChapterCount: Int

    // Manga reading position: chapter index + page index within that chapter
    var mangaChapterIndex: Int = 0
    var mangaPage: Int = 0

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

    // Custom decoder: missing new fields fall back to defaults instead of crashing
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
        mangaChapterIndex = (try? c.decode(Int.self, forKey: .mangaChapterIndex)) ?? 0
        mangaPage = (try? c.decode(Int.self, forKey: .mangaPage)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, source, contentFilename, contentPipelineKind, currentPosition, addedDate
        case isOnline, bookSourceId, bookInfoURL, tocURL, runtimeVariables, onlineChapters, bookmarks
        case coverImagePath, rendererPreference, compatibilityState
        case offlineDownloadState, downloadedChapterCount, group, lastOpenedDate
        case mangaChapterIndex, mangaPage
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
        if contentPipelineKind == .manga { return .manga }
        if isOnline { return .html }
        if source == "local_epub" || contentFilename.hasSuffix("_epub.json") {
            return .epub
        }
        return contentPipelineKind
    }

    var allowsUserSelectedReaderFont: Bool {
        if resolvedPipelineKind == .manga { return false }
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
    case manga

    var allowsUserSelectedReaderFont: Bool {
        switch self {
        case .txt:
            return true
        case .epub, .html, .manga:
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

enum TOCLayoutMode {
    case horizontalList
    case verticalRTLColumns

    static func from(writingMode: ReaderWritingMode) -> TOCLayoutMode {
        writingMode.isVertical ? .verticalRTLColumns : .horizontalList
    }
}

extension ReadingBook {
    var allowsVerticalWritingMode: Bool {
        if isOnline { return true }
        return resolvedPipelineKind == .txt
    }
}

enum ReaderLayoutMetrics {
    static let footerHeight: CGFloat = 16
    static let defaultFooterBottomPadding: CGFloat = 4
    static let defaultFooterTextGap: CGFloat = 12

    /// Extra space below the footer text to the screen bottom edge.
    /// Text area bottom = safeBottom + footerBottomPadding + footerHeight + footerTextGap.
    static let footerPadding: CGFloat = defaultFooterBottomPadding
    static let minimumVerticalPadding: CGFloat = 24
    static let topSafeAreaExtra: CGFloat = 10

    static func topInset(safeTop: CGFloat) -> CGFloat {
        max(minimumVerticalPadding, safeTop + topSafeAreaExtra)
    }

    static func bottomInset(
        safeBottom: CGFloat,
        footerHeight: CGFloat = footerHeight,
        footerBottomPadding: CGFloat = defaultFooterBottomPadding,
        footerTextGap: CGFloat = defaultFooterTextGap
    ) -> CGFloat {
        safeBottom + footerBottomPadding + footerHeight + footerTextGap
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
        case .manga:
            return false
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

// MARK: - Bookshelf Sort

enum BookSortOrder: String {
    case manual, recentlyRead, title, author
}

// MARK: - HTML Utilities

extension String {
    /// Converts HTML to plain text while preserving paragraph boundaries.
    /// Block-level elements (p, div, br, h1-h6, li, tr, blockquote) become
    /// line breaks; inline elements have their tags removed. Preserves semantic
    /// structure for downstream splitIntoParagraphs.
    var strippedHTML: String {
        do {
            let doc = try SwiftSoup.parse(self)
            try doc.select("script, style, noscript, iframe").remove()
            let root: SwiftSoup.Element = doc.body() ?? doc
            return HTMLTextExtractor.extractPreservingBlocks(root)
        } catch {
            return self
        }
    }
}

/// Recursively traverses the DOM, inserting line breaks at block-level element boundaries.
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
                    // Block element: add newlines before and after
                    if !result.isEmpty && !result.hasSuffix("\n") {
                        result += "\n"
                    }
                    result += extractPreservingBlocks(child)
                    if !result.hasSuffix("\n") {
                        result += "\n"
                    }
                } else {
                    // Inline element: extract text directly
                    result += extractPreservingBlocks(child)
                }
            }
        }
        return result
    }
}
