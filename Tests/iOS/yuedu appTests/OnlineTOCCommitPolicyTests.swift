import Foundation
import Testing
@testable import yuedu_app

/// A table of contents that came back empty is a failed request, not a book with no
/// chapters. Committing one emptied `onlineChapters`, and the reconcile that followed read
/// "every chapter disappeared" and deleted every cached file the book had — which is how a
/// download survived being backgrounded only to come back as a book that had never been
/// downloaded.
@Suite("Online TOC commit policy")
struct OnlineTOCCommitPolicyTests {

    @Test("an empty table of contents is never committed")
    func emptyTableOfContentsIsRejected() {
        #expect(OnlineTOCCommitPolicy.decide(refreshedCount: 0) == .rejectEmpty)
    }

    @Test("a non-empty table of contents commits, however short")
    func nonEmptyTableOfContentsCommits() {
        // Short is not the same as empty: a genuinely shortened book must still be able to
        // shrink. What protects the downloaded bytes there is the disposition below, not a
        // refusal to commit.
        #expect(OnlineTOCCommitPolicy.decide(refreshedCount: 1) == .commit)
        #expect(OnlineTOCCommitPolicy.decide(refreshedCount: 3000) == .commit)
    }

    @Test("only deletion is conditional; both dispositions are distinct")
    func dispositionsAreDistinct() {
        #expect(OfflineContentDisposition.preserveContent != .deleteMismatched)
    }
}

/// A whole book failing is a different fact from a chapter failing, and only the count of
/// distinct failures carries it. Before this, "retry" refetched one chapter against the same
/// stale URL forever, which is why 移除下載 could leave a book unreadable until 換源.
@Suite("Stale TOC suspicion")
struct StaleTOCSuspicionTests {

    @Test("a lone failure is about the chapter, not the table of contents")
    func singleFailureDoesNotAccuseTheTOC() {
        #expect(
            StaleTOCSuspicion.decide(distinctFailedChapters: 1, alreadyRevalidated: false)
                == .keepWaiting
        )
    }

    @Test("enough distinct failures accuse the table of contents")
    func enoughFailuresRevalidate() {
        #expect(
            StaleTOCSuspicion.decide(
                distinctFailedChapters: AppConfig.staleTOCSuspicionThreshold,
                alreadyRevalidated: false
            ) == .revalidateTableOfContents
        )
    }

    @Test("the suspicion threshold fires before the quarantine threshold")
    func revalidationGetsItsChanceBeforeQuarantine() {
        // Otherwise the book is quarantined for exactly the failures a fresh TOC would fix.
        #expect(AppConfig.staleTOCSuspicionThreshold < AppConfig.chapterFetchQuarantineThreshold)
    }

    @Test("revalidation happens at most once, however many more chapters fail")
    func revalidationIsOneShot() {
        // A freshly fetched list that still fails is telling the truth. Looping here is the
        // retry avalanche this codebase keeps having to delete.
        #expect(
            StaleTOCSuspicion.decide(distinctFailedChapters: 500, alreadyRevalidated: true)
                == .keepWaiting
        )
    }
}
