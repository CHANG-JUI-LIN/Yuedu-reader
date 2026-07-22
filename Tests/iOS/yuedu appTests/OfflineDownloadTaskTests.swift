import Foundation
import Testing
@testable import yuedu_app

@Suite("Offline download task")
struct OfflineDownloadTaskTests {
    @Test("merging a range preserves completed and failed indices")
    func mergePreservesProgress() {
        let failure = OfflineChapterFailure(
            chapterIndex: 2,
            title: "Chapter 3",
            category: .network,
            message: "offline",
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        var task = BookOfflineDownloadTask(requestedIndices: Set(0...4))
        task.markCompleted(0)
        task.markFailed(failure)

        task.mergeRequestedIndices(Set(3...7))

        #expect(task.requestedIndices == Set(0...7))
        #expect(task.completedIndices == Set([0]))
        #expect(task.failedChapters[2] == failure)
        #expect(task.pendingIndices == Set([1, 3, 4, 5, 6, 7]))
    }

    @Test("legacy range decodes as requested and pending disk-unknown chapters")
    func legacyMigration() throws {
        let json = #"{"startChapterIndex":2,"endChapterIndex":5,"completedChapterCount":3,"startedAt":0,"updatedAt":0}"#
        let task = try JSONDecoder().decode(BookOfflineDownloadTask.self, from: Data(json.utf8))

        #expect(task.schemaVersion == BookOfflineDownloadTask.currentSchemaVersion)
        #expect(task.requestedIndices == Set(2...5))
        #expect(task.completedIndices.isEmpty)
        #expect(task.pendingIndices == Set(2...5))
    }

    @Test("derived state distinguishes partial and available")
    func derivedState() {
        var task = BookOfflineDownloadTask(requestedIndices: [0, 1])
        task.markCompleted(0)
        task.markFailed(.init(
            chapterIndex: 1,
            title: "Two",
            category: .emptyContent,
            message: "empty",
            occurredAt: .distantPast
        ))
        #expect(task.derivedState(isRunning: false) == .partial)

        task.retryFailedIndices()
        task.markCompleted(1)
        #expect(task.derivedState(isRunning: false) == .available)
    }

    @Test("clamping removes indices outside the current table of contents")
    func clampToTableOfContents() throws {
        var task = BookOfflineDownloadTask(requestedIndices: [0, 2, 9])
        task.markCompleted(0)
        task.markFailed(.init(
            chapterIndex: 9,
            title: "Removed",
            category: .invalidChapter,
            message: "removed",
            occurredAt: .distantPast
        ))

        let clamped = try #require(task.clamped(to: 3))

        #expect(clamped.requestedIndices == Set([0, 2]))
        #expect(clamped.completedIndices == Set([0]))
        #expect(clamped.pendingIndices == Set([2]))
        #expect(clamped.failedChapters.isEmpty)
    }
}
