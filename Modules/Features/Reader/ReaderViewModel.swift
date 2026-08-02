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
    /// Normalized source-qualified keys of origins that failed to switch (TOC fetch threw),
    /// so the 換源 list can flag them. Backed by `ChangeSourceCache`.
    @Published private(set) var changeSourceFailedKeys: Set<String> = []
    /// Non-nil while a tapped source is being switched to. The sheet renders a cancellable
    /// "正在載入目錄…" over the row instead of looking frozen — Legado shows a `WaitDialog`
    /// on the same event, and its cancel listener aborts the fetch.
    @Published private(set) var changeSourcePendingOrigin: BookOrigin?

    private struct InFlightRequest {
        let token: UUID
        let priority: ChapterFetchPriority
        let task: Task<Void, Never>
    }

    private var chapterFetcher: ChapterFetching
    private var bookCoordinator: OnlineBookCoordinating
    private var bookSourceFetcher: BookSourceFetching
    private var offlineDownloadManager: (any OfflineDownloadManaging)?
    private var inFlightRequests: [Int: InFlightRequest] = [:]
    /// Books already checked for auto manga detection this session (cached-chapter path),
    /// so a genuine text book is not re-probed on every `ensureChapterReady`.
    private var mangaDetectionAttempted: Set<UUID> = []
    /// The current 換源 (source switch) search, so a re-open cancels the previous run.
    private var changeSourceSearchTask: Task<Void, Never>?
    /// The switch the user just tapped, while its TOC is being prepared. Drives the sheet's
    /// cancellable loading state (Legado's `WaitDialog`), and holding the task is what makes
    /// cancelling possible at all.
    private var changeSourceSwitchTask: Task<Void, Never>?
    /// Background TOC warm-up feeding `searchTOCCache` (see `warmSearchTOCCacheIfEnabled`).
    private var tocWarmTask: Task<Void, Never>?
    /// TOCs captured during the search fan-out when 搜索時載入目錄 is on — Legado's `tocMap`.
    /// A tap that hits this switches with no network round trip at all.
    private var searchTOCCache: [String: TOCPackage] = [:]
    /// Total chapters held in `searchTOCCache`. Legado caps the same map at 30 000 chapters
    /// so a few long 萬章 novels can't pin the whole TOC set in memory.
    private var searchTOCChapterCount = 0
    private static let searchTOCChapterLimit = 30_000

    convenience init() {
        self.init(
            chapterFetcher: AppDependencies.live.chapterFetcher,
            bookCoordinator: AppDependencies.live.onlineBookCoordinator,
            bookSourceFetcher: AppDependencies.live.bookSourceFetcher,
            offlineDownloadManager: AppDependencies.live.offlineDownloadManager
        )
    }

    init(
        chapterFetcher: ChapterFetching,
        bookCoordinator: OnlineBookCoordinating,
        bookSourceFetcher: BookSourceFetching,
        offlineDownloadManager: (any OfflineDownloadManaging)? = nil
    ) {
        self.chapterFetcher = chapterFetcher
        self.bookCoordinator = bookCoordinator
        self.bookSourceFetcher = bookSourceFetcher
        self.offlineDownloadManager = offlineDownloadManager
    }

    func chapterState(for chapterIndex: Int) -> ChapterLoadState {
        chapterStates[chapterIndex] ?? .idle
    }

    func configure(
        chapterFetcher: ChapterFetching,
        offlineDownloadManager: any OfflineDownloadManaging
    ) {
        self.chapterFetcher = chapterFetcher
        self.offlineDownloadManager = offlineDownloadManager
    }

    func resetChapterState(for chapterIndex: Int) {
        if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
            existing.task.cancel()
        }
        chapterStates.removeValue(forKey: chapterIndex)
    }

    /// Drops every chapter's load state. Required on 換源, where the states describe the
    /// *previous* source's chapters while `book.onlineChapters` — and therefore every cache
    /// lookup the reader makes — has already been replaced. Keeping them made
    /// `ReaderChapterPresentation.overlayState` compare a stale `.ready` against the new
    /// source's (necessarily empty) cache and render the 資料不一致 failure overlay on
    /// every source switch.
    func resetAllChapterStates() {
        for (_, request) in inFlightRequests {
            request.task.cancel()
        }
        inFlightRequests.removeAll()
        chapterStates.removeAll()
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

        // A previous failure is about to be re-evaluated. The cache probe below is an actor
        // hop plus metadata/artifact reads and a checksum, and the reader renders the failure
        // overlay straight off this state — leaving `.failed` in place paints "章節載入失敗"
        // over a chapter that is actively being loaded again.
        if case .failed = chapterStates[chapterIndex] {
            chapterStates[chapterIndex] = .loading
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

    /// Delegates download selection, pause, resume, and retry to the single offline queue.
    func handleDownloadAction(
        book: ReadingBook,
        store: BookStore,
        startChapterIndex: Int = 0,
        chapterCount: Int? = nil
    ) {
        guard let offlineDownloadManager else { return }
        switch book.offlineDownloadState {
        case .none, .available, .partial:
            guard let refs = book.onlineChapters, !refs.isEmpty else { return }
            let start = min(max(startChapterIndex, 0), refs.count - 1)
            let count = max(1, chapterCount ?? (refs.count - start))
            let end = min(refs.count - 1, start + count - 1)
            Task {
                await offlineDownloadManager.start(
                    book: book,
                    selection: .range(start...end),
                    store: store
                )
            }
        case .failed:
            Task { await offlineDownloadManager.retryFailed(book: book, store: store) }
        case .paused:
            Task { await offlineDownloadManager.resume(book: book, store: store) }
        case .downloading:
            Task { await offlineDownloadManager.pause(bookId: book.id, store: store) }
        }
    }

    func resumeOfflineDownload(book: ReadingBook, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.resume(book: book, store: store) }
    }

    func retryFailedOfflineDownload(book: ReadingBook, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.retryFailed(book: book, store: store) }
    }

    func skipFailedOfflineDownload(bookId: UUID, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.skipFailed(bookId: bookId, store: store) }
    }

    // MARK: - Neighbour Prefetch

    /// Prefetches chapters around the given center index through the injected coordinator.
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
            sortChangeSourceOriginsByHealth()
            warmSearchTOCCacheIfEnabled()
            return
        }

        changeSourceLoading = true
        changeSourceError = nil
        changeSourceOrigins = []
        // Keep prior failure flags across a re-search so a known-bad source stays marked.
        changeSourceFailedKeys = Set(ChangeSourceCache.shared.entry(for: bookId)?.failedKeys ?? [])
        let bookTitle = book.title
        let bookAuthor = book.author
        let currentOriginKey = ChangeSourceCache.originKey(
            sourceId: currentSourceId, bookUrl: book.bookInfoURL)
        // Search ALL enabled sources, including the current one. Aggregation sources
        // expose several "channels" for the same book under a single sourceId, and a
        // user may have only that one source installed — filtering by sourceId would
        // then yield zero results. We dedup by source-qualified origin, so sibling
        // sources that share one site URL remain independently switchable.
        let sources = enabledSources
        let concurrency = NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency)
        let autoPauseCount = NetworkSearchSettings.effectiveAutoPauseCount(
            configured: GlobalSettings.shared.searchAutoPauseCount,
            sourceCount: sources.count
        )
        let autoPausePolicy = SearchAutoPausePolicy(count: autoPauseCount)

        changeSourceSearchTask?.cancel()
        tocWarmTask?.cancel()
        changeSourceSearchTask = Task { [weak self] in
            guard let self else { return }
            var seenOriginKeys = Set<String>()
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
                            bookTitle: bookTitle,
                            bookAuthor: bookAuthor,
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
                    // Collect the whole source's matches first and append once:
                    // per-book appends re-published (and re-diffed) the sheet's
                    // list for every single origin.
                    var batchOrigins: [BookOrigin] = []
                    for ob in list {
                        let matched = SearchBook.isLikelySameBook(
                            name: bookTitle, author: bookAuthor,
                            name: ob.name, author: ob.author
                        )
                        guard matched else { continue }
                        // Dedup only the same source + URL. Aggregation channels from
                        // different sources may share a URL but remain distinct rules.
                        let originKey = ChangeSourceCache.originKey(
                            sourceId: ob.sourceId, bookUrl: ob.bookUrl)
                        if !originKey.isEmpty {
                            if originKey == currentOriginKey { continue }
                            guard seenOriginKeys.insert(originKey).inserted else { continue }
                        }
                        batchOrigins.append(
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
                            exactCount: self.changeSourceOrigins.count + batchOrigins.count,
                            fuzzyCount: 0
                        ) {
                            shouldPause = true
                            break
                        }
                    }
                    if !batchOrigins.isEmpty {
                        self.changeSourceOrigins.append(contentsOf: batchOrigins)
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
            // Fastest sources first (respondTime EMA), then persist that order so
            // the cached list reopens pre-sorted and TOC warm-up hits the best ones.
            self.sortChangeSourceOriginsByHealth()
            // Persist results so reopening the sheet is instant (honors 快取天數).
            ChangeSourceCache.shared.store(origins: self.changeSourceOrigins, for: bookId)
            // Only when 搜索時載入目錄 is on; otherwise a tap fetches its own TOC.
            self.warmSearchTOCCacheIfEnabled()
        }
    }

    /// Orders 換源 candidates: origins that previously failed to switch sink to
    /// the bottom; the rest sort by their source's measured response time
    /// (unmeasured sources keep arrival order after measured ones).
    private func sortChangeSourceOriginsByHealth() {
        guard changeSourceOrigins.count > 1 else { return }
        let failed = changeSourceFailedKeys
        let health = SourceHealthStore.shared
        let decorated = changeSourceOrigins.enumerated().map { offset, origin in
            (
                offset: offset,
                origin: origin,
                isFailed: failed.contains(ChangeSourceCache.originKey(
                    sourceId: origin.sourceId, bookUrl: origin.bookUrl))
                    || failed.contains(ChangeSourceCache.urlKey(origin.bookUrl)),
                speed: health.responseSortKey(origin.sourceId)
            )
        }
        changeSourceOrigins = decorated.sorted { a, b in
            if a.isFailed != b.isFailed { return !a.isFailed }
            if a.speed != b.speed { return a.speed < b.speed }
            return a.offset < b.offset
        }.map(\.origin)
    }

    /// Background-fetches the TOC of the first few switchable origins into
    /// `BookSourceFetcher`'s cache-first TOC store (Legado's tocMap idea), so the
    /// actual switch (`updateOnlineBookSource` → `fetchTOCPackage`) is a cache hit
    /// instead of a network round-trip the user waits on. Serial and low-priority;
    /// already-cached TOCs return immediately.
    // MARK: - Source Switch

    /// Legado `ChangeBookSourceViewModel.getToc`: the search-phase cache first, the network
    /// only on a miss. The resulting package is handed to the commit path, so a switch fetches
    /// its TOC exactly once — the commit used to fetch it a second time.
    func prepareTOCPackage(for origin: BookOrigin) async throws -> TOCPackage {
        let key = ChangeSourceCache.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl)
        if let cached = searchTOCCache[key] {
            return cached
        }
        guard let source = BookSourceStore.shared.sources.first(where: { $0.id == origin.sourceId })
        else {
            throw NSError(
                domain: "ReaderViewModel", code: -1,
                userInfo: [NSLocalizedDescriptionKey: localized("找不到書源")])
        }
        let package = try await bookSourceFetcher.fetchTOCPackage(
            tocUrl: origin.tocUrl,
            source: source,
            runtimeVariables: origin.runtimeVariables
        )
        // An empty TOC means this source's rules matched nothing. Fail here, before the
        // commit: the sheet stays open, the origin gets flagged, and the book keeps the
        // source it already had. Committing an empty list instead left the book with no
        // chapters at all — see the same guard in `BookStore.updateOnlineBookSource`.
        guard !package.chapters.isEmpty else {
            AppLogger.parse("⟐ changeSource empty TOC", context: [
                "source": origin.sourceName,
                "tocUrl": String(origin.tocUrl.prefix(120)),
            ])
            throw NSError(
                domain: "ReaderViewModel", code: -2,
                userInfo: [NSLocalizedDescriptionKey: localized("此書源取不到目錄")])
        }
        cacheSearchTOC(package, forKey: key)
        return package
    }

    /// Runs a tapped source switch as a cancellable unit, publishing the pending origin so the
    /// sheet can show progress. Legado does the same with a `WaitDialog` whose cancel listener
    /// cancels the coroutine.
    func beginSourceSwitch(
        to origin: BookOrigin,
        work: @escaping @MainActor () async -> Void
    ) {
        changeSourceSwitchTask?.cancel()
        changeSourcePendingOrigin = origin
        changeSourceSwitchTask = Task { @MainActor [weak self] in
            await work()
            guard !Task.isCancelled else { return }
            self?.finishSourceSwitch()
        }
    }

    func finishSourceSwitch() {
        changeSourceSwitchTask = nil
        changeSourcePendingOrigin = nil
    }

    func cancelPendingSourceSwitch() {
        changeSourceSwitchTask?.cancel()
        finishSourceSwitch()
    }

    /// Stops the cross-source fan-out. Called the moment a source is tapped: the search holds
    /// the connection pool and the JS bridge, and from that point it is competing with the one
    /// fetch the user is actually waiting on (Legado's `getToc` opens with `stopSearch()`).
    func stopChangeSourceSearch() {
        changeSourceSearchTask?.cancel()
        changeSourceSearchTask = nil
        changeSourceLoading = false
    }

    private func cacheSearchTOC(_ package: TOCPackage, forKey key: String) {
        // Never cache an empty TOC: `prepareTOCPackage` returns cache hits verbatim, so one
        // stored here would slip past its empty-TOC guard on every later tap.
        guard !package.chapters.isEmpty else { return }
        guard !key.isEmpty, searchTOCCache[key] == nil else { return }
        guard searchTOCChapterCount < Self.searchTOCChapterLimit else { return }
        searchTOCChapterCount += package.chapters.count
        searchTOCCache[key] = package
    }

    /// Fills `searchTOCCache` for the found candidates when 搜索時載入目錄 is on, so tapping one
    /// switches with no network wait.
    ///
    /// Legado fetches each TOC inline inside that source's search coroutine, which makes the
    /// result list itself appear slowly. Warming after the list is already sorted keeps the
    /// list fast and still has most TOCs ready by the time a source is picked; a tap that
    /// lands first simply fetches normally through `prepareTOCPackage`.
    private func warmSearchTOCCacheIfEnabled() {
        guard GlobalSettings.shared.changeSourceLoadToc else { return }
        tocWarmTask?.cancel()
        let failedKeys = changeSourceFailedKeys
        let sources = BookSourceStore.shared.sources
        let jobs: [(String, BookOrigin, BookSource)] = changeSourceOrigins.compactMap { origin in
            let key = ChangeSourceCache.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl)
            guard !key.isEmpty,
                  searchTOCCache[key] == nil,
                  !failedKeys.contains(key),
                  !failedKeys.contains(ChangeSourceCache.urlKey(origin.bookUrl)),
                  let source = sources.first(where: { $0.id == origin.sourceId })
            else { return nil }
            return (key, origin, source)
        }
        guard !jobs.isEmpty else { return }
        let fetcher = bookSourceFetcher
        tocWarmTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (String, TOCPackage)?.self) { group in
                var next = 0
                // Bounded window: the warm-up must stay in the background of whatever the
                // user does next, not saturate the pool the way the fan-out does.
                let active = min(4, jobs.count)

                func enqueue() {
                    guard next < jobs.count else { return }
                    let (key, origin, source) = jobs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        guard let package = try? await fetcher.fetchTOCPackage(
                            tocUrl: origin.tocUrl,
                            source: source,
                            runtimeVariables: origin.runtimeVariables
                        ) else { return nil }
                        return (key, package)
                    }
                }

                for _ in 0..<active { enqueue() }
                while let result = await group.next() {
                    if Task.isCancelled { break }
                    if let (key, package) = result {
                        self?.cacheSearchTOC(package, forKey: key)
                    }
                    enqueue()
                }
            }
        }
    }

    /// Reports an error from a source change operation.
    func reportChangeSourceError(_ message: String?) {
        changeSourceError = message
    }

    /// Flags an origin that failed to switch (its TOC fetch threw), persisting the
    /// flag so it stays marked across reopen/re-search of the same book.
    func markOriginFailed(bookId: UUID, sourceId: UUID, bookUrl: String) {
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: bookUrl)
        guard !key.isEmpty else { return }
        changeSourceFailedKeys.insert(key)
        ChangeSourceCache.shared.markFailed(originKey: key, for: bookId)
    }

    /// Searches one source with a timeout, off the main actor. Returns nil on error
    /// or timeout so a slow/hung source can't stall the whole 換源 search.
    /// `nonisolated` so concurrent tasks don't serialize back onto the MainActor.
    nonisolated private static func searchSourceWithTimeout(
        query: String,
        bookTitle: String,
        bookAuthor: String,
        source: BookSource,
        bookSourceFetcher: BookSourceFetching,
        seconds: UInt64 = 20
    ) async -> [OnlineBook]? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let books: [OnlineBook]? = await withTaskGroup(of: [OnlineBook]?.self) { group in
            group.addTask {
                // Early filter (Legado BookList idea): reject non-matching items
                // right after their name/author rules run, so the remaining field
                // rules (cover/intro/kind/wordCount/lastChapter/bookUrl) are never
                // evaluated — 換源 only keeps exact same-book candidates anyway.
                try? await bookSourceFetcher.search(
                    query: query,
                    in: source,
                    earlyFilter: { name, author in
                        SearchBook.isLikelySameBook(
                            name: bookTitle, author: bookAuthor,
                            name: name, author: author
                        )
                    }
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if books != nil {
            // Feed the response-time EMA so the 換源 list can rank fast sources first.
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            let sourceId = source.id
            await MainActor.run {
                SourceHealthStore.shared.recordSuccess(sourceId, responseMs: elapsedMs)
            }
        }
        return books
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
                // os_log, not print: this is the end of the online chapter pipeline,
                // and on a device it's the only record of *why* a chapter failed.
                AppLogger.parse("⟐ chapter fetch failed", error: error, context: [
                    "chapter": chapterIndex,
                    "book": book.title,
                    "online": book.isOnline
                ])
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
