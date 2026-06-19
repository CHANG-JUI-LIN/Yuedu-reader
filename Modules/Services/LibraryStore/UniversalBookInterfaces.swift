import Foundation
import SwiftSoup

#if canImport(PDFKit)
import PDFKit
typealias UniversalPDFPage = PDFPage
#else
final class UniversalPDFPage {}
#endif

enum ChapterContent {
    case text(String)
    case html(String)
    case image(URL)
    case pdfPage(UniversalPDFPage)
}

struct BookMetadata {
    let id: UUID
    let title: String
    let author: String
    let coverImagePath: String?
}

struct UniversalChapter: Identifiable {
    let id: String
    let title: String
    let content: ChapterContent
    var subChapters: [UniversalChapter] = []
}

struct ReaderCapabilities: OptionSet {
    let rawValue: Int

    static let fontSize = ReaderCapabilities(rawValue: 1 << 0)
    static let lineHeight = ReaderCapabilities(rawValue: 1 << 1)  // scroll mode / page-turn animation / page margins
    static let background = ReaderCapabilities(rawValue: 1 << 2)
    static let darkMode = ReaderCapabilities(rawValue: 1 << 3)
    static let spacing = ReaderCapabilities(rawValue: 1 << 4)     // line / letter / paragraph spacing

    static let reflowableText: ReaderCapabilities = [.fontSize, .lineHeight, .spacing, .background, .darkMode]
    static let fixedLayout: ReaderCapabilities = [.background, .darkMode]
}

protocol BookDocument {
    var metadata: BookMetadata { get }
    var tableOfContents: [UniversalChapter] { get }
    var capabilities: ReaderCapabilities { get }
    func loadContent(for chapterId: String) async throws -> ChapterContent
}

typealias UniversalBook = any BookDocument

enum BookDocumentError: LocalizedError {
    case chapterNotFound(String)
    case unsupportedContentType(String)

    var errorDescription: String? {
        switch self {
        case .chapterNotFound(let id):
            return "找不到章節：\(id)"
        case .unsupportedContentType(let type):
            return "目前閱讀器不支援此內容類型：\(type)"
        }
    }
}

private enum UniversalBookHelpers {
    static func flattenChapters(_ chapters: [UniversalChapter]) -> [UniversalChapter] {
        chapters.flatMap { chapter in
            [chapter] + flattenChapters(chapter.subChapters)
        }
    }

    static func normalizedText(fromHTML html: String) -> String {
        guard let document = try? SwiftSoup.parse(html) else {
            return fallbackText(from: html)
        }

        _ = try? document.select("script,style,noscript,iframe").remove()
        if let body = document.body() {
            let paragraphNodes = (try? body.select("p,li,blockquote,pre").array()) ?? []
            let fromNodes = paragraphNodes
                .compactMap { try? $0.text() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !fromNodes.isEmpty {
                return fromNodes.joined(separator: "\n")
            }

            if let bodyText = try? body.text() {
                let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return fallbackText(from: trimmed)
                }
            }
        }

        return ""
    }

