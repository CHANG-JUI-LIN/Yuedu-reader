import Foundation
import Testing
@testable import yuedu_app

/// `ChapterFetchManager.shared` used to build itself inside `MainActor.assumeIsolated`, on the
/// claim that the main actor always touched it first. `AppDependencies.live` never touched it
/// at all, so the first touch came from `OnlineChapterContentService.payload` on a global-executor
/// worker and the app died in `_dispatch_assert_queue_fail` (Crashlytics f71d7b80 / 196f3f10,
/// 3.0.1 (146), AI 問答 on an online book).
@Suite(.serialized)
struct ChapterFetchManagerSharedTests {
    /// Must be the first touch of `.shared` in its process to go red on the old code: run this
    /// suite on its own (`-only-testing:'yuedu appTests/ChapterFetchManagerSharedTests'`).
    @Test func firstTouchOffTheMainActorDoesNotTrap() async {
        let onMain = await Task.detached { Self.touchSharedManager() }.value
        #expect(onMain == false)
    }

    /// Synchronous so `Thread.isMainThread` is allowed; called from a detached task.
    private static func touchSharedManager() -> Bool {
        _ = ChapterFetchManager.shared
        return Thread.isMainThread
    }

    /// One manager owns in-flight dedup, priorities, generation tokens and quarantine counts:
    /// the reader's coordinator and every `.shared` caller (TTS, AI, video, browser) share it.
    @MainActor
    @Test func appDependenciesUseTheSharedManager() throws {
        let coordinator = try #require(AppDependencies.live.onlineBookCoordinator as? OnlineBookCoordinator)
        #expect(coordinator.chapterFetchManager === ChapterFetchManager.shared)
        #expect(coordinator.bookSourceFetcher === BookSourceFetcher.shared)
    }
}
