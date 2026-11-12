import Foundation
import Testing
@testable import yuedu_app

/// FB-179: reinstalled, the shelf came back from iCloud at 44% while the book's position file
/// had not, and the reader opened at chapter 1. With no position file on this device, an online
/// book opens at the chapter its shelf progress names (`ReaderView.shelfProgressOpeningPosition`).
@Suite("Online shelf progress opening")
struct OnlineShelfProgressOpeningTests {

    @Test("halfway through 100 chapters opens chapter 51 (index 50)")
    func halfwayOpensTheMiddleChapter() {
        #expect(OnlineInitialChapterResolver.shelfProgressChapter(currentPosition: 0.5, totalChapterCount: 100) == 50)
    }

    /// The inverse of what `CoreTextPageEngine.totalProgress` wrote, `(chapter + fraction) / count`,
    /// so a reinstall does not drift a chapter each time.
    @Test("every chapter's saved progress opens that same chapter")
    func invertsTheEnginesProgress() {
        let count = 832
        for chapter in [0, 1, 365, 366, 831] {
            for fraction in [0.0, 0.3, 0.99] {
                let progress = (Double(chapter) + fraction) / Double(count)
                #expect(
                    OnlineInitialChapterResolver.shelfProgressChapter(currentPosition: progress, totalChapterCount: count)
                        == (progress > 0 ? chapter : nil)
                )
            }
        }
    }

    @Test("a finished book opens its last chapter; no progress or no count opens nothing")
    func edges() {
        #expect(OnlineInitialChapterResolver.shelfProgressChapter(currentPosition: 1.0, totalChapterCount: 100) == 99)
        #expect(OnlineInitialChapterResolver.shelfProgressChapter(currentPosition: 0, totalChapterCount: 100) == nil)
        #expect(OnlineInitialChapterResolver.shelfProgressChapter(currentPosition: 0.5, totalChapterCount: 0) == nil)
    }
}
