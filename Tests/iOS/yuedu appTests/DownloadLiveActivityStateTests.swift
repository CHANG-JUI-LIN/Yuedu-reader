import Foundation
import Testing
@testable import yuedu_app

/// The aggregation behind the Dynamic Island. One activity covers the whole queue, because the
/// downloader runs several books at once (`maximumConcurrentBooks`) and the system surfaces only
/// one activity — so "the book being downloaded" is not a single value and the compact
/// presentation has to be a total.
@Suite("Download Live Activity state")
struct DownloadLiveActivityStateTests {

    @Test("no downloads means no activity")
    func idleShelfProducesNoState() {
        #expect(DownloadLiveActivityController.contentState(for: []) == nil)
        #expect(DownloadLiveActivityController.contentState(for: [makeBook(title: "閒書")]) == nil)
    }

    @Test("chapters are totalled across every downloading book")
    func totalsAcrossBooks() throws {
        let first = makeBook(title: "書甲", requested: 0...9, completed: [0, 1, 2])
        let second = makeBook(title: "書乙", requested: 0...4, completed: [0])

        let state = try #require(DownloadLiveActivityController.contentState(for: [first, second]))

        #expect(state.books.count == 2)
        #expect(state.totalChapters == 15)
        #expect(state.completedChapters == 4)
        #expect(abs(state.fraction - 4.0 / 15.0) < 0.0001)
    }

    @Test("a paused queue reports paused only when every book is paused")
    func pausedRequiresUnanimity() throws {
        let running = makeBook(title: "書甲", requested: 0...9, completed: [0])
        var pausedBook = makeBook(title: "書乙", requested: 0...4, completed: [0])
        pausedBook.offlineDownloadTask?.setPaused(true)
        pausedBook.offlineDownloadState = .paused

        let mixed = try #require(DownloadLiveActivityController.contentState(for: [running, pausedBook]))
        #expect(!mixed.isPaused)

        let allPaused = try #require(DownloadLiveActivityController.contentState(for: [pausedBook]))
        #expect(allPaused.isPaused)
    }

    @Test("a book with nothing requested is left out rather than dividing by zero")
    func emptyTaskIsExcluded() {
        var book = makeBook(title: "書丙")
        book.offlineDownloadTask = BookOfflineDownloadTask(requestedIndices: [])
        book.offlineDownloadState = .downloading

        #expect(DownloadLiveActivityController.contentState(for: [book]) == nil)
    }

    @Test("the featured book is one that is actually moving")
    func featuredBookIsNotPaused() throws {
        // The presentation shows one cover and one title and folds the rest, so a paused book
        // must not occupy that slot while another is downloading.
        var paused = makeBook(title: "書甲", requested: 0...9, completed: [0])
        paused.offlineDownloadTask?.setPaused(true)
        paused.offlineDownloadState = .paused
        let running = makeBook(title: "書乙", requested: 0...4, completed: [0])

        let state = try #require(DownloadLiveActivityController.contentState(for: [paused, running]))

        #expect(state.books.first?.title == "書乙")
        #expect(state.books.count == 2)
    }

    @Test("shelf order breaks the tie so the featured book does not jump around")
    func featuredOrderIsStable() throws {
        let first = makeBook(title: "書甲", requested: 0...9, completed: [0])
        let second = makeBook(title: "書乙", requested: 0...9, completed: [0, 1, 2, 3])

        let state = try #require(DownloadLiveActivityController.contentState(for: [first, second]))

        // Not "whichever is furthest along" — that would reshuffle as chapters land.
        #expect(state.books.map(\.title) == ["書甲", "書乙"])
    }

    @Test("cover file names are carried through, never image bytes")
    func coverFilenamesArePlumbedThrough() throws {
        let book = makeBook(title: "書甲", requested: 0...9, completed: [0])
        let filename = "\(book.id.uuidString).jpg"

        let state = try #require(
            DownloadLiveActivityController.contentState(
                for: [book],
                coverFilenames: [book.id.uuidString: filename]
            )
        )

        #expect(state.books.first?.coverFilename == filename)
    }

    @Test("a book with no published cover simply has none")
    func missingCoverIsNil() throws {
        let book = makeBook(title: "書甲", requested: 0...9, completed: [0])
        let state = try #require(DownloadLiveActivityController.contentState(for: [book]))
        #expect(state.books.first?.coverFilename == nil)
    }

    @Test("pause and resume changes bypass progress throttling")
    func pauseChangesRequireImmediateUpdate() throws {
        let runningBook = makeBook(title: "書甲", requested: 0...9, completed: [0])
        var pausedBook = runningBook
        pausedBook.offlineDownloadTask?.setPaused(true)
        pausedBook.offlineDownloadState = .paused

        let running = try #require(
            DownloadLiveActivityController.contentState(for: [runningBook])
        )
        let paused = try #require(
            DownloadLiveActivityController.contentState(for: [pausedBook])
        )

        #expect(
            DownloadLiveActivityController.requiresImmediateUpdate(
                from: running,
                to: paused
            )
        )
        #expect(
            DownloadLiveActivityController.requiresImmediateUpdate(
                from: paused,
                to: running
            )
        )
    }

    @Test("chapter progress remains eligible for coalescing")
    func chapterProgressDoesNotRequireImmediateUpdate() throws {
        let previousBook = makeBook(title: "書甲", requested: 0...9, completed: [0])
        var nextBook = previousBook
        nextBook.offlineDownloadTask?.markCompleted(1)
        let previous = try #require(
            DownloadLiveActivityController.contentState(for: [previousBook])
        )
        let next = try #require(
            DownloadLiveActivityController.contentState(for: [nextBook])
        )

        #expect(
            !DownloadLiveActivityController.requiresImmediateUpdate(
                from: previous,
                to: next
            )
        )
    }

    @Test("changing the featured download bypasses progress throttling")
    func featuredBookChangeRequiresImmediateUpdate() throws {
        let first = makeBook(title: "書甲", requested: 0...9, completed: [0])
        let second = makeBook(title: "書乙", requested: 0...9, completed: [0])
        let previous = try #require(
            DownloadLiveActivityController.contentState(for: [first, second])
        )
        let next = try #require(
            DownloadLiveActivityController.contentState(for: [second])
        )

        #expect(
            DownloadLiveActivityController.requiresImmediateUpdate(
                from: previous,
                to: next
            )
        )
    }

    // MARK: - Support

    private func makeBook(
        title: String,
        requested: ClosedRange<Int>? = nil,
        completed: [Int] = []
    ) -> ReadingBook {
        var book = ReadingBook(
            title: title,
            author: "作者",
            source: "https://example.com",
            contentFilename: "\(UUID().uuidString).txt"
        )
        guard let requested else { return book }
        var task = BookOfflineDownloadTask(requestedIndices: Set(requested))
        for index in completed { task.markCompleted(index) }
        book.offlineDownloadTask = task
        book.offlineDownloadState = .downloading
        return book
    }
}
