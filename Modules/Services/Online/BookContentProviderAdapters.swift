import Foundation
import SwiftSoup

struct TXTContentProviderAdapter: BookContentProvider {
    private let chapters: [UnifiedChapter]

    init(book: ReadingBook, store: BookStore) {
        let text = store.content(for: book)
        self.chapters = TXTChapterParser.parseUnifiedChapters(text, bookTitle: book.title)
    }

    var totalChapters: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return chapters[index].title
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard chapters.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        let chapter = chapters[index]
        return ChapterContentPayload(
            index: chapter.index,
            title: chapter.title,
            plainText: chapter.plainText,
            body: .plainText(chapter.plainText),
            sourceHref: chapter.sourceHref
        )
    }
}

struct EPUBContentProviderAdapter: BookContentProvider {
    private let session: PublicationSession

    init(session: PublicationSession) {
        self.session = session
    }

    var totalChapters: Int { session.chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard session.chapters.indices.contains(index) else { return "" }
        return session.chapters[index].title
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard session.chapters.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }

        let descriptor = session.chapters[index]
        let html = try await session.chapterHTML(at: index)
        let content = Self.extractReadableText(fromHTML: html)

        return ChapterContentPayload(
            index: descriptor.index,
            title: descriptor.title,
            plainText: content,
            body: .html(html),
            sourceHref: descriptor.href
        )
    }

    private static func extractReadableText(fromHTML html: String) -> String {
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

    private static func fallbackText(from text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// OnlineHTMLContentProviderAdapter removed — unified into OnlineChapterContentService + OnlineBookContentProvider.
// See OnlineChapterContentService in OnlineChapterContentService.swift.

// MARK: - OnlineBookContentProvider

final class OnlineBookContentProvider: BookContentProvider {
    private let service: OnlineChapterContentService

    init(service: OnlineChapterContentService) {
        self.service = service
    }

    var totalChapters: Int { service.chapterCount }

    func chapterTitle(at index: Int) -> String {
        service.title(at: index)
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        try await service.payload(at: index, policy: .cacheOnly)
    }
}

// MARK: - OnlineReaderProviderBundle

struct OnlineReaderProviderBundle {
    let provider: any BookContentProvider
    let chapterSourceHrefs: [String?]
    let bookIdentifier: String
}

// MARK: - BookContentProviderFactory

enum BookContentProviderFactory {
    @MainActor
    static func makeLocalTXTProvider(book: ReadingBook, store: BookStore) -> any BookContentProvider {
        let document = BookDocumentFactory.makeTXTDocument(book: book, store: store)
        return BookDocumentContentProviderAdapter(document: document)
    }

    static func makeEPUBProvider(book: ReadingBook, session: PublicationSession) -> any BookContentProvider {
        let document = BookDocumentFactory.makeEPUBDocument(book: book, session: session)
        return BookDocumentContentProviderAdapter(document: document)
    }

    @MainActor
    static func makeOnlineProvider(book: ReadingBook, store: BookStore?) -> (any BookContentProvider)? {
        guard book.isOnline, (book.onlineChapters?.isEmpty == false) else { return nil }
        let service = OnlineChapterContentService(book: book, store: store)
        return OnlineBookContentProvider(service: service)
    }

    @MainActor
    static func makeOnlineReaderBundle(
        book: ReadingBook,
        store: BookStore?
    ) -> OnlineReaderProviderBundle? {
        guard book.isOnline, let refs = book.onlineChapters, !refs.isEmpty else {
            return nil
        }
        let service = OnlineChapterContentService(book: book, store: store)
        return OnlineReaderProviderBundle(
            provider: OnlineBookContentProvider(service: service),
            chapterSourceHrefs: refs.map { Optional($0.sanitizedContentURL) },
            bookIdentifier: "coretext-node-\(book.id.uuidString)"
        )
    }
}
