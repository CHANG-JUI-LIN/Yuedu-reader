import Foundation

enum OnlineInitialChapterResolver {
    static func preferredInitialChapter(
        chapterCount: Int,
        savedPositionSnapshot: Double,
        restoreTargetChapter: Int?
    ) -> Int {
        guard chapterCount > 0 else { return 0 }

        let maxIndex = chapterCount - 1
        if let restoreTargetChapter {
            return max(0, min(restoreTargetChapter, maxIndex))
        }

        let clampedProgress = min(1.0, max(0.0, savedPositionSnapshot))
        let resolved = Int(round(clampedProgress * Double(maxIndex)))
        return max(0, min(resolved, maxIndex))
    }

    /// The chapter an online book's shelf progress points at, for opening a book that has no
    /// saved position on this device.
    ///
    /// The position file (`reading_positions_v1`) and the shelf record sync separately; after a
    /// reinstall the shelf can come back first. The reader then had nothing to restore, opened
    /// at chapter 1 and saved it, and that save went up over the synced position (FB-179).
    /// `currentPosition` is what `CoreTextPageEngine.totalProgress` wrote,
    /// `(chapter + fraction) / chapterCount`, so its floor times the count is that chapter.
    /// `totalChapterCount` is the shelf's own count (`totalChapterNum`), the denominator the
    /// progress was written with, not a first page of a table of contents still loading.
    ///
    /// Fallback (disclosed per CLAUDE.md): it lands at the chapter's start, not the exact
    /// character. Only for a book with no position file; deletable once the position file
    /// always arrives before a book can be opened.
    static func shelfProgressChapter(currentPosition: Double, totalChapterCount: Int) -> Int? {
        guard totalChapterCount > 0, currentPosition > 0 else { return nil }
        let clamped = min(1.0, currentPosition)
        // The epsilon absorbs the division's rounding: 365/832*832 is 364.99999… otherwise.
        return min(Int(floor(clamped * Double(totalChapterCount) + 1e-9)), totalChapterCount - 1)
    }
}
