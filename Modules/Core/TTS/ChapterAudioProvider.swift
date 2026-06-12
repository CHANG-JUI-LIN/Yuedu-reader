import Foundation

struct ChapterAudio {
    let url: URL
    let headers: [String: String]
}

enum ChapterAudioProviderError: LocalizedError {
    case missingAudio(contentLength: Int, preview: String)

    var errorDescription: String? {
        switch self {
        case .missingAudio:
            return localized("未找到音訊")
        }
    }
}

@MainActor
protocol ChapterAudioProvider: AnyObject {
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
        store: BookStore
    ) async throws -> ChapterAudio
}

@MainActor
final class OnlineChapterAudioProvider: ChapterAudioProvider {
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
        store: BookStore
    ) async throws -> ChapterAudio {
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: book,
            chapterIndex: chapterIndex,
            priority: .immediate,
            store: store
        )

        guard let request = DirectChapterAudioResolver.request(from: package.content),
              let url = request.url else {
            throw ChapterAudioProviderError.missingAudio(
                contentLength: package.content.count,
                preview: String(package.content.prefix(160))
            )
        }

        let mergedHeaders = sourceHeaders(for: book)
            .merging(request.allHTTPHeaderFields ?? [:]) { _, requestValue in requestValue }

        return ChapterAudio(
            url: url,
            headers: mergedHeaders
        )
    }

    private func sourceHeaders(for book: ReadingBook) -> [String: String] {
        let source = book.bookSourceId.flatMap { id in
            BookSourceStore.shared.sources.first { $0.id == id }
        }
        return BookCoverLoader.headers(
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
    }
}
