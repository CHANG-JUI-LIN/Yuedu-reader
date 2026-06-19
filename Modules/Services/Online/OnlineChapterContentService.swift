import Foundation

enum OnlineChapterLoadPolicy: Equatable {
    case cacheOnly
    case fetchIfMissing
}

final class OnlineChapterContentService {
    private let book: ReadingBook
    private let refs: [OnlineChapterRef]
    private weak var store: BookStore?

    init(book: ReadingBook, store: BookStore?) {
        self.book = book
        self.refs = book.onlineChapters ?? []
        self.store = store
    }

    var chapterCount: Int { refs.count }

    func title(at index: Int) -> String {
        guard refs.indices.contains(index) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: refs[index].title)
    }

    func chapterID(at index: Int) -> String? {
        guard refs.indices.contains(index) else { return nil }
        let sanitized = refs[index].sanitizedContentURL
        return sanitized.isEmpty ? String(index) : sanitized
    }

    func index(forChapterID chapterID: String) -> Int? {
        if let direct = refs.firstIndex(where: { $0.sanitizedContentURL == chapterID }) {
            return direct
        }
        guard let parsed = Int(chapterID), refs.indices.contains(parsed) else { return nil }
        return parsed
    }

    func payload(
        at index: Int,
        policy: OnlineChapterLoadPolicy
    ) async throws -> ChapterContentPayload {
        guard refs.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }

        let ref = refs[index]
        if ref.shouldRenderAsVolumeSeparator {
            return volumeSeparatorPayload(ref: ref, index: index)
        }

        let sanitizedURL = ref.sanitizedContentURL
        if let cached = BookSourceFetcher.shared.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: index,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ), cached.state == .cached, !cached.content.isEmpty {
            let invalidArtifacts = OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
                package: cached,
                hasBookSource: book.bookSourceId != nil
            )
            let suspiciousContent = ChapterFetchManager.isSuspiciousChapterContent(cached.content)
            if invalidArtifacts || suspiciousContent {
                BookSourceFetcher.shared.clearChapterCache(bookId: book.id, chapterIndex: index)
            } else {
                return makePayload(package: cached, ref: ref, index: index)
            }
        }

        guard policy == .fetchIfMissing else {
            throw BookContentProviderError.contentNotCached(index)
        }

        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: book,
            chapterIndex: index,
            priority: .immediate,
            store: store
        )
        return makePayload(package: package, ref: ref, index: index)
    }

    // MARK: - Private

    private func makePayload(
        package: ChapterPackage,
        ref: OnlineChapterRef,
        index: Int
    ) -> ChapterContentPayload {
        let sanitizedURL = ref.sanitizedContentURL
        let html = BookSourceFetcher.shared.loadNormalizedChapterHTMLSync(
            bookId: book.id,
            chapterIndex: index,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ) ?? (sanitizedURL != ref.url
            ? BookSourceFetcher.shared.loadNormalizedChapterHTMLSync(
                bookId: book.id,
                chapterIndex: index,
                expectedSourceURL: ref.url,
                expectedTOCTitle: ref.title
            )
            : nil
        ) ?? ChapterFetcher.shared.buildNormalizedHTML(
            title: ref.title,
            content: package.content
        )

        return ChapterContentPayload(
            index: index,
            title: title(at: index),
            plainText: package.content,
            body: .html(html),
            sourceHref: sanitizedURL
        )
    }

    private func volumeSeparatorPayload(
        ref: OnlineChapterRef,
        index: Int
    ) -> ChapterContentPayload {
        let displayTitle = title(at: index).isEmpty ? localized("作品相關") : title(at: index)
        let escaped = ReaderHTMLUtilities.escapeHTML(displayTitle)
        let html = """
        <!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"></head>
        <body><section class="yd-volume-separator"><h1>\(escaped)</h1></section></body></html>
        """
        return ChapterContentPayload(
            index: index,
            title: displayTitle,
            plainText: displayTitle,
            body: .html(html),
            sourceHref: "volume/\(index)"
        )
    }
}
