import Combine
import Foundation
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapterStates: [Int: ChapterLoadState] = [:]

    // MARK: - Source Change State

    @Published private(set) var changeSourceOrigins: [BookOrigin] = []
    @Published private(set) var changeSourceLoading: Bool = false
    @Published private(set) var changeSourceError: String? = nil
    /// Normalized book-URL keys of origins that failed to switch (TOC fetch threw),
    /// so the 換源 list can flag them. Backed by `ChangeSourceCache`.
    @Published private(set) var changeSourceFailedKeys: Set<String> = []

    private struct InFlightRequest {
        let token: UUID
        let priority: ChapterFetchPriority
        let task: Task<Void, Never>
    }

    private var chapterFetcher: ChapterFetching
    private var bookCoordinator: OnlineBookCoordinating
    private var bookSourceFetcher: BookSourceFetching
    private var inFlightRequests: [Int: InFlightRequest] = [:]
    /// Books already checked for auto manga detection this session (cached-chapter path),
    /// so a genuine text book is not re-probed on every `ensureChapterReady`.
    private var mangaDetectionAttempted: Set<UUID> = []
    /// The current 換源 (source switch) search, so a re-open cancels the previous run.
    private var changeSourceSearchTask: Task<Void, Never>?

    convenience init() {
        self.init(
            chapterFetcher: AppDependencies.live.chapterFetcher,
            bookCoordinator: AppDependencies.live.onlineBookCoordinator,
            bookSourceFetcher: AppDependencies.live.bookSourceFetcher
        )
    }

    init(
        chapterFetcher: ChapterFetching,
        bookCoordinator: OnlineBookCoordinating,
        bookSourceFetcher: BookSourceFetching
    ) {
        self.chapterFetcher = chapterFetcher
        self.bookCoordinator = bookCoordinator
        self.bookSourceFetcher = bookSourceFetcher
    }

    func chapterState(for chapterIndex: Int) -> ChapterLoadState {
        chapterStates[chapterIndex] ?? .idle
    }

    func configure(chapterFetcher: ChapterFetching) {
        self.chapterFetcher = chapterFetcher
    }

    func resetChapterState(for chapterIndex: Int) {
        if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
            existing.task.cancel()
        }
        chapterStates.removeValue(forKey: chapterIndex)
    }

    // MARK: - Chapter Loading

    func ensureChapterReady(
        book: ReadingBook?,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async {
        guard let book, let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            return
        }

        // Volume headers (作品相关 / 第N卷 …) have no fetchable content. Mark ready immediately so
        // the builder renders a divider page instead of spinning forever on an empty fetch.
        if refs[chapterIndex].shouldRenderAsVolumeSeparator {
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            chapterStates[chapterIndex] = .ready
            return
        }

        if await chapterFetcher.isChapterCached(book: book, chapterIndex: chapterIndex) {
            chapterStates[chapterIndex] = .ready
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            detectMangaInCachedChapter(
                book: book, chapterIndex: chapterIndex, priority: priority, store: store)
            return
        }

        if let existing = inFlightRequests[chapterIndex] {
            guard priority == .jump, existing.priority.rawValue < priority.rawValue else {
                return
            }

            existing.task.cancel()
            let token = UUID()
            inFlightRequests[chapterIndex] = InFlightRequest(
                token: token,
                priority: priority,
                task: Task<Void, Never> {}
            )
            chapterStates[chapterIndex] = .loading
            await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            guard inFlightRequests[chapterIndex]?.token == token else {
                return
            }
            let task = startFetchTask(
                book: book,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store,
                token: token
            )
            inFlightRequests[chapterIndex] = InFlightRequest(token: token, priority: priority, task: task)
            return
        }

        chapterStates[chapterIndex] = .loading
        let token = UUID()
        let task = startFetchTask(
            book: book,
            chapterIndex: chapterIndex,
            priority: priority,
            store: store,
            token: token
        )
        inFlightRequests[chapterIndex] = InFlightRequest(token: token, priority: priority, task: task)
    }

    // MARK: - Chapter Cancellation

    /// Cancels all in-flight chapter requests for the given book.
    func cancelAll(for bookId: UUID) async {
        await chapterFetcher.cancelAll(for: bookId)
    }

    // MARK: - Download Actions

    /// Starts or cancels offline download for a book, replacing direct OnlineBookCoordinator.shared calls from the view.
    func handleDownloadAction(
        book: ReadingBook,
        store: BookStore,
        startChapterIndex: Int = 0,
        chapterCount: Int? = nil
    ) {
        switch book.offlineDownloadState {
        case .none, .failed, .paused:
            bookCoordinator.downloadBook(
                book,
                store: store,
                startChapterIndex: startChapterIndex,
                chapterCount: chapterCount
            )
        case .downloading:
            bookCoordinator.pauseDownload(book: book, store: store)
        case .available:
            break  // .available is handled by the view layer via store.clearOnlineDownload
        }
    }

    // MARK: - Neighbour Prefetch

    /// Prefetches chapters around the given center index, replacing direct OnlineBookCoordinator.shared calls from the view.
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore) {
        Task {
            await bookCoordinator.prefetchAround(book: book, center: center, store: store)
        }
    }

    // MARK: - Source Change Search

    /// Searches for alternative book sources with the same title. Results update changeSourceOrigins.
    ///
    /// Honors 網路設定 →「搜索結果快取天數」: unless `forceRefresh` is set, a fresh cached
    /// result for this book is reused instead of re-running the full cross-source search.
    func loadOtherOrigins(
        book: ReadingBook,
        currentSourceId: UUID,
        enabledSources: [BookSource],
        store: BookStore,
        forceRefresh: Bool = false
    ) {
        let bookId = book.id

        // Cache hit: reuse recent results so reopening the sheet is instant.
        if !forceRefresh,
           let cached = ChangeSourceCache.shared.freshEntry(
               for: bookId, days: GlobalSettings.shared.searchCacheDays) {
            changeSourceSearchTask?.cancel()
            changeSourceOrigins = cached.origins
            changeSourceFailedKeys = Set(cached.failedKeys)
            changeSourceLoading = false
            changeSourceError = nil
            return
        }

        changeSourceLoading = true
        changeSourceError = nil
        changeSourceOrigins = []
        // Keep prior failure flags across a re-search so a known-bad source stays marked.
        changeSourceFailedKeys = Set(ChangeSourceCache.shared.entry(for: bookId)?.failedKeys ?? [])
        let bookTitle = book.title
        let bookAuthor = book.author
        let currentBookUrlKey = Self.normalizedURLKey(book.bookInfoURL)
        // Search ALL enabled sources, including the current one. Aggregation sources
        // expose several "channels" for the same book under a single sourceId, and a
        // user may have only that one source installed — filtering by sourceId would
        // then yield zero results. We dedup by book URL instead, so every distinct
        // channel/source is offered (minus the exact origin already being read).
        let sources = enabledSources
        let concurrency = NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency)
        let autoPauseCount = NetworkSearchSettings.effectiveAutoPauseCount(
            configured: GlobalSettings.shared.searchAutoPauseCount,
            sourceCount: sources.count
        )
        let autoPausePolicy = SearchAutoPausePolicy(count: autoPauseCount)

        changeSourceSearchTask?.cancel()
        changeSourceSearchTask = Task { [weak self] in
            guard let self else { return }
            var seenBookUrls = Set<String>()
            let bookSourceFetcher = self.bookSourceFetcher

            // Fan out with a bounded active window. Results are consumed on the
            // MainActor as they stream in, so dedup state stays single-threaded,
            // the list fills progressively, and auto-pause can stop enqueueing
            // untouched sources.
            await withTaskGroup(of: [OnlineBook]?.self) { group in
                var nextSourceIndex = 0
                let activeLimit = min(concurrency, sources.count)

                func enqueueNextSource() {
                    guard nextSourceIndex < sources.count else { return }
                    let source = sources[nextSourceIndex]
                    nextSourceIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await Self.searchSourceWithTimeout(
                            query: bookTitle,
                            source: source,
                            bookSourceFetcher: bookSourceFetcher
                        )
                    }
                }

                for _ in 0..<activeLimit {
                    enqueueNextSource()
                }

                while let list = await group.next() {
                    if Task.isCancelled { break }
                    guard let list else { continue }
                    var shouldPause = false
                    for ob in list {
                        let matched = SearchBook.isLikelySameBook(
                            name: bookTitle, author: bookAuthor,
                            name: ob.name, author: ob.author
                        )
                        guard matched else { continue }
                        // Dedup by book URL so aggregation channels survive; skip the exact
                        // origin already in use and any duplicate URLs across sources.
                        let urlKey = Self.normalizedURLKey(ob.bookUrl)
                        if !urlKey.isEmpty {
                            if urlKey == currentBookUrlKey { continue }
                            guard seenBookUrls.insert(urlKey).inserted else { continue }
                        }
                        self.changeSourceOrigins.append(
                            BookOrigin(
                                sourceId: ob.sourceId,
                                sourceName: ob.sourceName,
                                bookUrl: ob.bookUrl,
                                tocUrl: ob.tocUrl,
                                coverUrl: ob.coverUrl,
                                intro: ob.intro,
                                lastChapter: ob.lastChapter,
                                wordCount: ob.wordCount,
                                kind: ob.kind,
                                runtimeVariables: ob.runtimeVariables
                            )
                        )
                        if autoPausePolicy.shouldPause(
                            exactCount: self.changeSourceOrigins.count,
                            fuzzyCount: 0
                        ) {
                            shouldPause = true
                            break
                        }
                    }
                    if shouldPause {
                        group.cancelAll()
                        break
                    }
                    enqueueNextSource()
                }
            }

            if Task.isCancelled { return }
            self.changeSourceLoading = false
            // Persist results so reopening the sheet is instant (honors 快取天數).
            ChangeSourceCache.shared.store(origins: self.changeSourceOrigins, for: bookId)
        }
    }

    /// Reports an error from a source change operation.
    func reportChangeSourceError(_ message: String?) {
        changeSourceError = message
    }

    /// Flags an origin that failed to switch (its TOC fetch threw), persisting the
    /// flag so it stays marked across reopen/re-search of the same book.
    func markOriginFailed(bookId: UUID, bookUrl: String) {
        let key = ChangeSourceCache.urlKey(bookUrl)
        guard !key.isEmpty else { return }
        changeSourceFailedKeys.insert(key)
        ChangeSourceCache.shared.markFailed(bookUrlKey: key, for: bookId)
    }

    /// Normalized book-URL key for deduping origins (drops fragment, lowercased).
    private static func normalizedURLKey(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "" }
        if var components = URLComponents(string: trimmed) {
            components.fragment = nil
            return (components.string ?? trimmed).lowercased()
        }
        return trimmed.lowercased()
    }

    /// Searches one source with a timeout, off the main actor. Returns nil on error
    /// or timeout so a slow/hung source can't stall the whole 換源 search.
    /// `nonisolated` so concurrent tasks don't serialize back onto the MainActor.
    nonisolated private static func searchSourceWithTimeout(
        query: String,
        source: BookSource,
        bookSourceFetcher: BookSourceFetching,
        seconds: UInt64 = 20
    ) async -> [OnlineBook]? {
        await withTaskGroup(of: [OnlineBook]?.self) { group in
            group.addTask {
                try? await bookSourceFetcher.search(query: query, in: source)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Private

    /// One-shot manga probe for an already-cached chapter: a book that was cached as
    /// text before auto-detection existed still needs to be flipped to the image reader.
    /// Runs at most once per book per session and reuses the cached package (no network).
    private func detectMangaInCachedChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) {
        guard book.isOnline,
              book.contentPipelineKind != .manga,
              let store,
              !mangaDetectionAttempted.contains(book.id)
        else { return }
        mangaDetectionAttempted.insert(book.id)
        Task { [weak self] in
            guard let self else { return }
            guard let package = try? await self.chapterFetcher.fetchChapter(
                book: book, chapterIndex: chapterIndex, priority: priority, store: store),
                  !package.content.isEmpty
            else { return }
            if !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content) {
                store.upgradeToAudioIfDetected(bookId: book.id, content: package.content)
            }
        }
    }

    private func startFetchTask(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?,
        token: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                print("[FetchStateDebug] ch=\(chapterIndex) fetchChapter START priority=\(priority)")
                let package = try await self.chapterFetcher.fetchChapter(
                    book: book,
                    chapterIndex: chapterIndex,
                    priority: priority,
                    store: store
                )
                guard !Task.isCancelled else {
                    print("[FetchStateDebug] ch=\(chapterIndex) fetchChapter CANCELLED after return")
                    return
                }
                let result: ChapterLoadState = package.state == .cached && !package.content.isEmpty
                    ? .ready
                    : .failed(reason: package.failureReason ?? "empty")
                print("[FetchStateDebug] ch=\(chapterIndex) fetchChapter DONE pkgState=\(package.state) contentLen=\(package.content.count) → result=\(result)")
                if case .ready = result, let store {
                    // Aggregation sources serve manga under a text (type-0) source; once the
                    // first chapter comes back as an image list, flip the book to the manga
                    // reader. `BookReaderView` swaps reactively.
                    #if DEBUG
                    if book.isOnline {
                        let imgs = MangaChapterParser.imageURLs(from: package.content)
                        let head = package.content.prefix(600)
                            .replacingOccurrences(of: "\n", with: "⏎")
                        print("[MangaDetect] ch=\(chapterIndex) len=\(package.content.count) imgURLs=\(imgs.count) looksManga=\(MangaChapterParser.looksLikeMangaContent(package.content)) looksAudio=\(DirectChapterAudioResolver.looksLikeAudioContent(package.content)) audioURL=\(DirectChapterAudioResolver.request(from: package.content)?.url?.absoluteString ?? "nil") head=\(head)")
                    }
                    #endif
                    if !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content) {
                        store.upgradeToAudioIfDetected(bookId: book.id, content: package.content)
                    }
                }
                self.finishFetch(chapterIndex: chapterIndex, token: token, result: result)
            } catch is CancellationError {
                print("[FetchStateDebug] ch=\(chapterIndex) fetchChapter CancellationError")
                self.clearInFlight(chapterIndex: chapterIndex, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                print("[FetchStateDebug] ch=\(chapterIndex) fetchChapter ERROR \(error)")
                self.finishFetch(
                    chapterIndex: chapterIndex,
                    token: token,
                    result: .failed(reason: error.localizedDescription)
                )
            }
        }
    }

    private func finishFetch(
        chapterIndex: Int,
        token: UUID,
        result: ChapterLoadState
    ) {
        guard inFlightRequests[chapterIndex]?.token == token else {
            print("[FetchStateDebug] ch=\(chapterIndex) finishFetch SKIPPED (token mismatch)")
            return
        }
        print("[FetchStateDebug] ch=\(chapterIndex) finishFetch SET state=\(result)")
        inFlightRequests.removeValue(forKey: chapterIndex)
        chapterStates[chapterIndex] = result
    }

    private func clearInFlight(chapterIndex: Int, token: UUID) {
        guard inFlightRequests[chapterIndex]?.token == token else { return }
        inFlightRequests.removeValue(forKey: chapterIndex)
        if chapterStates[chapterIndex] == .loading {
            chapterStates[chapterIndex] = .idle
        }
    }
}
