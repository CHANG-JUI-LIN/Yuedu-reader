import Foundation
import Testing
@testable import yuedu_app

@MainActor
@Suite("ReaderViewModel chapter state")
struct ReaderViewModelChapterStateTests {

    @Test("idle transitions to loading then ready")
    func idleLoadingReady() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "ready")

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        await fetcher.resolvePending(chapterIndex: 0, with: .success(readyPackage))
        await waitForState(.ready, in: viewModel, chapterIndex: 0)
    }

    @Test("cached chapters become ready without fetching")
    func cachedChapterBecomesReadyImmediately() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        await fetcher.setCached(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)

        #expect(viewModel.chapterStates[0] == .ready)
        #expect(await fetcher.fetchCount(for: 0) == 0)
    }

    @Test("idle transitions to loading then failed")
    func idleLoadingFailed() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        await fetcher.resolvePending(
            chapterIndex: 0,
            with: .failure(MockChapterFetcher.MockError(message: "network"))
        )
        await waitForFailure("network", in: viewModel, chapterIndex: 0)
    }

    @Test("failed packages map to failed chapter state")
    func failedPackageMapsToFailureState() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let failedPackage = ChapterPackage(
            bookId: book.id,
            chapterIndex: 0,
            sourceURL: "https://example.com/1",
            tocTitle: "Chapter 1",
            canonicalTitle: "Chapter 1",
            content: "",
            contentChecksum: "",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .failed,
            failureReason: "empty"
        )

        await fetcher.enqueuePackage(chapterIndex: 0, package: failedPackage)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)

        await waitForFailure("empty", in: viewModel, chapterIndex: 0)
    }

    @Test("duplicate requests do not start a second fetch")
    func duplicateRequestsDeduplicate() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)

        #expect(await fetcher.fetchCount(for: 0) == 1)
    }

    @Test("retry after failure re-enters loading")
    func retryAfterFailureReturnsToLoading() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "retry")

        await fetcher.enqueueFailure(chapterIndex: 0, message: "offline")
        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForFailure("offline", in: viewModel, chapterIndex: 0)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }
        #expect(await fetcher.fetchCount(for: 0) == 2)

        await fetcher.resolvePending(chapterIndex: 0, with: .success(readyPackage))
        await waitForState(.ready, in: viewModel, chapterIndex: 0)
    }

    @Test("reset chapter state clears stale failures")
    func resetChapterStateClearsStaleFailures() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await fetcher.enqueueFailure(chapterIndex: 0, message: "offline")
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForFailure("offline", in: viewModel, chapterIndex: 0)

        viewModel.resetChapterState(for: 0)

        #expect(viewModel.chapterStates[0] == nil)
        #expect(viewModel.chapterState(for: 0) == .idle)
    }

    @Test("jump promotes an in-flight immediate request")
    func jumpPromotesImmediateRequest() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "jump")

        await fetcher.enqueuePending(chapterIndex: 0)
        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: nil)

        await waitUntil {
            let fetchCount = await fetcher.fetchCount(for: 0)
            let cancelCount = await fetcher.cancelCount(for: 0)
            return fetchCount == 2 && cancelCount == 1
        }
        #expect(await fetcher.priorities(for: 0) == [.immediate, .jump])

        await fetcher.resolvePending(chapterIndex: 0, with: .success(readyPackage))
        await waitForState(.ready, in: viewModel, chapterIndex: 0)
    }

    @Test("repeated jump promotion stays deduped during cancellation")
    func repeatedJumpPromotionStaysDeduped() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "promoted")

        await fetcher.enqueuePending(chapterIndex: 0)
        await fetcher.enqueuePending(chapterIndex: 0)
        await fetcher.blockNextCancellation()
        let viewModel = ReaderViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        let firstJump = Task { @MainActor in
            await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: nil)
        }
        await waitUntil { await fetcher.cancelCount(for: 0) == 1 }

        let secondJump = Task { @MainActor in
            await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: nil)
        }

        await fetcher.resumeBlockedCancellation()
        await firstJump.value
        await secondJump.value

        #expect(await fetcher.fetchCount(for: 0) == 2)

        await fetcher.resolvePending(chapterIndex: 0, with: .success(readyPackage))
        await waitForState(.ready, in: viewModel, chapterIndex: 0)
    }

    private func makeBook() -> ReadingBook {
        var book = ReadingBook(title: "Book", author: "Author", source: "https://example.com", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "Chapter 1", url: "https://example.com/1")
        ]
        return book
    }

    private func makePackage(bookId: UUID, chapterIndex: Int, content: String) -> ChapterPackage {
        ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: "https://example.com/\(chapterIndex + 1)",
            tocTitle: "Chapter \(chapterIndex + 1)",
            canonicalTitle: "Chapter \(chapterIndex + 1)",
            content: content,
            contentChecksum: "checksum",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
    }

    private func waitForState(
        _ expected: ChapterLoadState,
        in viewModel: ReaderViewModel,
        chapterIndex: Int
    ) async {
        await waitUntil {
            viewModel.chapterStates[chapterIndex] == expected
        }
    }

    private func waitForFailure(
        _ message: String,
        in viewModel: ReaderViewModel,
        chapterIndex: Int
    ) async {
        await waitUntil {
            viewModel.chapterStates[chapterIndex] == .failed(reason: message)
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let start = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - start > .nanoseconds(timeoutNanoseconds) {
                Issue.record("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }
}

actor MockChapterFetcher: ChapterFetching {
    struct MockError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Outcome {
        case pending
        case success(ChapterPackage)
        case failure(MockError)
    }

    private var cachedChapters = Set<Int>()
    private var outcomes: [Int: [Outcome]] = [:]
    private var pendingContinuations: [Int: CheckedContinuation<ChapterPackage, Error>] = [:]
    private var fetchRecords: [Int: [ChapterFetchPriority]] = [:]
    private var cancelRecords: [Int: Int] = [:]
    private var blockCancellation = false
    private var blockedCancelContinuation: CheckedContinuation<Void, Never>?

    func setCached(chapterIndex: Int) {
        cachedChapters.insert(chapterIndex)
    }

    func enqueuePending(chapterIndex: Int) {
        outcomes[chapterIndex, default: []].append(.pending)
    }

    func enqueueFailure(chapterIndex: Int, message: String) {
        outcomes[chapterIndex, default: []].append(.failure(MockError(message: message)))
    }

    func enqueuePackage(chapterIndex: Int, package: ChapterPackage) {
        outcomes[chapterIndex, default: []].append(.success(package))
    }

    func blockNextCancellation() {
        blockCancellation = true
    }

    func resumeBlockedCancellation() {
        blockCancellation = false
        blockedCancelContinuation?.resume()
        blockedCancelContinuation = nil
    }

    func fetchCount(for chapterIndex: Int) -> Int {
        fetchRecords[chapterIndex]?.count ?? 0
    }

    func cancelCount(for chapterIndex: Int) -> Int {
        cancelRecords[chapterIndex, default: 0]
    }

    func priorities(for chapterIndex: Int) -> [ChapterFetchPriority] {
        fetchRecords[chapterIndex] ?? []
    }

    func hasPendingRequest(for chapterIndex: Int) -> Bool {
        pendingContinuations[chapterIndex] != nil
    }

    func resolvePending(chapterIndex: Int, with result: Result<ChapterPackage, Error>) {
        pendingContinuations.removeValue(forKey: chapterIndex)?.resume(with: result)
    }

    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool {
        cachedChapters.contains(chapterIndex)
    }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        fetchRecords[chapterIndex, default: []].append(priority)
        let outcome = outcomes[chapterIndex, default: []].isEmpty ? Outcome.failure(MockError(message: "missing outcome")) : outcomes[chapterIndex]!.removeFirst()

        switch outcome {
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuations[chapterIndex] = continuation
            }
        case .success(let package):
            return package
        case .failure(let error):
            throw error
        }
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {
        cancelRecords[chapterIndex, default: 0] += 1
        if blockCancellation, blockedCancelContinuation == nil {
            await withCheckedContinuation { continuation in
                blockedCancelContinuation = continuation
            }
        }
        pendingContinuations.removeValue(forKey: chapterIndex)?.resume(throwing: CancellationError())
    }

    func cancelAll(for bookId: UUID) async {}
}
