import Foundation

// MARK: - 章節快取委派（ChapterCacheRepository）

extension BookSourceFetcher {

    nonisolated func loadCachedChapterSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadCachedChapterSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        Self.chapterCacheRepository.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        Self.chapterCacheRepository.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
    }

    /// 清空該書所有章節快取（換源時呼叫）
    nonisolated func clearAllChapterCache(bookId: UUID) {
        Self.chapterCacheRepository.clearAllChapterCache(bookId: bookId)
    }

    @discardableResult
    nonisolated func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil
    ) -> String {
        Self.chapterCacheRepository.saveToCache(
            content: content,
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            rawHTML: rawHTML
        )
    }

    @discardableResult
    nonisolated func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String
    ) -> String {
        Self.chapterCacheRepository.saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML
        )
    }

    nonisolated func saveFailureMarker(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        reason: String? = nil
    ) {
        Self.chapterCacheRepository.saveFailureMarker(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            reason: reason
        )
    }

    nonisolated func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        Self.chapterCacheRepository.loadCachedChapterMetadataSync(
            bookId: bookId,
            chapterIndex: chapterIndex
        )
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        Self.chapterCacheRepository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }
}
