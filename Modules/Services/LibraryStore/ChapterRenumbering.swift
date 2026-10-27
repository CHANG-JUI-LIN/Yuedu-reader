import Foundation

/// A refreshed table of contents that moved chapters to other indices: old index → new index
/// of every chapter that is still in the list but no longer where it was.
///
/// A reading place is `(spineIndex, charOffset)` and a bookmark names its chapter by index, so
/// both must move with the chapter. The text is the same chapter's from the same source, so the
/// offset inside it is kept — unlike 換源 (`OnlineBookSourceSwitch`), which lands on another
/// source's text and starts the chapter from the top. Feedback #95: a source inserted one entry
/// ahead of the reader and the book reopened one chapter back.
struct ChapterRenumbering: Equatable, Sendable {
    let bookId: UUID
    let moves: [Int: Int]
    /// Every refresh that moves chapters publishes a new one, even with the same moves.
    let id = UUID()

    func chapterIndex(for old: Int) -> Int {
        moves[old] ?? old
    }

    func position(for old: CoreTextReadingPosition) -> CoreTextReadingPosition {
        guard let moved = moves[old.spineIndex] else { return old }
        return CoreTextReadingPosition(spineIndex: moved, charOffset: old.charOffset)
    }

    func bookmarks(_ bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.map { bookmark in
            guard moves[bookmark.chapterIndex] != nil || moves[bookmark.position.spineIndex] != nil else {
                return bookmark
            }
            return Bookmark(
                chapterIndex: chapterIndex(for: bookmark.chapterIndex), chapterTitle: bookmark.chapterTitle,
                position: position(for: bookmark.position), length: bookmark.length, kind: bookmark.kind,
                note: bookmark.note, excerpt: bookmark.excerpt, id: bookmark.id, date: bookmark.date,
                annotationStyle: bookmark.annotationStyle, annotationColor: bookmark.annotationColor
            )
        }
    }

    /// The image reader and the audiobook player keep their place on the record
    /// (`ReadingChapterPlace`); a page or a time inside a chapter stays with the chapter.
    /// Only the kind of book that keeps its place there, and only one already opened: 0/0 reads
    /// as "never opened" (`ReadingChapterPlace.resumeChapterIndex`), and an entry inserted at the
    /// top would otherwise mark an untouched comic as started at chapter 1.
    func applyToRecordPlaces(_ book: inout ReadingBook) {
        book.bookmarks = bookmarks(book.bookmarks)
        switch book.resolvedPipelineKind {
        case .manga, .fixedPage:
            let untouched = book.mangaChapterIndex == 0 && book.mangaPage == 0 && book.currentPosition == 0
            if !untouched { book.mangaChapterIndex = chapterIndex(for: book.mangaChapterIndex) }
        case .audio:
            let untouched = book.audioChapterIndex == 0 && book.audioTimeSeconds == 0
            if !untouched { book.audioChapterIndex = chapterIndex(for: book.audioChapterIndex) }
        default:
            break
        }
    }
}
