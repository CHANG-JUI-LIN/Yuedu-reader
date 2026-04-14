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
        runtimeVariables: [String: String]?
    ) async throws -> TOCPackage

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool

    func clearChapterCache(bookId: UUID, chapterIndex: Int)
    func search(query: String, in source: BookSource) async throws -> [OnlineBook]

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage?
}

protocol ChapterFetching {
    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage

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
        runtimeVariables: [String: String]?
    ) async throws -> TOCPackage {
        try await bookSourceFetcher.fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables
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

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        try await bookSourceFetcher.search(query: query, in: source)
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
}

struct LiveChapterFetcher: ChapterFetching {
    let chapterFetchManager: ChapterFetchManager

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

    func cancelAll(for bookId: UUID) async {
        await chapterFetchManager.cancelAll(for: bookId)
    }
}

struct AppDependencies {
    var webContentFetcher: WebContentFetching
    var bookSourceFetcher: BookSourceFetching
    var chapterFetcher: ChapterFetching

    static let live: AppDependencies = {
        let webFetcher = WebFetcher()
        let webViewFetcher = WebViewFetcher.shared
        let bsf = BookSourceFetcher(webFetcher: webFetcher)
        let cfm = ChapterFetchManager(bookSourceFetcher: bsf, webViewFetcher: webViewFetcher)
        return AppDependencies(
            webContentFetcher: LiveWebContentFetcher(webFetcher: webFetcher),
            bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: bsf),
            chapterFetcher: LiveChapterFetcher(chapterFetchManager: cfm)
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
