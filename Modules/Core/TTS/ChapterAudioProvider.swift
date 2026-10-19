import Foundation

struct ChapterAudio {
    let url: URL
    let headers: [String: String]
    let chapterStartSeconds: Double?
    let chapterDurationSeconds: Double?

    init(
        url: URL,
        headers: [String: String] = [:],
        chapterStartSeconds: Double? = nil,
        chapterDurationSeconds: Double? = nil
    ) {
        self.url = url
        self.headers = headers
        self.chapterStartSeconds = chapterStartSeconds
        self.chapterDurationSeconds = chapterDurationSeconds
    }
}

enum ChapterAudioProviderError: LocalizedError {
    case missingAudio(contentLength: Int, preview: String)
    case missingLocalAudio

    var errorDescription: String? {
        switch self {
        case .missingAudio:
            return localized("未找到音訊")
        case .missingLocalAudio:
            return localized("音訊檔案不在此裝置上，請重新匯入")
        }
    }
}

@MainActor
protocol ChapterAudioProvider: AnyObject {
    /// The chapter's playable link. `priority` is `.immediate` for the chapter the listener
    /// is waiting on and `.prefetch` for a look-ahead (`AudiobookResourcePreloader`).
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore
    ) async throws -> ChapterAudio

    /// Forgets the chapter's resolved link so the next `audio` call resolves it again —
    /// legado's `AudioPlayManager.refreshChapter` (`chapter.resourceUrl = null`), which its
    /// player runs once, silently, when a link fails to play: most links are time-signed,
    /// so a failure usually means the link expired while it sat resolved.
    func discardResolvedAudio(for book: ReadingBook, chapterIndex: Int, store: BookStore)
}

@MainActor
final class OnlineChapterAudioProvider: ChapterAudioProvider {
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore
    ) async throws -> ChapterAudio {
        // Cache first, like every online chapter: the cached content is this chapter's
        // resolved link (legado keeps it in `BookChapter.resourceUrl`).
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: book,
            chapterIndex: chapterIndex,
            priority: priority,
            store: store
        )

        guard let request = DirectChapterAudioResolver.request(from: package.content),
              let url = request.url else {
            throw ChapterAudioProviderError.missingAudio(
                contentLength: package.content.count,
                preview: String(package.content.prefix(160))
            )
        }

        let mergedHeaders = await sourceHeaders(for: book)
            .merging(request.allHTTPHeaderFields ?? [:]) { _, requestValue in requestValue }

        return ChapterAudio(
            url: url,
            headers: mergedHeaders
        )
    }

    /// The same two steps the reader's refetch takes: the cached chapter file, and the
    /// shelf record's pointer to it.
    func discardResolvedAudio(for book: ReadingBook, chapterIndex: Int, store: BookStore) {
        BookSourceFetcher.shared.clearChapterCache(bookId: book.id, chapterIndex: chapterIndex)
        store.clearCachedChapter(bookId: book.id, chapterIndex: chapterIndex)
    }

    private func sourceHeaders(for book: ReadingBook) async -> [String: String] {
        let source = book.bookSourceId.flatMap { id in
            BookSourceStore.shared.source(id: id)
        }
        return BookCoverLoader.headers(
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: await source?.resolvedHeaders() ?? [:]
        )
    }
}

@MainActor
final class LocalChapterAudioProvider: ChapterAudioProvider {
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore
    ) async throws -> ChapterAudio {
        guard let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            throw ChapterAudioProviderError.missingAudio(contentLength: 0, preview: "")
        }
        let ref = refs[chapterIndex]

        let url = Self.documentsURL(for: ref.url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChapterAudioProviderError.missingLocalAudio
        }

        return ChapterAudio(
            url: url,
            chapterStartSeconds: ref.audioStartSeconds,
            chapterDurationSeconds: ref.audioDurationSeconds
        )
    }

    /// A local chapter's link is a file path; there is nothing resolved to forget.
    func discardResolvedAudio(for book: ReadingBook, chapterIndex: Int, store: BookStore) {}

    /// Audio extracted from a user-supplied archive (`local_audio/<id>/…`) or the
    /// audiobook file itself — user content, so it stays in Documents.
    private static func documentsURL(for relativePath: String) -> URL {
        StorageLocations.bookFile(relativePath)
    }
}