    static func fallbackText(from text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct TXTBookDocument: BookDocument {
    let metadata: BookMetadata
    let tableOfContents: [UniversalChapter]
    let capabilities: ReaderCapabilities = .reflowableText

    private let chapterTextByID: [String: String]
    private let indexedRangesByID: [String: NSRange]
    private let indexedText: String?
    private let mappedRangesByID: [String: Range<Int>]
    private let mappedTextFile: TXTMappedTextFile?

    init(book: ReadingBook, store: BookStore) {
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        let chapters = TXTChapterParser.parseUnifiedChapters(store.content(for: book), bookTitle: book.title)
        self.tableOfContents = Self.makeTableOfContents(from: chapters)
        self.chapterTextByID = Dictionary(uniqueKeysWithValues: chapters.map { (String($0.index), $0.plainText) })
        self.indexedRangesByID = [:]
        self.indexedText = nil
        self.mappedRangesByID = [:]
        self.mappedTextFile = nil
    }

    init(book: ReadingBook, chapters: [UnifiedChapter]) {
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        self.tableOfContents = Self.makeTableOfContents(from: chapters)
        self.chapterTextByID = Dictionary(uniqueKeysWithValues: chapters.map { (String($0.index), $0.plainText) })
        self.indexedRangesByID = [:]
        self.indexedText = nil
        self.mappedRangesByID = [:]
        self.mappedTextFile = nil
    }

    init(book: ReadingBook, chapterIndexes: [TXTChapterIndex], text: String) {
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        self.tableOfContents = chapterIndexes.map { idx in
            UniversalChapter(
                id: String(idx.index),
                title: idx.title,
                content: .text("")
            )
        }
        self.chapterTextByID = [:]
        self.indexedRangesByID = Dictionary(uniqueKeysWithValues: chapterIndexes.map { (String($0.index), $0.contentRange) })
        self.indexedText = text
        self.mappedRangesByID = [:]
        self.mappedTextFile = nil
    }

    init(book: ReadingBook, mappedChapterIndexes: [TXTMappedChapterIndex], mappedTextFile: TXTMappedTextFile) {
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        self.tableOfContents = mappedChapterIndexes.map { idx in
            UniversalChapter(
                id: String(idx.index),
                title: idx.title,
                content: .text("")
            )
        }
        self.chapterTextByID = [:]
        self.indexedRangesByID = [:]
        self.indexedText = nil
        self.mappedRangesByID = Dictionary(uniqueKeysWithValues: mappedChapterIndexes.map { (String($0.index), $0.byteRange) })
        self.mappedTextFile = mappedTextFile
    }

    private static func makeTableOfContents(from chapters: [UnifiedChapter]) -> [UniversalChapter] {
        chapters.map {
            UniversalChapter(
                id: String($0.index),
                title: $0.title,
                content: .text($0.plainText)
            )
        }
    }

    func loadContent(for chapterId: String) async throws -> ChapterContent {
        if let chapterText = chapterTextByID[chapterId] {
            return .text(chapterText)
        }

        if let text = indexedText, let range = indexedRangesByID[chapterId] {
            return .text(TXTChapterParser.chapterText(text, range: range))
        }

        if let mappedTextFile, let byteRange = mappedRangesByID[chapterId] {
            return .text(TXTChapterParser.chapterText(mappedTextFile, byteRange: byteRange))
        }

        guard let chapter = tableOfContents.first(where: { $0.id == chapterId }) else {
            throw BookDocumentError.chapterNotFound(chapterId)
        }
        return chapter.content
    }
}

struct EPUBBookDocument: BookDocument {
    let metadata: BookMetadata
    let tableOfContents: [UniversalChapter]
    // .spacing is temporarily disabled: line/paragraph/letter spacing is not yet
    // fully supported for EPUB due to CSS priority conflicts.
    // Will be re-enabled after HTMLAttributedStringBuilder applies user overrides.
    let capabilities: ReaderCapabilities = [.fontSize, .lineHeight, .background, .darkMode]

    private let session: PublicationSession

    init(book: ReadingBook, session: PublicationSession) {
        self.session = session
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        self.tableOfContents = session.chapters.map { descriptor in
            let id = descriptor.href.isEmpty ? String(descriptor.index) : descriptor.href
            return UniversalChapter(
                id: id,
                title: descriptor.title,
                content: .text("")
            )
        }
    }

    func loadContent(for chapterId: String) async throws -> ChapterContent {
        guard let descriptor = session.chapters.first(where: {
            let id = $0.href.isEmpty ? String($0.index) : $0.href
            return id == chapterId || String($0.index) == chapterId
        }) else {
            throw BookDocumentError.chapterNotFound(chapterId)
        }

        let html = try await session.chapterHTML(at: descriptor.index)
        let text = UniversalBookHelpers.normalizedText(fromHTML: html)
        return .text(text)
    }
}

struct OnlineHTMLBookDocument: BookDocument {
    let metadata: BookMetadata
    let tableOfContents: [UniversalChapter]
    let capabilities: ReaderCapabilities = .reflowableText

    private let service: OnlineChapterContentService

    init(book: ReadingBook, store: BookStore?) {
        let service = OnlineChapterContentService(book: book, store: store)
        self.service = service
        self.metadata = BookMetadata(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImagePath: book.coverImagePath
        )
        self.tableOfContents = (0..<service.chapterCount).map { index in
            UniversalChapter(
                id: service.chapterID(at: index) ?? String(index),
                title: service.title(at: index),
                content: .text("")
            )
        }
    }

    func loadContent(for chapterId: String) async throws -> ChapterContent {
        guard let index = service.index(forChapterID: chapterId) else {
            throw BookDocumentError.chapterNotFound(chapterId)
        }
        let payload = try await service.payload(at: index, policy: .fetchIfMissing)
        switch payload.body {
        case .html(let html): return .html(html)
        case .plainText(let text): return .text(text)
        }
    }
}

enum BookDocumentFactory {
    @MainActor
    static func makeTXTDocument(book: ReadingBook, store: BookStore) -> any BookDocument {
        TXTBookDocument(book: book, store: store)
    }

    @MainActor
    static func makeTXTDocument(book: ReadingBook, chapters: [UnifiedChapter]) -> any BookDocument {
        TXTBookDocument(book: book, chapters: chapters)
    }

    @MainActor
    static func makeTXTDocument(book: ReadingBook, chapterIndexes: [TXTChapterIndex], text: String) -> any BookDocument {
        TXTBookDocument(book: book, chapterIndexes: chapterIndexes, text: text)
    }

    @MainActor
    static func makeTXTDocument(book: ReadingBook, mappedChapterIndexes: [TXTMappedChapterIndex], mappedTextFile: TXTMappedTextFile) -> any BookDocument {
        TXTBookDocument(book: book, mappedChapterIndexes: mappedChapterIndexes, mappedTextFile: mappedTextFile)
    }

    static func makeEPUBDocument(book: ReadingBook, session: PublicationSession) -> any BookDocument {
        EPUBBookDocument(book: book, session: session)
    }

    @MainActor
    static func makeOnlineDocument(book: ReadingBook, store: BookStore?) -> (any BookDocument)? {
        guard book.isOnline, (book.onlineChapters?.isEmpty == false) else { return nil }
        return OnlineHTMLBookDocument(book: book, store: store)
    }
}

struct BookDocumentContentProviderAdapter: BookContentProvider {
    private let document: any BookDocument
    private let chapters: [UniversalChapter]

    init(document: any BookDocument) {
        self.document = document
        self.chapters = UniversalBookHelpers.flattenChapters(document.tableOfContents)
    }

    var totalChapters: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: chapters[index].title)
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard chapters.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }

        let chapter = chapters[index]
        let content = try await document.loadContent(for: chapter.id)
        switch content {
        case .text(let text):
            return ChapterContentPayload(
                index: index,
                title: chapter.title,
                plainText: text,
                body: .plainText(text),
                sourceHref: chapter.id
            )
        case .html(let html):
            return ChapterContentPayload(
                index: index,
                title: chapter.title,
                plainText: UniversalBookHelpers.normalizedText(fromHTML: html),
                body: .html(html),
                sourceHref: chapter.id
            )
        case .image(let url):
            throw BookContentProviderError.unsupportedChapterContent("image:\(url.absoluteString)")
        case .pdfPage:
            throw BookContentProviderError.unsupportedChapterContent("pdfPage")
        }
    }
}
