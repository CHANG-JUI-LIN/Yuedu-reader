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
            content: chapter.plainText,
            renderHTML: nil,
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
            content: content,
            renderHTML: html,
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

struct OnlineHTMLContentProviderAdapter: BookContentProvider {
    private let book: ReadingBook
    private let refs: [OnlineChapterRef]
    private weak var store: BookStore?

    init(book: ReadingBook, store: BookStore?) {
        self.book = book
        self.refs = book.onlineChapters ?? []
        self.store = store
    }

    var totalChapters: Int { refs.count }

    func chapterTitle(at index: Int) -> String {
        guard refs.indices.contains(index) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: refs[index].title)
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard refs.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }

        let ref = refs[index]
        let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)

        if let cached = BookSourceFetcher.shared.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: index,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ), cached.state == .cached, !cached.content.isEmpty {
            if OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
                package: cached,
                hasBookSource: book.bookSourceId != nil
            ) {
                BookSourceFetcher.shared.clearChapterCache(bookId: book.id, chapterIndex: index)
            } else {
                return ChapterContentPayload(
                    index: index,
                    title: ReaderHTMLUtilities.displayText(fromHTMLFragment: ref.title),
                    content: cached.content,
                    renderHTML: book.bookSourceId == nil ? nil : resolveNormalizedHTML(
                        for: book.id,
                        chapterIndex: index,
                        tocTitle: ref.title,
                        primarySourceURL: sanitizedURL,
                        secondarySourceURL: ref.url,
                        fallbackContent: cached.content
                    ),
                    sourceHref: sanitizedURL
                )
            }
        }

        let pkg = try await ChapterFetchManager.shared.fetchChapter(
            book: book,
            chapterIndex: index,
            priority: .immediate,
            store: store
        )

        return ChapterContentPayload(
            index: index,
            title: ReaderHTMLUtilities.displayText(fromHTMLFragment: ref.title),
            content: pkg.content,
            renderHTML: book.bookSourceId == nil ? nil : resolveNormalizedHTML(
                for: book.id,
                chapterIndex: index,
                tocTitle: ref.title,
                primarySourceURL: sanitizedURL,
                secondarySourceURL: ref.url,
                fallbackContent: pkg.content
            ),
            sourceHref: sanitizedURL
        )
    }

    private func resolveNormalizedHTML(
        for bookId: UUID,
        chapterIndex: Int,
        tocTitle: String,
        primarySourceURL: String,
        secondarySourceURL: String,
        fallbackContent: String
    ) -> String {
        BookSourceFetcher.shared.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: primarySourceURL,
            expectedTOCTitle: tocTitle
        )
            ?? (primarySourceURL != secondarySourceURL
                ? BookSourceFetcher.shared.loadNormalizedChapterHTMLSync(
                    bookId: bookId,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: secondarySourceURL,
                    expectedTOCTitle: tocTitle
                )
                : nil)
            ?? ChapterFetcher.shared.buildNormalizedHTML(
                title: tocTitle,
                content: fallbackContent
            )
    }
}

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
        guard let document = BookDocumentFactory.makeOnlineDocument(book: book, store: store) else {
            return nil
        }
        return BookDocumentContentProviderAdapter(document: document)
    }
}
