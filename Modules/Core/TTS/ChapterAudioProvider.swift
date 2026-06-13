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

@MainActor
final class LocalChapterAudioProvider: ChapterAudioProvider {
    func audio(
        for book: ReadingBook,
        chapterIndex: Int,
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

    private static func documentsURL(for relativePath: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath)
    }
}
