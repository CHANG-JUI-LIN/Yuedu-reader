import Foundation

/// The chapter a book's reader opens at, kept where that reader restores from.
///
/// Text readers restore from the position store; the image reader restores from the record's
/// `mangaChapterIndex` / `mangaPage`, and the audiobook player from `audioChapterIndex` /
/// `audioTimeSeconds` (`OnlineBookSourceSwitch` maps them the same way). Until 2026-10-21 the
/// detail pages wrote every chosen chapter into the position store, so a comic opened from
/// 目錄 at any chapter started at its first (feedback #34, every comic source).
@MainActor
struct ReadingChapterPlace {
    let store: BookStore
    let positionStore: ReadingPositionStore

    /// Makes the next open of `bookId` start at the top of chapter `index`.
    func open(atChapter index: Int, bookId: UUID) async {
        guard let book = store.readingBook(id: bookId) else { return }
        let total = book.onlineChapters?.count ?? 0
        switch book.resolvedPipelineKind {
        case .manga, .fixedPage:
            store.updateMangaPosition(bookId: bookId, chapter: index, page: 0, totalChapters: total, forceSave: true)
        case .audio:
            store.updateAudioPosition(bookId: bookId, chapter: index, time: 0, totalChapters: total, forceSave: true)
        default:
            await positionStore.save(CoreTextReadingPosition(spineIndex: index, charOffset: 0), for: bookId.uuidString)
        }
    }

    /// The chapter the next open of `bookId` resumes at, or nil when nothing was read yet.
    func resumeChapterIndex(of bookId: UUID) async -> Int? {
        guard let book = store.readingBook(id: bookId) else { return nil }
        switch book.resolvedPipelineKind {
        case .manga, .fixedPage:
            let untouched = book.mangaChapterIndex == 0 && book.mangaPage == 0 && book.currentPosition == 0
            return untouched ? nil : book.mangaChapterIndex
        case .audio:
            let untouched = book.audioChapterIndex == 0 && book.audioTimeSeconds == 0
            return untouched ? nil : book.audioChapterIndex
        default:
            return await positionStore.load(for: bookId.uuidString)?.spineIndex
        }
    }
}
