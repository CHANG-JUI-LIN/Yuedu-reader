import CoreGraphics
import Testing
@testable import yuedu_app

/// `ReaderPageTouchProbe` (FB-173 diagnostic): which touches it reports, and how many.
struct ReaderPageTouchProbeTests {
    @Test func anUnansweredTouchIsReportedWhenTheNextOneBegins() {
        var ledger = ReaderPageTouchLedger()
        #expect(ledger.begin("first") == nil)
        #expect(ledger.begin("second") == "first")
    }

    @Test func anAnsweredTouchIsNotReported() {
        var ledger = ReaderPageTouchLedger()
        _ = ledger.begin("tap")
        ledger.pageAnswered()
        #expect(ledger.begin("next") == nil)
        #expect(ledger.reportedCount == 0)
    }

    @Test func anAnswerBelongsToItsOwnTouchOnly() {
        var ledger = ReaderPageTouchLedger()
        _ = ledger.begin("answered")
        ledger.pageAnswered()
        _ = ledger.begin("unanswered")
        #expect(ledger.close() == "unanswered")
    }

    @Test func aTouchThatDoesNotCountStillClosesThePreviousOne() {
        var ledger = ReaderPageTouchLedger()
        _ = ledger.begin("over the page")
        #expect(ledger.begin(nil) == "over the page")
        #expect(ledger.close() == nil)
    }

    @Test func leavingThePageReportsTheOpenTouchOnce() {
        var ledger = ReaderPageTouchLedger()
        _ = ledger.begin("last")
        #expect(ledger.close() == "last")
        #expect(ledger.close() == nil)
    }

    @Test func aPageReportsNoMoreThanItsBudget() {
        var ledger = ReaderPageTouchLedger()
        var reports = 0
        for index in 0...(ReaderPageTouchLedger.budget + 5) {
            if ledger.begin("touch \(index)") != nil { reports += 1 }
        }
        if ledger.close() != nil { reports += 1 }
        #expect(reports == ReaderPageTouchLedger.budget)
        #expect(ledger.reportedCount == ReaderPageTouchLedger.budget)
    }

    /// A touch that never reached the page counts only in the band where no reader bar sits:
    /// on a 874pt-tall window, the toolbar's buttons (y≈806) and the top bar stay out.
    @MainActor
    @Test func anUnreachedTouchCountsOnlyBetweenTheBars() {
        let window = CGSize(width: 402, height: 874)
        #expect(ReaderPageTouchProbe.counts(unreachedAt: CGPoint(x: 201, y: 437), in: window))
        #expect(ReaderPageTouchProbe.counts(unreachedAt: CGPoint(x: 201, y: 200), in: window))
        #expect(!ReaderPageTouchProbe.counts(unreachedAt: CGPoint(x: 130, y: 806), in: window))
        #expect(!ReaderPageTouchProbe.counts(unreachedAt: CGPoint(x: 201, y: 60), in: window))
        #expect(!ReaderPageTouchProbe.counts(unreachedAt: CGPoint(x: 201, y: 437), in: .zero))
    }
}
