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
    private var bookJobs: [UUID: Task<Void, Never>] = [:]
    private var activeChapterIndices: [UUID: Int] = [:]
    private var waitingBooks: [WaitingBook] = []
    private var isReconciling = false

    init(
        chapterFetcher: any ChapterFetching,
        chapterStore: any OfflineChapterStoring = OfflineChapterStore(),
        maximumConcurrentBooks: Int = 2
    ) {
        self.chapterFetcher = chapterFetcher
        self.chapterStore = chapterStore
        self.maximumConcurrentBooks = max(1, maximumConcurrentBooks)
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

    func remove(bookId: UUID, store: BookStore) async throws {
        waitingBooks.removeAll { $0.book.id == bookId }
        let job = bookJobs[bookId]
        job?.cancel()
        if let chapterIndex = activeChapterIndices[bookId] {
            await chapterFetcher.cancelChapter(bookId: bookId, chapterIndex: chapterIndex)
        }
        await job?.value
        try await store.clearOnlineDownload(
            bookId: bookId,
            offlineChapterStore: chapterStore
        )
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
            var task = await MainActor.run {
                store.books.first(where: { $0.id == book.id })?.offlineDownloadTask
            } ?? BookOfflineDownloadTask(requestedIndices: [])
            let invalidIndices = Set(task.requestedIndices.filter { !refs.indices.contains($0) })
            task.removeRequestedIndices(invalidIndices)

            for index in task.requestedIndices.sorted() {
                let ref = refs[index]
                if ref.shouldRenderAsVolumeSeparator {
                    task.removeRequestedIndices([index])
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
                        requiresManga: book.contentPipelineKind == .manga
                    )
                }
                if validation == .complete {
                    task.markCompleted(index)
                } else if task.completedIndices.contains(index) {
                    task.markPending(index)
                }
            }

            await MainActor.run {
                store.replaceOfflineDownloadTask(bookId: book.id, task: task, isRunning: false)
            }
            if !task.isPaused && !task.pendingIndices.isEmpty {
                enqueue(book, store: store)
            }
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
            bookJobs[bookId] = Task { [weak self] in
                await self?.runBook(waiting.book, store: waiting.store)
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
                        requiresManga: book.contentPipelineKind == .manga
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
                    requiresManga: book.contentPipelineKind == .manga
                )
                guard finalValidation == .complete else {
                    throw OfflineDownloadManagerError.invalidPackage
                }
                await markCompleted(index, bookId: book.id, store: store)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await markFailed(
                    index,
                    title: ref.title,
                    error: error,
                    bookId: book.id,
                    store: store
                )
            }
            activeChapterIndices.removeValue(forKey: book.id)
        }
    }

    private func markCompleted(_ index: Int, bookId: UUID, store: BookStore) async {
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
        bookJobs.removeValue(forKey: bookId)
        startWaitingBooksIfPossible()
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
            case .httpError, .cloudflareChallengeRequired:
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
