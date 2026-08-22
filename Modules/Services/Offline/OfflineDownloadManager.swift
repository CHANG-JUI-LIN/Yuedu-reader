import Foundation

protocol OfflineDownloadManaging: Sendable {
    func start(
        book: ReadingBook,
        selection: OfflineChapterSelection,
        store: BookStore
    ) async
    func pause(bookId: UUID, store: BookStore) async
    func resume(book: ReadingBook, store: BookStore) async
    func retryFailed(book: ReadingBook, store: BookStore) async
    func skipFailed(bookId: UUID, store: BookStore) async
    func remove(bookId: UUID, store: BookStore) async throws
    func reconcileInterruptedDownloads(store: BookStore) async
}

private enum OfflineDownloadManagerError: LocalizedError {
    case invalidPackage

    var errorDescription: String? {
        "Fetched chapter did not produce a complete durable package"
    }
}

actor OfflineDownloadManager: OfflineDownloadManaging {
    private struct WaitingBook {
        var book: ReadingBook
        var store: BookStore
        var enqueuedAt: TimeInterval
    }

    private let chapterFetcher: any ChapterFetching
    private let chapterStore: any OfflineChapterStoring
    private let maximumConcurrentBooks: Int
    /// Seconds to wait before the first automatic retry; later attempts scale with the
    /// attempt number. Injectable so tests exercise the retry path without real waiting.
    private let retryBackoff: TimeInterval
    private var bookJobs: [UUID: Task<Void, Never>] = [:]
    private var activeChapterIndices: [UUID: Int] = [:]
    private var waitingBooks: [WaitingBook] = []
    private var isReconciling = false
    /// The store each running book is downloading into, so the background-expiry handler can
    /// pause them without being handed one.
    private var runningStores: [UUID: BookStore] = [:]
    private var hasInstalledBackgroundExpiryHandler = false
    /// Attempts spent per chapter, `bookId → chapterIndex → count`. In memory only, like
    /// Legado's `errorDownloadMap`: a relaunch is a fresh set of attempts.
    private var chapterAttempts: [UUID: [Int: Int]] = [:]

    /// Legado gives each chapter three tries before recording a failure
    /// (`CacheBook.onPostError`). Paid sources, sources behind a login, and chapters that
    /// also fetch 段評 all take longer and are the ones that lose to a single blip; failing
    /// them on the first error is what made a download report failures it could have avoided.
    private static let maximumChapterAttempts = 3

    /// Whether spending another attempt on this failure could plausibly change the outcome.
    /// A volume header or a malformed chapter URL fails identically every time, so retrying
    /// only spends requests against a source that may already be throttling us.
    private static func isRetryable(_ category: OfflineChapterFailure.Category) -> Bool {
        switch category {
        case .invalidChapter, .canceled:
            return false
        case .network, .parsing, .emptyContent, .textWrite,
             .imageDownload, .imageValidation, .unknown:
            return true
        }
    }

    init(
        chapterFetcher: any ChapterFetching,
        chapterStore: any OfflineChapterStoring = OfflineChapterStore(),
        maximumConcurrentBooks: Int = 2,
        retryBackoff: TimeInterval = 1.0
    ) {
        self.chapterFetcher = chapterFetcher
        self.chapterStore = chapterStore
        self.maximumConcurrentBooks = max(1, maximumConcurrentBooks)
        self.retryBackoff = max(0, retryBackoff)
    }

    func start(
        book: ReadingBook,
        selection: OfflineChapterSelection,
        store: BookStore
    ) async {
        let libraryBook = await MainActor.run {
            store.ensureOnlineBookForDownload(book)
        }
        guard let refs = libraryBook.onlineChapters, !refs.isEmpty else { return }

        let validIndices = Set(selection.indices.filter { refs.indices.contains($0) })
        let volumeIndices = Set(validIndices.filter { refs[$0].shouldRenderAsVolumeSeparator })
        let requested = validIndices.subtracting(volumeIndices)
        guard !requested.isEmpty else { return }

        await MainActor.run {
            var task = store.books.first(where: { $0.id == libraryBook.id })?.offlineDownloadTask
                ?? BookOfflineDownloadTask(requestedIndices: [])
            task.mergeRequestedIndices(requested)
            task.setPaused(false)
            store.replaceOfflineDownloadTask(
                bookId: libraryBook.id,
                task: task,
                isRunning: true
            )
        }
        enqueue(libraryBook, store: store)
    }

    func pause(bookId: UUID, store: BookStore) async {
        waitingBooks.removeAll { $0.book.id == bookId }
        let activeChapterIndex = activeChapterIndices[bookId]
        let job = bookJobs[bookId]
        job?.cancel()
        if let activeChapterIndex {
            await chapterFetcher.cancelChapter(bookId: bookId, chapterIndex: activeChapterIndex)
        }
        await job?.value
        await MainActor.run {
            guard var task = store.books.first(where: { $0.id == bookId })?.offlineDownloadTask else {
                return
            }
            task.setPaused(true)
            store.replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: false)
        }
    }

    func resume(book: ReadingBook, store: BookStore) async {
        let shouldResume = await MainActor.run { () -> Bool in
            guard var task = store.books.first(where: { $0.id == book.id })?.offlineDownloadTask else {
                return false
            }
            task.setPaused(false)
            store.replaceOfflineDownloadTask(bookId: book.id, task: task, isRunning: true)
            return !task.pendingIndices.isEmpty
        }
        guard shouldResume else { return }
        enqueue(book, store: store)
    }

    func retryFailed(book: ReadingBook, store: BookStore) async {
        // An explicit 重試 is a fresh verdict: the user may have logged into the source or
        // bought the chapter since, so the automatic attempts already spent must not count
        // against this round.
        chapterAttempts.removeValue(forKey: book.id)
        let shouldRetry = await MainActor.run { () -> Bool in
            guard var task = store.books.first(where: { $0.id == book.id })?.offlineDownloadTask,
                  !task.failedChapters.isEmpty else {
                return false
            }
            task.retryFailedIndices()
            store.replaceOfflineDownloadTask(bookId: book.id, task: task, isRunning: true)
            return true
        }
        guard shouldRetry else { return }
        enqueue(book, store: store)
    }

    func skipFailed(bookId: UUID, store: BookStore) async {
        guard bookJobs[bookId] == nil,
              !waitingBooks.contains(where: { $0.book.id == bookId }) else {
            return
        }
        await MainActor.run {
            guard var task = store.books.first(where: { $0.id == bookId })?.offlineDownloadTask,
                  task.pendingIndices.isEmpty,
                  !task.failedChapters.isEmpty else {
                return
            }
            task.removeRequestedIndices(Set(task.failedChapters.keys))
            store.replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: false)
        }
    }

    func remove(bookId: UUID, store: BookStore) async throws {
        chapterAttempts.removeValue(forKey: bookId)
        waitingBooks.removeAll { $0.book.id == bookId }
        let job = bookJobs[bookId]
        job?.cancel()
        // Every fetch for this book, not just the one index `activeChapterIndices` happens to
        // hold: the reader is usually open on the same book and has its own requests in
        // flight, and any of them landing after the directory is deleted writes into a book
        // the user just cleared.
        await chapterFetcher.cancelAll(for: bookId, includingDownloads: true)
        await job?.value
        // Cancelling a download cancels many chapters at once. Each one that surfaced as a
        // failure counted against the book's quarantine budget, which only ever reset on a
        // success — so removing a download could quarantine the book permanently.
        await chapterFetcher.resetFailureBudget(for: bookId)
        await MainActor.run { store.clearAutomaticQuarantine(bookId: bookId) }
        try await store.clearOnlineDownload(
            bookId: bookId,
            offlineChapterStore: chapterStore
        )
        // A reconcile pass suspended inside its validation loop can queue this book
        // again while the awaits above run. Its job would exit immediately (the task
        // is gone), but dropping the entry keeps the queue honest for the books
        // still waiting behind it.
        waitingBooks.removeAll { $0.book.id == bookId }
    }

    func reconcileInterruptedDownloads(store: BookStore) async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        let books = await MainActor.run {
            store.books.filter { $0.isOnline && $0.offlineDownloadTask != nil }
        }
        for book in books {
            guard let refs = book.onlineChapters else { continue }
            // A reconcile validates; it never destroys. With an empty table of contents every
            // requested index falls outside `refs.indices`, so the merge below would drop them
            // all, leave an empty task, and `derivedState` would answer `.none` — the book
            // silently reverts to "never downloaded", flushed immediately because the targets
            // changed. Nothing here can tell "this book lost its chapters" apart from "the TOC
            // fetch failed", so it must not act on either. `OnlineTOCCommitPolicy` keeps an
            // empty list from being committed in the first place; this is the second lock.
            guard !refs.isEmpty else {
                AppLogger.cache("⟐ reconcile skipped, empty TOC", context: [
                    "bookId": book.id.uuidString,
                    "title": book.title,
                ])
                continue
            }
            let requestedIndices = await MainActor.run {
                store.books.first(where: { $0.id == book.id })?.offlineDownloadTask?.requestedIndices
            }
            guard let requestedIndices else { continue }

            var droppedIndices = Set(requestedIndices.filter { !refs.indices.contains($0) })
            var verifiedIndices: Set<Int> = []
            var missingIndices: Set<Int> = []

            for index in requestedIndices.subtracting(droppedIndices).sorted() {
                let ref = refs[index]
                if ref.shouldRenderAsVolumeSeparator {
                    droppedIndices.insert(index)
                    continue
                }
                let validation = await SourcePerfTrace.spanAsync(
                    "offline.validation",
                    book.title
                ) {
                    await chapterStore.validationState(
                        bookId: book.id,
                        chapterIndex: index,
                        expectedSourceURL: ref.url,
                        expectedTOCTitle: ref.title,
                        requiresManga: book.contentPipelineKind == .manga,
                        hasBookSource: book.bookSourceId != nil
                    )
                }
                if validation == .complete {
                    verifiedIndices.insert(index)
                } else {
                    missingIndices.insert(index)
                }
            }

            // Validating a long book is one await per chapter, and 移除下載 can
            // land in the middle of them (下載管理 even starts this pass on the
            // same screen as the 移除 button). Merging into the task that is live
            // *now* is what keeps a removal removed: writing the pre-validation
            // snapshot back resurrected the task, and because removal had just
            // deleted the artifacts it still listed as completed, the follow-up
            // enqueue restarted the whole download.
            // The loop above is done mutating the three index sets, so capture them by
            // value — reaching into this actor's mutable locals from the @MainActor
            // closure is an error under the Swift 6 language mode.
            let merged = await MainActor.run {
                [droppedIndices, verifiedIndices, missingIndices] () -> BookOfflineDownloadTask? in
                guard var task = store.books
                    .first(where: { $0.id == book.id })?.offlineDownloadTask
                else { return nil }
                task.removeRequestedIndices(droppedIndices)
                for index in verifiedIndices where task.requestedIndices.contains(index) {
                    task.markCompleted(index)
                }
                for index in missingIndices where task.completedIndices.contains(index) {
                    task.markPending(index)
                }
                store.replaceOfflineDownloadTask(bookId: book.id, task: task, isRunning: false)
                return task
            }
            guard let merged, !merged.isPaused, !merged.pendingIndices.isEmpty else { continue }
            enqueue(book, store: store)
        }
    }

    func waitUntilIdle() async {
        while let job = bookJobs.values.first {
            await job.value
        }
    }

    private func enqueue(_ book: ReadingBook, store: BookStore) {
        guard bookJobs[book.id] == nil else { return }
        if let index = waitingBooks.firstIndex(where: { $0.book.id == book.id }) {
            waitingBooks[index].book = book
            waitingBooks[index].store = store
            return
        }
        waitingBooks.append(WaitingBook(
            book: book,
            store: store,
            enqueuedAt: ProcessInfo.processInfo.systemUptime
        ))
        startWaitingBooksIfPossible()
    }

    private func startWaitingBooksIfPossible() {
        while bookJobs.count < maximumConcurrentBooks, !waitingBooks.isEmpty {
            let waiting = waitingBooks.removeFirst()
            SourcePerfTrace.record(
                "offline.queueWait",
                waiting.book.title,
                since: waiting.enqueuedAt
            )
            let bookId = waiting.book.id
            runningStores[bookId] = waiting.store
            bookJobs[bookId] = Task { [weak self] in
                await self?.beginBackgroundAssertion()
                await self?.runBook(waiting.book, store: waiting.store)
                await MainActor.run { OfflineDownloadBackgroundTask.shared.release() }
            }
        }
    }

    private func runBook(_ originalBook: ReadingBook, store: BookStore) async {
        defer { finishBook(bookId: originalBook.id) }

        while !Task.isCancelled {
            let snapshot = await MainActor.run { () -> (ReadingBook, BookOfflineDownloadTask)? in
                guard
                    let book = store.books.first(where: { $0.id == originalBook.id }),
                    let task = book.offlineDownloadTask
                else { return nil }
                return (book, task)
            }
            guard let (book, task) = snapshot, !task.isPaused else { return }
            guard let index = task.pendingIndices.sorted().first else {
                await MainActor.run {
                    guard let finalTask = store.books
                        .first(where: { $0.id == book.id })?.offlineDownloadTask else { return }
                    store.replaceOfflineDownloadTask(
                        bookId: book.id,
                        task: finalTask,
                        isRunning: false
                    )
                }
                return
            }
            guard let refs = book.onlineChapters, refs.indices.contains(index) else {
                await removeInvalidIndex(index, bookId: book.id, store: store)
                continue
            }
            let ref = refs[index]
            if ref.shouldRenderAsVolumeSeparator {
                await removeInvalidIndex(index, bookId: book.id, store: store)
                continue
            }

            activeChapterIndices[book.id] = index
            do {
                let validation = await SourcePerfTrace.spanAsync(
                    "offline.validation",
                    book.title
                ) {
                    await chapterStore.validationState(
                        bookId: book.id,
                        chapterIndex: index,
                        expectedSourceURL: ref.url,
                        expectedTOCTitle: ref.title,
                        requiresManga: book.contentPipelineKind == .manga,
                        hasBookSource: book.bookSourceId != nil
                    )
                }
                if validation != .complete {
                    let package = try await SourcePerfTrace.spanAsync(
                        "offline.textCommit",
                        book.title
                    ) {
                        try await chapterFetcher.fetchChapter(
                            book: book,
                            chapterIndex: index,
                            priority: .download,
                            store: store
                        )
                    }
                    guard package.state == .cached,
                          !package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw OfflineDownloadManagerError.invalidPackage
                    }
                    if book.contentPipelineKind == .manga {
                        let request = await mangaRequest(
                            book: book,
                            chapterIndex: index,
                            ref: ref,
                            package: package
                        )
                        try await SourcePerfTrace.spanAsync(
                            "offline.imageCommit",
                            book.title
                        ) {
                            try await chapterStore.persistMangaImages(request)
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                let finalValidation = await chapterStore.validationState(
                    bookId: book.id,
                    chapterIndex: index,
                    expectedSourceURL: ref.url,
                    expectedTOCTitle: ref.title,
                    requiresManga: book.contentPipelineKind == .manga,
                    hasBookSource: book.bookSourceId != nil
                )
                guard finalValidation == .complete else {
                    throw OfflineDownloadManagerError.invalidPackage
                }
                await markCompleted(index, bookId: book.id, store: store)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let category = failureCategory(for: error)
                let attempts = (chapterAttempts[book.id]?[index] ?? 0) + 1
                chapterAttempts[book.id, default: [:]][index] = attempts

                if attempts < Self.maximumChapterAttempts, Self.isRetryable(category) {
                    // The index is still in `pendingIndices` (only `markFailed` removes it),
                    // so the next loop pass picks it straight back up. Back off first —
                    // retrying a source the instant it failed is how a transient error
                    // becomes three of them. Legado waits a flat second here; the wait grows
                    // with the attempt so a struggling source gets more room each round.
                    AppLogger.parse("⟐ offline chapter retry", context: [
                        "index": index,
                        "attempt": attempts,
                        "category": category.rawValue,
                    ])
                    ChapterRetryLog.record(
                        .offlineDownload,
                        chapter: index,
                        bookId: book.id.uuidString,
                        attempt: attempts,
                        detail: "category=\(category.rawValue)"
                    )
                    activeChapterIndices.removeValue(forKey: book.id)
                    let backoff = retryBackoff * Double(attempts)
                    if backoff > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    }
                    continue
                }

                await markFailed(
                    index,
                    title: ref.title,
                    error: error,
                    bookId: book.id,
                    store: store
                )
                chapterAttempts[book.id]?.removeValue(forKey: index)
            }
            activeChapterIndices.removeValue(forKey: book.id)
        }
    }

    private func markCompleted(_ index: Int, bookId: UUID, store: BookStore) async {
        chapterAttempts[bookId]?.removeValue(forKey: index)
        await MainActor.run {
            guard var task = store.books.first(where: { $0.id == bookId })?.offlineDownloadTask else {
                return
            }
            task.markCompleted(index)
            store.replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: true)
        }
        ReaderTelemetry.shared.log("book_download_progress", attributes: [
            "bookId": bookId.uuidString,
            "chapterIndex": "\(index)",
            "result": "success",
        ])
    }

    private func markFailed(
        _ index: Int,
        title: String,
        error: Error,
        bookId: UUID,
        store: BookStore
    ) async {
        let category = failureCategory(for: error)
        let failure = OfflineChapterFailure(
            chapterIndex: index,
            title: title,
            category: category,
            message: error.localizedDescription,
            occurredAt: Date()
        )
        await MainActor.run {
            guard var task = store.books.first(where: { $0.id == bookId })?.offlineDownloadTask else {
                return
            }
            task.markFailed(failure)
            store.replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: true)
        }
        AppLogger.error("Offline chapter download failed [\(category.rawValue)] index=\(index)", error: error)
        ReaderTelemetry.shared.log("book_download_progress", attributes: [
            "bookId": bookId.uuidString,
            "chapterIndex": "\(index)",
            "result": "failed",
            "category": category.rawValue,
        ])
    }

    private func removeInvalidIndex(_ index: Int, bookId: UUID, store: BookStore) async {
        await MainActor.run {
            guard var task = store.books.first(where: { $0.id == bookId })?.offlineDownloadTask else {
                return
            }
            task.removeRequestedIndices([index])
            store.replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: true)
        }
    }

    private func finishBook(bookId: UUID) {
        activeChapterIndices.removeValue(forKey: bookId)
        chapterAttempts.removeValue(forKey: bookId)
        bookJobs.removeValue(forKey: bookId)
        runningStores.removeValue(forKey: bookId)
        startWaitingBooksIfPossible()
    }

    /// Takes the shared background assertion for this job, installing the expiry handler the
    /// first time. See `OfflineDownloadBackgroundTask` for what the assertion does and does
    /// not buy — it is a clean stop, not background downloading.
    private func beginBackgroundAssertion() async {
        let needsHandler = !hasInstalledBackgroundExpiryHandler
        hasInstalledBackgroundExpiryHandler = true
        await MainActor.run { [weak self] in
            if needsHandler {
                OfflineDownloadBackgroundTask.shared.onExpiration = {
                    Task { await self?.pauseForBackgroundExpiry() }
                }
            }
            OfflineDownloadBackgroundTask.shared.acquire()
        }
    }

    /// iOS is about to reclaim the assertion. Stop where we are and write it down: a paused
    /// task is a state the next foreground resumes from, whereas being frozen mid-chapter
    /// leaves the reconcile to reconstruct one.
    private func pauseForBackgroundExpiry() async {
        let running = runningStores
        guard !running.isEmpty else { return }
        AppLogger.cache("⟐ pausing offline downloads for background expiry", context: [
            "books": running.count,
        ])
        for (bookId, store) in running {
            await pause(bookId: bookId, store: store)
        }
    }

    private func failureCategory(for error: Error) -> OfflineChapterFailure.Category {
        if error is ChapterCacheWriteError { return .textWrite }
        if let error = error as? OfflineChapterStoreError {
            switch error {
            case .noImages:
                return .emptyContent
            case .invalidImageURL, .imageResponse, .emptyImage, .imageWrite:
                return .imageDownload
            case .invalidImageData, .manifestWrite, .manifestValidation, .commit:
                return .imageValidation
            case .remove:
                return .unknown
            }
        }
        if let error = error as? FetchError {
            switch error {
            case .emptyContent:
                return .emptyContent
            case .invalidURL, .noSearchURL, .volumeSeparator:
                return .invalidChapter
            case .httpError, .cloudflareChallengeRequired, .sourceAPIError:
                return .network
            case .encodingError:
                return .parsing
            }
        }
        if error is OfflineDownloadManagerError { return .emptyContent }
        if error is URLError { return .network }
        if error is CancellationError { return .canceled }
        return .unknown
    }

    private func mangaRequest(
        book: ReadingBook,
        chapterIndex: Int,
        ref: OnlineChapterRef,
        package: ChapterPackage
    ) async -> OfflineMangaChapterRequest {
        let defaultHeaders = await MainActor.run { () -> [String: String] in
            let source = book.bookSourceId.flatMap { id in
                BookSourceStore.shared.sources.first { $0.id == id }
            }
            return BookCoverLoader.headers(
                sourceBaseURL: source?.bookSourceUrl,
                sourceHeaders: source?.parsedHeaders ?? [:]
            )
        }
        let images = MangaChapterParser.parsedImages(from: package.content).map { image in
            OfflineMangaImageRequest(
                sourceURL: image.url,
                headers: defaultHeaders.merging(image.headers) { _, perImage in perImage }
            )
        }
        return OfflineMangaChapterRequest(
            bookId: book.id,
            chapterIndex: chapterIndex,
            chapterSourceURL: package.sourceURL ?? ref.url,
            tocTitle: package.tocTitle ?? ref.title,
            images: images
        )
    }

}
