import Foundation
import Testing
@testable import yuedu_app

/// Guards for the two invariants in `ReaderPositionSentry`.
///
/// These encode the shape of the bug the sentry exists to catch: `Technotes/
/// ReaderPagingContract.md` records the user report as "章末往前撥會連跳到下一章
/// 第二頁" — one chapter forward, but two pages instead of one. A "jumped too many
/// chapters" test would pass on that input, which is exactly why G1 checks the
/// stepped destination rather than the distance.
@Suite("ReaderPositionSentry")
@MainActor
struct ReaderPositionSentryTests {

    /// Collects what the sentry concluded instead of sending it to the log.
    private final class Recorder {
        var reports: [ReaderPositionSentry.Report] = []
        var anomalies: [ReaderPositionSentry.Report] { reports.filter { $0.severity == .anomaly } }
    }

    private func makeSentry() -> (ReaderPositionSentry, Recorder) {
        let recorder = Recorder()
        let sentry = ReaderPositionSentry { recorder.reports.append($0) }
        sentry.beginBook(label: "test")
        return (sentry, recorder)
    }

    private func position(_ spine: Int, _ offset: Int) -> CoreTextReadingPosition {
        CoreTextReadingPosition(spineIndex: spine, charOffset: offset)
    }

    // MARK: - G1: a step lands where the walker said it would

    @Test("a gesture landing on the computed next page is silent")
    func gestureForwardIsClean() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
        sentry.observeCommit(position(3, 200), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("a gesture that snaps back to where it started is silent")
    func gestureSnapBackIsClean() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
        sentry.observeCommit(start, source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("crossing a chapter boundary by one page is silent")
    func chapterBoundaryStepIsClean() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 900)
        sentry.expectGesture(from: start, before: position(3, 800), after: position(4, 0))
        sentry.observeCommit(position(4, 0), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    /// The reported bug, reproduced as a value: the turn was supposed to land on the
    /// first page of chapter 4 and landed on its second. Only one chapter apart, so
    /// nothing that measures distance would notice.
    @Test("landing one page past the stepped destination is an anomaly")
    func overshootByOnePageIsAnomaly() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 900)
        sentry.expectGesture(from: start, before: position(3, 800), after: position(4, 0))
        sentry.observeCommit(position(4, 1200), source: .pagedTurn)

        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies.first?.detail.contains("guard=G1") == true)
        #expect(recorder.anomalies.first?.detail.contains("landed=(ch4,off1200)") == true)
    }

    @Test("an abandoned swipe leaves no expectation to judge")
    func cancelledExpectationIsNotJudged() {
        let (sentry, recorder) = makeSentry()
        sentry.expectGesture(from: position(3, 100), before: nil, after: position(3, 200))
        sentry.cancelExpectation()
        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("a placeholder landing is reported quietly, not as an anomaly")
    func placeholderMismatchIsDowngraded() {
        let (sentry, recorder) = makeSentry()
        sentry.expectGesture(from: position(3, 900), before: nil, after: position(4, 0))
        sentry.observeCommit(position(4, 1200), source: .pagedTurn, isPlaceholder: true)

        #expect(recorder.anomalies.isEmpty)
        #expect(recorder.reports.count == 1)
        #expect(recorder.reports.first?.severity == .notice)
    }

    // MARK: - G2: a multi-chapter jump had a reason

    @Test("jumping several chapters with nothing asking for it is an anomaly")
    func undeclaredMultiChapterJumpIsAnomaly() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        sentry.observeCommit(position(9, 0), source: .pagedTurn)

        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies.first?.detail.contains("guard=G2") == true)
        #expect(recorder.anomalies.first?.detail.contains("spineDelta=6") == true)
    }

    @Test("a declared jump to the same chapter is silent")
    func declaredJumpIsClean() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        sentry.declareIntent(.tocJump, target: position(9, 0))
        sentry.observeCommit(position(9, 0), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    /// A jump lands twice — first on the placeholder page, then on the real one once
    /// the chapter finishes paginating (`Technotes/ReaderChapterSupply.md`
    /// invariant 1). Both commits carry the target's spine, so neither may be flagged.
    @Test("placeholder then real landing of one jump does not double-report")
    func jumpSettlingTwiceIsClean() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        sentry.declareIntent(.tocJump, target: position(9, 0))
        sentry.observeCommit(position(9, 0), source: .pagedTurn, isPlaceholder: true)
        sentry.observeCommit(position(9, 340), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("the first commit of a book is never a jump")
    func firstCommitHasNoBaseline() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(42, 0), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("a new book does not inherit the previous book's position")
    func beginBookClearsBaseline() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(2, 0), source: .pagedTurn)
        sentry.beginBook(label: "another")
        sentry.observeCommit(position(80, 0), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("scroll mode is watched by the same guard")
    func scrollCommitIsWatched() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(1, 0), source: .scrollSettle)
        sentry.observeCommit(position(7, 0), source: .scrollSettle)
        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies.first?.detail.contains("source=scrollSettle") == true)
    }

    // MARK: - Intent bookkeeping

    /// An intent that never arrives must not vouch for the rest of the session, and
    /// the fact that it never arrived is worth saying.
    @Test("a declared jump that never lands is dropped and reported")
    func unmatchedIntentExpires() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn)
        sentry.declareIntent(.tocJump, target: position(50, 0))

        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        sentry.observeCommit(position(3, 200), source: .pagedTurn)
        sentry.observeCommit(position(3, 300), source: .pagedTurn)

        #expect(recorder.reports.contains { $0.detail.contains("intent=tocJump") })

        // Intent gone: a later undeclared jump is caught again.
        sentry.observeCommit(position(20, 0), source: .pagedTurn)
        #expect(recorder.anomalies.contains { $0.detail.contains("guard=G2") })
    }

    @Test("a deliberate page turn ends an outstanding jump episode")
    func stepClearsIntent() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn)
        sentry.declareIntent(.tocJump, target: position(50, 0))
        // The user turned a page instead; the jump is no longer pending.
        sentry.expectGesture(from: position(3, 0), before: nil, after: position(3, 100))
        sentry.observeCommit(position(3, 100), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)

        sentry.observeCommit(position(50, 0), source: .pagedTurn)
        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies.first?.detail.contains("guard=G2") == true)
    }

    @Test("an intent with no named target vouches for exactly one landing")
    func untargetedIntentCoversOneCommit() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn)
        sentry.declareIntent(.userSeek, target: nil)
        sentry.observeCommit(position(30, 0), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)

        sentry.observeCommit(position(60, 0), source: .pagedTurn)
        #expect(recorder.anomalies.count == 1)
    }
}
