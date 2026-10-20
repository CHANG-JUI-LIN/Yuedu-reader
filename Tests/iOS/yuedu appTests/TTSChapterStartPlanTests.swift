import Foundation
import Testing
@testable import yuedu_app

/// Starting narration used to treat "the paged engine has no text for this chapter" as
/// "this chapter has no text": it logged 聽書取不到章節文字而停止 and returned, so tapping
/// 聽書 did nothing at all.
///
/// Scroll mode made that the ordinary case. Its chapters are laid out by the scroll engine
/// only, and since the scroll-mode restore stopped preloading the restored chapter into the
/// paged engine, even the chapter the book opened on was unmeasured there — while narration
/// only ever reads the paged engine. An unmeasured chapter has to be laid out and then
/// started, not abandoned.
@Suite("TTS chapter start plan")
@MainActor
struct TTSChapterStartPlanTests {

    private func plan(
        hasNarration: Bool,
        isLaidOut: Bool,
        canLayOut: Bool = true,
        layoutAwaited: Bool = false
    ) -> ReaderView.TTSChapterStartPlan {
        ReaderView.ttsChapterStartPlan(
            hasNarration: hasNarration,
            isLaidOut: isLaidOut,
            canLayOut: canLayOut,
            layoutAwaited: layoutAwaited
        )
    }

    /// The reported case: TXT in scroll mode, open (or scroll) to any chapter, tap 聽書.
    @Test("a chapter the paged engine has not laid out is laid out, not abandoned")
    func unmeasuredChapterAwaitsLayout() {
        #expect(plan(hasNarration: false, isLaidOut: false) == .awaitLayout)
    }

    @Test("text in hand speaks immediately")
    func narrationInHandSpeaks() {
        #expect(plan(hasNarration: true, isLaidOut: true) == .speak)
    }

    /// The layout pass is the only thing waited on, once. A chapter that is still empty
    /// after its own layout finished is empty for real, and must reach the anomaly instead
    /// of requesting the same layout again.
    @Test("a chapter still empty after its own layout pass stops instead of asking again")
    func emptyAfterAwaitedLayoutStops() {
        #expect(plan(hasNarration: false, isLaidOut: false, layoutAwaited: true) == .unavailable)
        #expect(plan(hasNarration: false, isLaidOut: true, layoutAwaited: true) == .unavailable)
    }

    @Test("a laid-out chapter with no text is genuinely empty")
    func laidOutButEmptyStops() {
        #expect(plan(hasNarration: false, isLaidOut: true) == .unavailable)
    }

    /// An online chapter whose content has not been fetched cannot be laid out yet; that
    /// case keeps its existing fetch request rather than waiting on a layout that cannot run.
    @Test("a chapter the engine cannot lay out yet is not waited on")
    func notLayOutableStops() {
        #expect(plan(hasNarration: false, isLaidOut: false, canLayOut: false) == .unavailable)
    }
}
