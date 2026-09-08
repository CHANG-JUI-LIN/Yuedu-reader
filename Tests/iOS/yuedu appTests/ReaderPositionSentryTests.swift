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

    // MARK: - A1: every move is accounted for
    //
    // The guards below this line all grew out of *reported symptoms*, and each carries a
    // threshold chosen to avoid false positives on the input that prompted it: G2 needs two
    // whole chapters, G3 needs two consecutive no-op swipes, S1 allows 120 characters. The
    // consequence is a hole none of them can see into — a move of one chapter, one page, or
    // half a paragraph that nobody asked for.
    //
    // A1 is the invariant those thresholds were standing in for: a commit is accounted for
    // when an intent declared it, an expectation predicted it, or the reader's own finger
    // made it. Otherwise it is recorded — **at any distance**. It stays a notice until the
    // logs say how often it fires; the point is that the threshold gets deleted from
    // evidence rather than re-guessed.

    private var unaccounted: (ReaderPositionSentry.Report) -> Bool {
        { $0.detail.contains("guard=A1") }
    }

    @Test("a move the reader made themselves is accounted for")
    func readerDrivenCommitIsAccounted() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .scrollSettle, readerDriven: true)
        sentry.observeCommit(position(3, 4000), source: .scrollSettle, readerDriven: true)
        #expect(!recorder.reports.contains(where: unaccounted))
    }

    /// The hole G2 leaves: one chapter is not "two or more", so this was silent.
    @Test("an unexplained one-chapter move is recorded")
    func unexplainedSingleChapterMoveIsRecorded() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn, readerDriven: true)
        sentry.observeCommit(position(4, 0), source: .pagedTurn, readerDriven: false)

        #expect(recorder.reports.contains(where: unaccounted))
        // Still not an anomaly — the threshold stands until there are numbers — but it is
        // no longer invisible, which is the whole point.
        #expect(recorder.anomalies.isEmpty)
    }

    /// The hole every guard leaves: a move inside one chapter.
    @Test("an unexplained move inside a chapter is recorded with its distance")
    func unexplainedWithinChapterMoveIsRecorded() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 100), source: .scrollSettle, readerDriven: true)
        sentry.observeCommit(position(3, 2600), source: .scrollSettle, readerDriven: false)

        let report = try! #require(recorder.reports.first(where: unaccounted))
        #expect(report.detail.contains("charDelta=2500"))
        #expect(report.severity == .notice)
    }

    /// Distance is not the test — being unaccounted for is. A one-character move nobody
    /// asked for is still nobody asking for it.
    @Test("even a tiny unexplained move is recorded")
    func tinyUnexplainedMoveIsRecorded() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 100), source: .scrollSettle, readerDriven: true)
        sentry.observeCommit(position(3, 101), source: .scrollSettle, readerDriven: false)
        #expect(recorder.reports.contains(where: unaccounted))
    }

    @Test("a declared jump accounts for a move the reader did not make")
    func declaredIntentAccountsForMove() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn, readerDriven: true)
        sentry.declareIntent(.tocJump, target: position(9, 0))
        sentry.observeCommit(position(9, 0), source: .pagedTurn, readerDriven: false)
        #expect(!recorder.reports.contains(where: unaccounted))
    }

    /// A page turn that landed where the walker said accounts for itself through G1 and
    /// must not also be reported as unaccounted for.
    @Test("an expected page turn is not also called unaccounted")
    func expectedTurnIsNotUnaccounted() {
        let (sentry, recorder) = makeSentry()
        sentry.observeCommit(position(3, 0), source: .pagedTurn, readerDriven: true)
        sentry.expectGesture(from: position(3, 0), before: nil, after: position(3, 200))
        sentry.observeCommit(position(3, 200), source: .pagedTurn, readerDriven: false)
        #expect(!recorder.reports.contains(where: unaccounted))
    }

    // MARK: - S1/S2: scroll mode
    //
    // None of G1–G3 can say anything about scrolling: G1 and G3 need an expectation only a
    // page turn creates, and G2 only fires two whole chapters out. A jump *within* a
    // chapter — the thing scrolling actually suffers from — was invisible to all three.

    @Test("a structural change that leaves the reader in place is silent")
    func scrollRestoreInPlaceIsClean() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: position(4, 900), cause: .chunkInsertion
        )
        #expect(recorder.anomalies.isEmpty)
    }

    /// The restore converts a character offset to a y offset and the check converts it
    /// back by hit-testing; landing mid-line costs a few dozen characters either way.
    @Test("the geometry round trip is allowed to be inexact")
    func scrollRestoreToleratesRoundTripError() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: position(4, 940), cause: .chunkInsertion
        )
        #expect(recorder.anomalies.isEmpty)
    }

    /// The reported symptom: background, return, and the reader is somewhere else.
    @Test("coming back from the background somewhere else is an anomaly")
    func foregroundResumeThatMovesIsAnomalous() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: position(4, 3200), cause: .foregroundResume
        )
        #expect(recorder.anomalies.count == 1)
        let detail = recorder.anomalies[0].detail
        #expect(detail.contains("guard=S1"))
        #expect(detail.contains("cause=foregroundResume"))
        // The displacement has to be in the report; "it moved" without how far is not
        // actionable, and the tolerance is a first cut that these numbers will calibrate.
        #expect(detail.contains("charDelta=2300"))
    }

    /// A chapter arriving must not move the reader — that is the whole reason the restore
    /// re-applies the position instead of compensating for the content that moved.
    @Test("a chapter arriving must not move the reader")
    func chunkInsertionThatMovesIsAnomalous() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: position(5, 12), cause: .chunkInsertion
        )
        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies[0].detail.contains("crossedChapter=4 → 5"))
    }

    /// Crossing a chapter is a jump however small the offsets look — the numbers are not
    /// comparable across chapters, so distance cannot be the test.
    @Test("a small offset in another chapter is still a jump")
    func crossingChaptersIgnoresOffsetDistance() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 100), landed: position(3, 100), cause: .reload
        )
        #expect(recorder.anomalies.count == 1)
    }

    /// The same escape hatch page turns get: a declared navigation explains any distance.
    @Test("a declared jump explains a scroll move")
    func declaredIntentExplainsScrollMove() {
        let (sentry, recorder) = makeSentry()
        sentry.declareIntent(.tocJump, target: position(9, 0))
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: position(9, 40), cause: .reload
        )
        #expect(recorder.anomalies.isEmpty)
    }

    /// A restore that cannot be verified is recorded but not reported: not knowing where
    /// the reader is differs from knowing they are in the wrong place.
    @Test("an unresolvable landing is not called an anomaly")
    func unresolvedLandingIsNotAnomalous() {
        let (sentry, recorder) = makeSentry()
        sentry.observeScrollGeometryChange(
            expected: position(4, 900), landed: nil, cause: .chunkInsertion
        )
        #expect(recorder.anomalies.isEmpty)
    }

    @Test("chapters in reading order are silent")
    func chunkOrderInOrderIsClean() {
        let (sentry, recorder) = makeSentry()
        sentry.observeChunkOrder([256, 256, 257, 257, 258], cause: .chunkInsertion)
        #expect(recorder.anomalies.isEmpty)
    }

    /// The real ordering defect from the device log: 258's text sat physically above
    /// 257's, so scrolling down from 256 arrived in 258 and only then 257. Nothing
    /// "jumped" — the book itself was out of order — so it needs its own guard.
    @Test("a chapter laid out above an earlier one is an anomaly")
    func chunkOrderRegressionIsAnomalous() {
        let (sentry, recorder) = makeSentry()
        sentry.observeChunkOrder([256, 258, 257, 259], cause: .chunkInsertion)
        #expect(recorder.anomalies.count == 1)
        let detail = recorder.anomalies[0].detail
        #expect(detail.contains("guard=S2"))
        #expect(detail.contains("firstBreakAt=1"))
        #expect(detail.contains("[256, 258, 257, 259]"))
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

    /// An abandoned swipe never reaches `observeCommit` — UIKit reports it with
    /// `completed == false`, which cancels the expectation. So a *completed* gesture
    /// landing back on its start is the reported symptom, not a snap-back.
    @Test("one completed swipe that does not move is noted, not escalated")
    func singleNoOpTurnIsQuiet() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
        sentry.observeCommit(start, source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    /// "翻過去有翻頁動畫但還是同一個頁面, 必須重進才顯示正常" — the shape the first
    /// version of this guard explicitly allowed, so it was the one thing it could
    /// never catch.
    @Test("repeated completed swipes that do not move are an anomaly")
    func repeatedNoOpTurnsEscalate() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        for _ in 0..<2 {
            sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
            sentry.observeCommit(start, source: .pagedTurn)
        }
        #expect(recorder.anomalies.count == 1)
        #expect(recorder.anomalies.first?.detail.contains("guard=G3") == true)
        #expect(recorder.anomalies.first?.detail.contains("consecutiveNoOpTurns=2") == true)
    }

    /// One anomaly per run: somebody hitting this swipes many times before giving up.
    @Test("a run of no-op turns reports once")
    func noOpRunReportsOnce() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        for _ in 0..<6 {
            sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
            sentry.observeCommit(start, source: .pagedTurn)
        }
        #expect(recorder.anomalies.count == 1)
    }

    @Test("a turn that moves clears the no-op run")
    func movingClearsTheRun() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
        sentry.observeCommit(start, source: .pagedTurn)
        // It moved.
        sentry.expectGesture(from: start, before: position(3, 0), after: position(3, 200))
        sentry.observeCommit(position(3, 200), source: .pagedTurn)
        // Back to a single no-op — not yet a run.
        sentry.expectGesture(from: position(3, 200), before: start, after: position(3, 400))
        sentry.observeCommit(position(3, 200), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    /// Re-placing the reader on the position it already shows is exactly what a chapter
    /// layout landing does, so a programmatic transition is exempt.
    @Test("a programmatic transition may legitimately not move")
    func programmaticNoMoveIsClean() {
        let (sentry, recorder) = makeSentry()
        let start = position(3, 100)
        for _ in 0..<4 {
            sentry.expectGesture(
                from: start, before: position(3, 0), after: position(3, 200), isProgrammatic: true
            )
            sentry.observeCommit(start, source: .pagedTurn)
        }
        #expect(recorder.anomalies.isEmpty)
    }

    /// `chapterEnd` is the `.max` sentinel: the walker knows the step crosses into that
    /// chapter but not where, because it is not paginated yet. Every backward turn out
    /// of a chapter's first page produced this, and every one was reported as an
    /// anomaly by the first version.
    @Test("the chapter-end sentinel matches any offset in that chapter")
    func chapterEndSentinelResolves() {
        let (sentry, recorder) = makeSentry()
        let start = position(90, 0)
        sentry.expectGesture(
            from: start,
            before: CoreTextReadingPosition.chapterEnd(89),
            after: position(90, 316)
        )
        sentry.observeCommit(position(89, 4396), source: .pagedTurn)
        #expect(recorder.anomalies.isEmpty)
    }

    /// With neither neighbour known there is nothing to check against, so the landing
    /// is unverifiable rather than wrong.
    @Test("a landing with no known neighbour is not judged")
    func unverifiableLandingIsNotAnomaly() {
        let (sentry, recorder) = makeSentry()
        sentry.expectGesture(from: position(90, 0), before: nil, after: nil)
        sentry.observeCommit(position(89, 4396), source: .pagedTurn)
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
