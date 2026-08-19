import Foundation
import Testing
@testable import yuedu_app

@MainActor
@Suite("ReaderViewModel chapter state", .serialized)
struct ReaderViewModelChapterStateTests {

    @Test("idle transitions to loading then ready")
    func idleLoadingReady() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "ready")

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        #expect(!viewModel.isChapterContentAvailable(at: 0))
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        await fetcher.resolvePending(chapterIndex: 0, with: .success(readyPackage))
        await waitForState(.ready, in: viewModel, chapterIndex: 0)
        #expect(viewModel.isChapterContentAvailable(at: 0))
    }

    @Test("cached chapters become ready without fetching")
    func cachedChapterBecomesReadyImmediately() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        await fetcher.setCached(chapterIndex: 0)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)

        #expect(viewModel.chapterStates[0] == .ready)
        #expect(viewModel.isChapterContentAvailable(at: 0))
        #expect(await fetcher.fetchCount(for: 0) == 0)
    }

    @Test("cached review metadata is inspected without a chapter fetch")
    func cachedReviewMetadataDoesNotFetch() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let package = makePackage(
            bookId: book.id,
            chapterIndex: 0,
            content: "<a href=\"ydreview://r?d=1\">review</a>"
        )
        await fetcher.setCached(chapterIndex: 0, package: package)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(
            book: book,
            chapterIndex: 0,
            priority: .immediate,
            store: nil
        )
        await waitUntil { viewModel.hasParagraphReviews }

        #expect(viewModel.isChapterContentAvailable(at: 0))
        #expect(await fetcher.fetchCount(for: 0) == 0)
    }

    @Test("idle transitions to loading then failed")
    func idleLoadingFailed() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        await fetcher.resolvePending(
            chapterIndex: 0,
            with: .failure(MockChapterFetcher.MockError(message: "network"))
        )
        await waitForFailure("network", in: viewModel, chapterIndex: 0)
        #expect(!viewModel.isChapterContentAvailable(at: 0))
    }

    @Test("empty content keeps the reader on a recoverable failure surface")
    func emptyContentKeepsRecoverableFailureSurface() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueueEmptyContent(chapterIndex: 0)
        await viewModel.ensureChapterReady(
            book: book,
            chapterIndex: 0,
            priority: .immediate,
            store: nil
        )

        let reason = FetchError.emptyContent.localizedDescription
        await waitForFailure(reason, in: viewModel, chapterIndex: 0)

        #expect(!viewModel.isChapterContentAvailable(at: 0))
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: viewModel.isChapterContentAvailable(at: 0),
                loadState: viewModel.chapterState(for: 0)
            ) == .failed(message: reason)
        )
        #expect(await fetcher.fetchCount(for: 0) == 1)
    }

    @Test("network timeout keeps the reader on a recoverable failure surface")
    func timeoutKeepsRecoverableFailureSurface() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueueTimeout(chapterIndex: 0)
        await viewModel.ensureChapterReady(
            book: book,
            chapterIndex: 0,
            priority: .immediate,
            store: nil
        )

        let reason = URLError(.timedOut).localizedDescription
        await waitForFailure(reason, in: viewModel, chapterIndex: 0)

        #expect(!viewModel.isChapterContentAvailable(at: 0))
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: viewModel.isChapterContentAvailable(at: 0),
                loadState: viewModel.chapterState(for: 0)
            ) == .failed(message: reason)
        )
        #expect(await fetcher.fetchCount(for: 0) == 1)
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
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)

        await waitForFailure("empty", in: viewModel, chapterIndex: 0)
    }

    @Test("a cancelled fetch is not reported as a failure")
    func cancelledFetchIsNotAFailure() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueuePending(chapterIndex: 0)
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        // -999 is how a URLSession task or a WKWebView navigation reports being torn down.
        // It used to reach the catch-all and paint 章節載入失敗 over a chapter that fetched
        // fine on the next attempt — the failure users cleared by refreshing.
        await fetcher.resolvePending(chapterIndex: 0, with: .failure(URLError(.cancelled)))
        await waitForState(.cancelled, in: viewModel, chapterIndex: 0)

        #expect(!viewModel.isChapterContentAvailable(at: 0))
        #expect(
            ReaderChapterPresentation.overlayState(
                isContentAvailable: viewModel.isChapterContentAvailable(at: 0),
                loadState: viewModel.chapterState(for: 0)
            ) == .loading
        )
    }

    @Test("a directly thrown CancellationError also lands on cancelled")
    func cancellationErrorLandsOnCancelled() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueuePending(chapterIndex: 0)
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }

        await fetcher.resolvePending(chapterIndex: 0, with: .failure(CancellationError()))
        await waitForState(.cancelled, in: viewModel, chapterIndex: 0)
    }

    @Test("a cancelled chapter re-enters loading when it is requested again")
    func cancelledChapterReEntersLoading() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueuePending(chapterIndex: 0)
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }
        await fetcher.resolvePending(chapterIndex: 0, with: .failure(URLError(.cancelled)))
        await waitForState(.cancelled, in: viewModel, chapterIndex: 0)

        await fetcher.enqueuePending(chapterIndex: 0)
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .jump, store: nil)
        await waitForState(.loading, in: viewModel, chapterIndex: 0)
        // The fetch runs in its own task; count it only once it has actually started.
        await waitUntil { await fetcher.hasPendingRequest(for: 0) }
        #expect(await fetcher.fetchCount(for: 0) == 2)
    }

    @Test("duplicate requests do not start a second fetch")
    func duplicateRequestsDeduplicate() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()

        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

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
        let viewModel = makeViewModel(chapterFetcher: fetcher)

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
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueueFailure(chapterIndex: 0, message: "offline")
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForFailure("offline", in: viewModel, chapterIndex: 0)

        viewModel.resetChapterState(for: 0)

        #expect(viewModel.chapterStates[0] == nil)
        #expect(viewModel.chapterState(for: 0) == .idle)
        #expect(!viewModel.isChapterContentAvailable(at: 0))
    }

    @Test("source switch drops every chapter state")
    func resetAllChapterStatesClearsEverything() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.setCached(chapterIndex: 0)
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        #expect(viewModel.chapterStates[0] == .ready)

        // 換源: this `.ready` describes the source we just left. Carried over, the reader
        // compares it against the new source's (empty) cache and shows 資料不一致.
        viewModel.resetAllChapterStates()

        #expect(viewModel.chapterStates.isEmpty)
        #expect(viewModel.chapterState(for: 0) == .idle)
    }

    @Test("a refetch clears the previous failure before probing the cache")
    func refetchClearsFailureBeforeCacheProbe() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let viewModel = makeViewModel(chapterFetcher: fetcher)

        await fetcher.enqueueFailure(chapterIndex: 0, message: "offline")
        await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        await waitForFailure("offline", in: viewModel, chapterIndex: 0)

        await fetcher.blockNextCacheProbe()
        await fetcher.enqueuePending(chapterIndex: 0)
        let retry = Task { @MainActor in
            await viewModel.ensureChapterReady(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        }

        // The failure overlay renders straight off this state. While the cache probe runs
        // the chapter is being loaded again, so it must not still read as failed.
        await waitForState(.loading, in: viewModel, chapterIndex: 0)

        await fetcher.resumeBlockedCacheProbe()
        await retry.value
    }

    @Test("a tapped source switch publishes its origin and cancels cleanly")
    func pendingSourceSwitchCancels() async throws {
        let viewModel = makeViewModel(chapterFetcher: MockChapterFetcher())
        let origin = makeOrigin()
        let gate = SwitchGate()

        // Stands in for the TOC fetch: the switch is parked here, which is exactly when the
        // sheet used to look frozen and offer no way out.
        viewModel.beginSourceSwitch(to: origin) {
            await gate.wait()
        }
        #expect(viewModel.changeSourcePendingOrigin?.id == origin.id)

        viewModel.cancelPendingSourceSwitch()

        #expect(viewModel.changeSourcePendingOrigin == nil)
        await gate.open()
    }

    @Test("a later success clears an origin's persisted failure flag")
    func originFailureFlagClearsOnSuccess() async throws {
        let viewModel = makeViewModel(chapterFetcher: MockChapterFetcher())
        let bookId = UUID()
        let origin = makeOrigin()
        defer { ChangeSourceCache.shared.clear(for: bookId) }
        let key = ChangeSourceCache.originKey(
            sourceId: origin.sourceId, bookUrl: origin.bookUrl)

        viewModel.markOriginFailed(
            bookId: bookId, sourceId: origin.sourceId, bookUrl: origin.bookUrl)
        #expect(viewModel.changeSourceFailedKeys.contains(key))
        #expect(ChangeSourceCache.shared.entry(for: bookId)?.failedKeys.contains(key) == true)

        viewModel.clearOriginFailure(
            bookId: bookId, sourceId: origin.sourceId, bookUrl: origin.bookUrl)

        // Both copies must go: the persisted one is why a one-off failure used to keep the
        // row badged 載入失敗 across relaunches.
        #expect(!viewModel.changeSourceFailedKeys.contains(key))
        #expect(ChangeSourceCache.shared.entry(for: bookId)?.failedKeys.contains(key) != true)
    }

    @Test("stopping the search clears its loading flag")
    func stopChangeSourceSearchClearsLoading() async throws {
        let viewModel = makeViewModel(chapterFetcher: MockChapterFetcher())

        // A tap stops the fan-out so it stops competing with the TOC fetch the user waits on.
        viewModel.stopChangeSourceSearch()

        #expect(viewModel.changeSourceLoading == false)
    }

    private func makeOrigin() -> BookOrigin {
        BookOrigin(
            sourceId: UUID(),
            sourceName: "Source",
            bookUrl: "https://example.com/book",
            tocUrl: "https://example.com/book/toc",
            coverUrl: "",
            intro: "",
            lastChapter: "Chapter 9",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )
    }

    @Test("jump promotes an in-flight immediate request")
    func jumpPromotesImmediateRequest() async throws {
        let fetcher = MockChapterFetcher()
        let book = makeBook()
        let readyPackage = makePackage(bookId: book.id, chapterIndex: 0, content: "jump")

        await fetcher.enqueuePending(chapterIndex: 0)
        await fetcher.enqueuePending(chapterIndex: 0)
        let viewModel = makeViewModel(chapterFetcher: fetcher)

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
        let viewModel = makeViewModel(chapterFetcher: fetcher)

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

    private func makeViewModel(chapterFetcher: MockChapterFetcher) -> ReaderViewModel {
        ReaderViewModel(
            chapterFetcher: chapterFetcher,
            bookCoordinator: StubOnlineBookCoordinator(),
            bookSourceFetcher: StubBookSourceFetcher()
        )
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

/// Parks a source switch until the test releases it, so the pending state can be observed.
private actor SwitchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
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
        case emptyContent
        case timeout
    }

    private var cachedChapters = Set<Int>()
    private var cachedPackages: [Int: ChapterPackage] = [:]
    private var outcomes: [Int: [Outcome]] = [:]
    private var pendingContinuations: [Int: CheckedContinuation<ChapterPackage, Error>] = [:]
    private var fetchRecords: [Int: [ChapterFetchPriority]] = [:]
    private var cancelRecords: [Int: Int] = [:]
    private var blockCancellation = false
    private var blockedCancelContinuation: CheckedContinuation<Void, Never>?
    private var blockCacheProbe = false
    private var blockedCacheProbeContinuation: CheckedContinuation<Void, Never>?

    func setCached(chapterIndex: Int) {
        cachedChapters.insert(chapterIndex)
    }

    func setCached(chapterIndex: Int, package: ChapterPackage) {
        cachedChapters.insert(chapterIndex)
        cachedPackages[chapterIndex] = package
    }

    func enqueuePending(chapterIndex: Int) {
        outcomes[chapterIndex, default: []].append(.pending)
    }

    func enqueueFailure(chapterIndex: Int, message: String) {
        outcomes[chapterIndex, default: []].append(.failure(MockError(message: message)))
    }

    func enqueueEmptyContent(chapterIndex: Int) {
        outcomes[chapterIndex, default: []].append(.emptyContent)
    }

    func enqueueTimeout(chapterIndex: Int) {
        outcomes[chapterIndex, default: []].append(.timeout)
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

    /// Holds `isChapterCached` open so a test can observe the state the reader renders while
    /// the cache probe is still running.
    func blockNextCacheProbe() {
        blockCacheProbe = true
    }

    func resumeBlockedCacheProbe() {
        blockCacheProbe = false
        blockedCacheProbeContinuation?.resume()
        blockedCacheProbeContinuation = nil
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
        if blockCacheProbe, blockedCacheProbeContinuation == nil {
            await withCheckedContinuation { continuation in
                blockedCacheProbeContinuation = continuation
            }
        }
        return cachedChapters.contains(chapterIndex)
    }

    func cachedChapterPackage(book: ReadingBook, chapterIndex: Int) async -> ChapterPackage? {
        cachedPackages[chapterIndex]
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
        case .emptyContent:
            throw FetchError.emptyContent
        case .timeout:
            throw URLError(.timedOut)
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

private final class StubOnlineBookCoordinator: OnlineBookCoordinating {
    func downloadBook(_ book: ReadingBook, store: BookStore?) {}
    func downloadBook(
        _ book: ReadingBook,
        store: BookStore?,
        startChapterIndex: Int,
        chapterCount: Int?
    ) {}
    func pauseDownload(book: ReadingBook, store: BookStore?) {}
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}

private struct StubBookSourceFetcher: BookSourceFetching {
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "StubBookSourceFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        throw NSError(domain: "StubBookSourceFetcher", code: 2)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}
