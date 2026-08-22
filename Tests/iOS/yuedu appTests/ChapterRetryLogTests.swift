import Foundation
import Testing
@testable import yuedu_app

/// The point of this type is not that it records retries — it is that it says *why*,
/// and notices when one chapter keeps coming back. These cover both.
@Suite("ChapterRetryLog", .serialized)
struct ChapterRetryLogTests {

    private func fresh() { ChapterRetryLog.resetForTesting() }

    @Test("retries are counted per chapter, per book")
    func countsArePerChapter() {
        fresh()
        ChapterRetryLog.record(.fetchCancelled, chapter: 3, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 3, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 4, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 3, bookId: "B")

        #expect(ChapterRetryLog.retryCount(chapter: 3, bookId: "A") == 2)
        #expect(ChapterRetryLog.retryCount(chapter: 4, bookId: "A") == 1)
        #expect(ChapterRetryLog.retryCount(chapter: 3, bookId: "B") == 1)
        fresh()
    }

    /// The chapter arrived, so the run is over. Without this a book read long enough
    /// would eventually report every chapter as looping.
    @Test("a success clears the chapter's history")
    func successClearsHistory() {
        fresh()
        ChapterRetryLog.record(.fetchCancelled, chapter: 7, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 7, bookId: "A")
        #expect(ChapterRetryLog.retryCount(chapter: 7, bookId: "A") == 2)

        ChapterRetryLog.noteSuccess(chapter: 7, bookId: "A")
        #expect(ChapterRetryLog.retryCount(chapter: 7, bookId: "A") == 0)

        ChapterRetryLog.record(.userTapped, chapter: 7, bookId: "A")
        #expect(ChapterRetryLog.retryCount(chapter: 7, bookId: "A") == 1)
        fresh()
    }

    @Test("a success for one chapter does not clear another")
    func successIsScoped() {
        fresh()
        ChapterRetryLog.record(.fetchCancelled, chapter: 1, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 2, bookId: "A")
        ChapterRetryLog.noteSuccess(chapter: 1, bookId: "A")
        #expect(ChapterRetryLog.retryCount(chapter: 1, bookId: "A") == 0)
        #expect(ChapterRetryLog.retryCount(chapter: 2, bookId: "A") == 1)
        fresh()
    }

    /// The escalation is what turns a pile of retries into an actionable report, and it
    /// must fire once per stuck chapter rather than once per retry after the threshold.
    @Test("a looping chapter is reported once, with the sequence of reasons")
    func loopingChapterEscalatesOnce() {
        fresh()
        let log = DiagnosticLog.shared
        let before = log.reportableCountThisSession

        ChapterRetryLog.record(.fetchCancelled, chapter: 9, bookId: "A")
        ChapterRetryLog.record(.fetchCancelled, chapter: 9, bookId: "A")
        #expect(log.reportableCountThisSession == before, "two retries are not yet a loop")

        ChapterRetryLog.record(.cacheInconsistent, chapter: 9, bookId: "A")
        #expect(log.reportableCountThisSession == before + 1, "the third retry should report")

        // Still stuck, but already reported — no second anomaly.
        ChapterRetryLog.record(.cacheInconsistent, chapter: 9, bookId: "A")
        ChapterRetryLog.record(.cacheInconsistent, chapter: 9, bookId: "A")
        #expect(log.reportableCountThisSession == before + 1)
        fresh()
    }

    @Test("a chapter that recovers can be reported again if it gets stuck later")
    func escalationRearmsAfterSuccess() {
        fresh()
        let log = DiagnosticLog.shared
        let before = log.reportableCountThisSession

        for _ in 0..<3 { ChapterRetryLog.record(.fetchCancelled, chapter: 11, bookId: "A") }
        #expect(log.reportableCountThisSession == before + 1)

        ChapterRetryLog.noteSuccess(chapter: 11, bookId: "A")
        for _ in 0..<3 { ChapterRetryLog.record(.offlineDownload, chapter: 11, bookId: "A") }
        #expect(log.reportableCountThisSession == before + 2)
        fresh()
    }

    /// Bounded so a long download session cannot grow this without limit.
    @Test("only a bounded number of chapters is tracked")
    func trackingIsBounded() {
        fresh()
        for chapter in 0..<200 {
            ChapterRetryLog.record(.offlineDownload, chapter: chapter, bookId: "A")
        }
        // The earliest chapters were evicted; the most recent are still tracked.
        #expect(ChapterRetryLog.retryCount(chapter: 0, bookId: "A") == 0)
        #expect(ChapterRetryLog.retryCount(chapter: 199, bookId: "A") == 1)
        fresh()
    }

    @Test("a nil book id does not collide with a real one")
    func nilBookIdIsItsOwnBucket() {
        fresh()
        ChapterRetryLog.record(.layoutSuperseded, chapter: 5, bookId: nil)
        ChapterRetryLog.record(.fetchCancelled, chapter: 5, bookId: "A")
        #expect(ChapterRetryLog.retryCount(chapter: 5, bookId: nil) == 1)
        #expect(ChapterRetryLog.retryCount(chapter: 5, bookId: "A") == 1)
        fresh()
    }
}
