import Foundation
import SwiftUI

protocol WebContentFetching {
    func fetchHTML(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String?,
        allowInteractiveChallengeOn503: Bool
    ) async throws -> String
}

protocol BookSourceFetching {
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage

    func cachedTOCPackage(
        tocUrl: String,
        source: BookSource
    ) async -> TOCPackage?

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool

    func clearChapterCache(bookId: UUID, chapterIndex: Int)
    func clearAllChapterCache(bookId: UUID)
    func search(query: String, in source: BookSource) async throws -> [OnlineBook]

    /// Early-filtered search: implementations that can push the predicate into
    /// rule parsing override this (protocol requirement so existential calls
    /// dispatch dynamically); a post-filtering default exists for mocks.
    func search(
        query: String,
        in source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?
    ) async throws -> [OnlineBook]

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage?

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String?
}

extension BookSourceFetching {
    /// Cache lookup is an optional acceleration capability. Test doubles and
    /// alternate implementations without persistent TOC storage skip it and
    /// continue through the normal fetch path.
    func cachedTOCPackage(
        tocUrl: String,
        source: BookSource
    ) async -> TOCPackage? {
        nil
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> TOCPackage {
        try await fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: nil,
            forceRefresh: false
        )
    }

    /// Convenience overload that defaults `forceRefresh` to `false`, so existing
    /// reading paths keep using the cached TOC without passing the new flag.
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?
    ) async throws -> TOCPackage {
        try await fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: onFirstPageReady,
            forceRefresh: false
        )
    }

    /// Early-filtered search. Default implementation filters after the fact so
    /// existing conformers (tests/mocks) keep working; implementations that can
    /// push the predicate into rule parsing override it (LiveBookSourceFetcher).
    func search(
        query: String,
        in source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?
    ) async throws -> [OnlineBook] {
        let books = try await search(query: query, in: source)
        guard let earlyFilter else { return books }
        return books.filter { earlyFilter($0.name, $0.author) }
    }
}

/// Protocol for online book download and neighborhood chapter prefetch,
/// decoupling the reader from the concrete OnlineBookCoordinator implementation.
protocol OnlineBookCoordinating: AnyObject {
    func downloadBook(_ book: ReadingBook, store: BookStore?)
    func downloadBook(
        _ book: ReadingBook,
        store: BookStore?,
        startChapterIndex: Int,
        chapterCount: Int?
    )
    func pauseDownload(book: ReadingBook, store: BookStore?)
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async
}

protocol ChapterFetching: Sendable {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage

    func cancelChapter(bookId: UUID, chapterIndex: Int) async

    func cancelAll(for bookId: UUID) async
}

struct LiveWebContentFetcher: WebContentFetching {
    let webFetcher: WebFetcher

    func fetchHTML(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String?,
        allowInteractiveChallengeOn503: Bool
    ) async throws -> String {
        try await webFetcher.fetchHTML(
            url: url,
            method: method,
            body: body,
            headers: headers,
            baseURL: baseURL,
            bodyCharset: bodyCharset,
            allowInteractiveChallengeOn503: allowInteractiveChallengeOn503
        )
    }
}

struct LiveBookSourceFetcher: BookSourceFetching {
    let bookSourceFetcher: BookSourceFetcher

    func cachedTOCPackage(
        tocUrl: String,
        source: BookSource
    ) async -> TOCPackage? {
        await bookSourceFetcher.cachedTOCPackage(tocUrl: tocUrl, source: source)
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        try await bookSourceFetcher.fetchBookInfoPackage(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        try await bookSourceFetcher.fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: onFirstPageReady,
            forceRefresh: forceRefresh
        )
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        bookSourceFetcher.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        bookSourceFetcher.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
    }

    func clearAllChapterCache(bookId: UUID) {
        bookSourceFetcher.clearAllChapterCache(bookId: bookId)
    }

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        try await bookSourceFetcher.search(query: query, in: source)
    }

    func search(
        query: String,
        in source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?
    ) async throws -> [OnlineBook] {
        // Push the predicate into the parser so rejected items skip most rule
        // evaluations (instead of the protocol default's post-filter).
        try await bookSourceFetcher.search(
            query: query, in: source, earlyFilter: earlyFilter
        )
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        bookSourceFetcher.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        bookSourceFetcher.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }
}

struct LiveChapterFetcher: ChapterFetching {
    let chapterFetchManager: ChapterFetchManager

    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool {
        await chapterFetchManager.isChapterCached(book: book, chapterIndex: chapterIndex)
    }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        try await chapterFetchManager.fetchChapter(
            book: book,
            chapterIndex: chapterIndex,
            priority: priority,
            store: store
        )
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {
        await chapterFetchManager.cancelFetch(bookId: bookId, chapterIndex: chapterIndex)
    }

    func cancelAll(for bookId: UUID) async {
        await chapterFetchManager.cancelAll(for: bookId)
    }
}

struct AppDependencies {
    var webContentFetcher: WebContentFetching
    var bookSourceFetcher: BookSourceFetching
    var chapterFetcher: ChapterFetching
    var onlineBookCoordinator: OnlineBookCoordinating
    var readingPositionStore: ReadingPositionStore

    static let live: AppDependencies = {
        let webFetcher = WebFetcher()
        let webViewFetcher = MainActor.assumeIsolated { WebViewFetcher.shared }
        let bsf = BookSourceFetcher(webFetcher: webFetcher)
        let cfm = ChapterFetchManager(bookSourceFetcher: bsf, webViewFetcher: webViewFetcher)
        return AppDependencies(
            webContentFetcher: LiveWebContentFetcher(webFetcher: webFetcher),
            bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: bsf),
            chapterFetcher: LiveChapterFetcher(chapterFetchManager: cfm),
            onlineBookCoordinator: OnlineBookCoordinator.shared,
            readingPositionStore: JSONFileReadingPositionStore()
        )
    }()
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies = .live
}

extension EnvironmentValues {
    var appDependencies: AppDependencies {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
