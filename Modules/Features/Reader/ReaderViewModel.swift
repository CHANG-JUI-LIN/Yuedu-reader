import Combine
import Foundation
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapterStates: [Int: ChapterLoadState] = [:]
    /// The book shows paragraph-review bubbles — a review link or a bubble SVG in a
    /// chapter loaded so far. Gates 閱讀設定 › 段評氣泡.
    @Published private(set) var hasParagraphReviews = false

    /// Chapter cache availability validated by the loading pipeline. This is deliberately
    /// kept in memory so SwiftUI presentation code never re-opens and re-validates chapter
    /// files during `body` evaluation.
    private var availableChapterIndexes: Set<Int> = []

    // MARK: - Source Change State

    /// The 換源 list (search, TOCs, failure flags, scores), shared with 作品詳情's 換源. The sheet
    /// observes it directly, so a result arriving re-renders the sheet and not the reader.
    let changeSource: ChangeSourceSearch
    var changeSourceOrigins: [BookOrigin] { changeSource.ranked }
    var changeSourceLoading: Bool { changeSource.isSearching }
    var changeSourceError: String? { changeSource.error }
    /// Normalized source-qualified keys of origins that failed to switch (TOC fetch threw),
    /// so the 換源 list can flag them. Backed by `ChangeSourceCache`.
    var changeSourceFailedKeys: Set<String> { changeSource.failedKeys }
    /// Non-nil while a tapped source is being switched to. The sheet renders a cancellable
    /// "正在載入目錄…" over the row instead of looking frozen — Legado shows a `WaitDialog`
    /// on the same event, and its cancel listener aborts the fetch.
    @Published private(set) var changeSourcePendingOrigin: BookOrigin?
    /// Non-nil while another version of the work is being switched to (`ShelfVersionSwitch`),
    /// by its node key: a kept copy's `.copy(id)`. One switch at a time, as with a source.
    @Published private(set) var changeSourcePendingVersion: SourceItemKey?
    /// 自動換源 at work, or how it failed: the reader's banner (Legado toasts the same).
    @Published private(set) var autoChangeSourceNotice: AutoChangeSourceNotice?

    enum AutoChangeSourceNotice: Equatable {
        case changing
        case failed(id: UUID, message: String)
    }

    /// 單章換源: the 換源 sheet replaces only the text of the chapter being read (Legado's
    /// ChangeChapterSourceDialog), not the book's 來源配置. Every opening of the sheet starts
    /// on 整本書 (`resetChangeSourceSheetMode`).
    @Published var changeSourceReplacesChapterOnly = false
    /// The origin whose 目錄 is pushed to pick that chapter from.
    @Published var changeChapterSourcePick: ChangeChapterSourcePick?

    func resetChangeSourceSheetMode() {
        changeSourceReplacesChapterOnly = false
        changeChapterSourcePick = nil
    }

    private struct InFlightRequest {
        let token: UUID
        let priority: ChapterFetchPriority
        let task: Task<Void, Never>
    }

    private var chapterFetcher: ChapterFetching
    private var bookSourceFetcher: BookSourceFetching
    private var offlineDownloadManager: (any OfflineDownloadManaging)?
    private var inFlightRequests: [Int: InFlightRequest] = [:]
    /// Books already checked for auto manga detection this session (cached-chapter path),
    /// so a genuine text book is not re-probed on every `ensureChapterReady`.
    private var mangaDetectionAttempted: Set<UUID> = []
    private struct CachedChapterInspectionKey: Hashable {
        let bookId: UUID
        let chapterIndex: Int
    }
    /// Cached chapters already inspected for paragraph-review capability. The inspection
    /// uses `ChapterFetching` asynchronously instead of synchronously reading files from a
    /// SwiftUI update callback.
    private var paragraphReviewInspectionAttempted: Set<CachedChapterInspectionKey> = []
    /// The switch the user just tapped, while its TOC is being prepared. Drives the sheet's
    /// cancellable loading state (Legado's `WaitDialog`), and holding the task is what makes
    /// cancelling possible at all.
    private var changeSourceSwitchTask: Task<Void, Never>?

    convenience init() {
        self.init(
            chapterFetcher: AppDependencies.live.chapterFetcher,
            bookSourceFetcher: AppDependencies.live.bookSourceFetcher,
            offlineDownloadManager: AppDependencies.live.offlineDownloadManager
        )
    }

    init(
        chapterFetcher: ChapterFetching,
        bookSourceFetcher: BookSourceFetching,
        offlineDownloadManager: (any OfflineDownloadManaging)? = nil
    ) {
        self.chapterFetcher = chapterFetcher
        self.bookSourceFetcher = bookSourceFetcher
        self.offlineDownloadManager = offlineDownloadManager
        self.changeSource = ChangeSourceSearch(fetcher: bookSourceFetcher)
    }

    func chapterState(for chapterIndex: Int) -> ChapterLoadState {
        chapterStates[chapterIndex] ?? .idle
    }

    func isChapterContentAvailable(at chapterIndex: Int) -> Bool {
        availableChapterIndexes.contains(chapterIndex)
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
        availableChapterIndexes.remove(chapterIndex)
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
        // The single-chapter form (`resetChapterState`) drops this too. Leaving it behind
        // made every chapter keep claiming "content available" against a cache that 移除下載
        // had just emptied, and `overlayState` consults it first — so the reader painted
        // 資料不一致 over chapters it could simply have refetched.
        availableChapterIndexes.removeAll()
    }

    // MARK: - Chapter Loading

    /// The book the chapter states currently describe.
    ///
    /// `setChapterState` is reached from paths that never carried the book
    /// (`finishFetch`, `clearInFlight`), and the retry log keys on it. Recorded here,
    /// at the one entry point every chapter request passes through, rather than
    /// widening four signatures for a diagnostic.
    private var currentBookId: String?

    func ensureChapterReady(
        book: ReadingBook?,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async {
        guard let book, let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            return
        }
        currentBookId = book.id.uuidString

        // Volume headers (作品相关 / 第N卷 …) have no fetchable content. Mark ready immediately so
        // the builder renders a divider page instead of spinning forever on an empty fetch.
        if refs[chapterIndex].shouldRenderAsVolumeSeparator {
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            setChapterState(.ready, for: chapterIndex, contentAvailable: true)
            return
        }

        // A previous failure is about to be re-evaluated. The cache probe below is an actor
        // hop plus metadata/artifact reads and a checksum, and the reader renders the failure
        // overlay straight off this state — leaving `.failed` in place paints "章節載入失敗"
        // over a chapter that is actively being loaded again.
        if case .failed = chapterStates[chapterIndex] {
            chapterStates[chapterIndex] = .loading
        }
        if chapterStates[chapterIndex] == .cancelled {
            chapterStates[chapterIndex] = .loading
        }

        if await chapterFetcher.isChapterCached(book: book, chapterIndex: chapterIndex) {
            setChapterState(.ready, for: chapterIndex, contentAvailable: true)
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            inspectCachedChapter(
                book: book, chapterIndex: chapterIndex, store: store)
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
            setChapterState(.loading, for: chapterIndex, contentAvailable: false)
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

        setChapterState(.loading, for: chapterIndex, contentAvailable: false)
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

    /// Cancels the reader's in-flight chapter requests for the given book.
    ///
    /// Offline downloads are deliberately spared: the reader and the downloader share one
    /// fetch manager, so closing the reader used to cancel a download running on the same
    /// book. `runBook` treats cancellation as a clean exit, so the download simply stopped —
    /// no error, no queue, state still `.downloading`.
    func cancelAll(for bookId: UUID) async {
        await chapterFetcher.cancelAll(for: bookId, includingDownloads: false)
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

    /// Requests the neighbour window around `center` through `ensureChapterReady`, the same
    /// entry the reader's own chapter uses.
    ///
    /// It used to go through `OnlineBookCoordinator.prefetchAround`, which fills the cache
    /// without telling anyone. The engine preloads n±1 the moment a chapter opens — before
    /// any prefetch can land — and gets a 載入中 placeholder; with no `.ready` published for
    /// the neighbour, nothing supplied it again, so the placeholder stayed until the reader
    /// crossed into it and the entry probe found the bytes. That was one frame of
    /// 「第N章 載入中」 on the first chapter turn after every open (回饋中心 #155). Through
    /// here each neighbour publishes its own `.ready`, and `handleChapterStateChanges`
    /// supplies it to the engine like any other arriving chapter.
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {
        guard let refs = book.onlineChapters, !refs.isEmpty else { return }
        for neighbour in OnlineBookCoordinator.adjacentPrefetchWindow(
            center: center, chapterCount: refs.count, ahead: GlobalSettings.shared.chapterPrefetchCount
        ) {
            await ensureChapterReady(
                book: book,
                chapterIndex: neighbour.index,
                priority: neighbour.priority,
                store: store
            )
        }
    }

    // MARK: - Source Change Search

    /// Searches for other origins of `book` (`ChangeSourceSearch`). Unless `forceRefresh` is
    /// set, a fresh cached result for this book is reused (網路設定 →「搜索結果快取天數」).
    ///
    /// Every enabled source is searched, the current one included: aggregation sources expose
    /// several "channels" for the same book under one sourceId, and a user may have only that
    /// one source installed. The origin in use is the one left out.
    func loadOtherOrigins(
        book: ReadingBook,
        currentSourceId: UUID?,
        enabledSources: [BookSource],
        store: BookStore,
        forceRefresh: Bool = false,
        readingChapter: ChangeSourceTarget.ReadingChapter? = nil
    ) {
        changeSource.start(
            ChangeSourceTarget(
                title: book.title,
                author: book.author,
                bookId: book.id,
                currentSourceId: currentSourceId,
                // A book read from elsewhere (an imported file, a library, a module) has no
                // origin among the sources to leave out.
                currentBookURL: currentSourceId == nil ? nil : book.bookInfoURL,
                readingChapter: readingChapter,
                kind: Self.contentKind(of: book)
            ),
            sources: enabledSources,
            forceRefresh: forceRefresh
        )
    }

    /// The kind of book the reader shows, for 換源's 「書籍類型不一樣」 check.
    static func contentKind(of book: ReadingBook) -> OnlineBookContentKind {
        switch book.contentPipelineKind {
        case .manga: .manga
        case .audio: .audio
        case .video: .video
        case .epub, .txt, .html, .fixedPage: .text
        }
    }

    // MARK: - Source Switch

    /// The origin's TOC, from the 換源 search when it already fetched it (`ChangeSourceSearch`).
    func prepareTOCPackage(for origin: BookOrigin) async throws -> TOCPackage {
        try await changeSource.prepareTOCPackage(for: origin)
    }

    /// Runs a tapped source switch as a cancellable unit, publishing the pending origin so the
    /// sheet can show progress. Legado does the same with a `WaitDialog` whose cancel listener
    /// cancels the coroutine.
    func beginSourceSwitch(
        to origin: BookOrigin,
        work: @escaping @MainActor () async -> Void
    ) {
        changeSourceSwitchTask?.cancel()
        changeSourcePendingVersion = nil
        changeSourcePendingOrigin = origin
        changeSourceSwitchTask = Task { @MainActor [weak self] in
            await work()
            guard !Task.isCancelled else { return }
            self?.finishSourceSwitch()
        }
    }

    /// `beginSourceSwitch` for another version of the work.
    func beginVersionSwitch(
        to version: SourceItemKey,
        work: @escaping @MainActor () async -> Void
    ) {
        changeSourceSwitchTask?.cancel()
        changeSourcePendingOrigin = nil
        changeSourcePendingVersion = version
        changeSourceSwitchTask = Task { @MainActor [weak self] in
            await work()
            guard !Task.isCancelled else { return }
            self?.finishSourceSwitch()
        }
    }

    /// 自動換源 (Legado `autoChangeSource`): which origin it switches to is only known once one
    /// loads, so there is no row to mark — the reader shows a banner instead.
    func beginAutoSourceSwitch(work: @escaping @MainActor () async -> Void) {
        changeSourceSwitchTask?.cancel()
        changeSourcePendingOrigin = nil
        changeSourcePendingVersion = nil
        autoChangeSourceNotice = .changing
        changeSourceSwitchTask = Task { @MainActor [weak self] in
            await work()
            guard !Task.isCancelled else { return }
            self?.finishSourceSwitch()
        }
    }

    /// 自動換源 found nothing to switch to, or its switch failed: the banner says so, and so
    /// does the 換源 sheet's footer.
    func reportAutoChangeSourceFailure(_ message: String) {
        autoChangeSourceNotice = .failed(id: UUID(), message: message)
        changeSource.reportError(message)
    }

    /// The failure banner has been shown long enough; a newer notice is left in place.
    func dismissAutoChangeSourceNotice(_ notice: AutoChangeSourceNotice) {
        if autoChangeSourceNotice == notice { autoChangeSourceNotice = nil }
    }

    /// Whether a source or a version is being switched to.
    var isSwitchingSource: Bool {
        changeSourcePendingOrigin != nil || changeSourcePendingVersion != nil
            || autoChangeSourceNotice == .changing
    }

    func finishSourceSwitch() {
        changeSourceSwitchTask = nil
        changeSourcePendingOrigin = nil
        changeSourcePendingVersion = nil
        if autoChangeSourceNotice == .changing { autoChangeSourceNotice = nil }
    }

    func cancelPendingSourceSwitch() {
        changeSourceSwitchTask?.cancel()
        finishSourceSwitch()
    }

    /// Stops the cross-source fan-out. Called the moment a source is tapped: the search holds
    /// the connection pool and the JS bridge, and from that point it is competing with the one
    /// fetch the user is actually waiting on (Legado's `getToc` opens with `stopSearch()`).
    func stopChangeSourceSearch() {
        changeSource.stop()
    }

    /// Reports an error from a source change operation.
    func reportChangeSourceError(_ message: String?) {
        changeSource.reportError(message)
    }

    /// Flags an origin that failed to switch (its TOC fetch threw), persisting the
    /// flag so it stays marked across reopen/re-search of the same book.
    func markOriginFailed(bookId: UUID, sourceId: UUID, bookUrl: String) {
        changeSource.markFailed(sourceId: sourceId, bookUrl: bookUrl, bookId: bookId)
    }

    /// Drops an origin's failure flag once it has switched successfully, so the row stops
    /// showing 載入失敗.
    func clearOriginFailure(bookId: UUID, sourceId: UUID, bookUrl: String) {
        changeSource.clearFailure(sourceId: sourceId, bookUrl: bookUrl, bookId: bookId)
    }

    /// Searches one source with a timeout, off the main actor. Returns nil on error
    /// or timeout so a slow/hung source can't stall the whole 換源 search.
    /// `nonisolated` so concurrent tasks don't serialize back onto the MainActor.
    // MARK: - Private

    /// Reads an already-validated cached package off the main presentation path. Besides the
    /// one-shot media probe, each cached text chapter is inspected until paragraph-review
    /// capability is found. `ChapterFetching` returns the existing package here; no network
    /// fallback is introduced because this method is called only after `isChapterCached`.
    private func inspectCachedChapter(
        book: ReadingBook,
        chapterIndex: Int,
        store: BookStore?
    ) {
        let inspectionKey = CachedChapterInspectionKey(
            bookId: book.id,
            chapterIndex: chapterIndex
        )
        let shouldInspectParagraphReviews = !hasParagraphReviews
            && paragraphReviewInspectionAttempted.insert(inspectionKey).inserted
        let shouldDetectMedia = book.isOnline
            && book.contentPipelineKind != .manga
            && store != nil
            && mangaDetectionAttempted.insert(book.id).inserted

        guard shouldInspectParagraphReviews || shouldDetectMedia else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let package = await self.chapterFetcher.cachedChapterPackage(
                book: book, chapterIndex: chapterIndex),
                  !package.content.isEmpty
            else { return }

            if shouldInspectParagraphReviews {
                self.recordParagraphReviewsIfPresent(in: package.content)
            }
            if shouldDetectMedia, let store,
               !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content, atChapter: chapterIndex) {
                store.upgradeToAudioIfDetected(bookId: book.id, content: package.content, atChapter: chapterIndex)
            }
        }
    }

    /// Links are a string search, so they are checked here. A bubble without one takes
    /// decoding the chapter's SVGs until one is recognized, which is off the main actor.
    private func recordParagraphReviewsIfPresent(in content: String) {
        guard !hasParagraphReviews else { return }
        if ReaderHTMLUtilities.containsParagraphReviewLinks(in: content) {
            hasParagraphReviews = true
            return
        }
        guard content.range(of: "data:image/svg+xml", options: .caseInsensitive) != nil else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard CommentBubbleSVGRecognizer.containsRecognizedBubble(inChapterHTML: content) else { return }
            await MainActor.run { [weak self] in self?.hasParagraphReviews = true }
        }
    }

    private func setChapterState(
        _ state: ChapterLoadState,
        for chapterIndex: Int,
        contentAvailable: Bool
    ) {
        if contentAvailable {
            availableChapterIndexes.insert(chapterIndex)
        } else {
            availableChapterIndexes.remove(chapterIndex)
        }
        let previous = chapterStates[chapterIndex]
        chapterStates[chapterIndex] = state
        recordChapterStateTransition(
            from: previous, to: state, chapter: chapterIndex, contentAvailable: contentAvailable
        )
    }

    /// The chapter-supply story, in the log.
    ///
    /// Every long-running complaint in this area — 無限加載中, 莫名其妙章節載入失敗,
    /// 鎖屏聽書停止 — was a question about which state a chapter ended up in and how it
    /// got there (`Technotes/ReaderChapterSupply.md`). That was only answerable with a
    /// Mac attached. This is the single funnel every state change passes through.
    private func recordChapterStateTransition(
        from previous: ChapterLoadState?,
        to state: ChapterLoadState,
        chapter: Int,
        contentAvailable: Bool
    ) {
        guard previous != state else { return }
        let severity: DiagnosticSeverity
        switch state {
        case .failed:    severity = .error
        case .cancelled: severity = .notice
        default:         severity = .trace
        }
        AppLogger.render(
            "⟐ chapterState ch=\(chapter) \(previous.map { "\($0)" } ?? "nil") → \(state) content=\(contentAvailable)",
            level: severity
        )
        // A chapter that finally arrived is no longer retrying, so its history must not
        // carry into an unrelated later failure.
        if state == .ready, contentAvailable {
            ChapterRetryLog.noteSuccess(chapter: chapter, bookId: currentBookId)
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
                let package = try await self.chapterFetcher.fetchChapter(
                    book: book,
                    chapterIndex: chapterIndex,
                    priority: priority,
                    store: store
                )
                guard !Task.isCancelled else {
                    self.clearInFlight(chapterIndex: chapterIndex, token: token)
                    return
                }
                let result: ChapterLoadState = package.state == .cached && !package.content.isEmpty
                    ? .ready
                    : .failed(reason: package.failureReason ?? "empty")
                if case .ready = result {
                    self.recordParagraphReviewsIfPresent(in: package.content)
                }
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
                    if !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content, atChapter: chapterIndex) {
                        store.upgradeToAudioIfDetected(bookId: book.id, content: package.content, atChapter: chapterIndex)
                    }
                }
                self.finishFetch(chapterIndex: chapterIndex, token: token, result: result)
            } catch {
                // Cancellation is not a verdict on the chapter, and it arrives in more than
                // one shape: `CancellationError` thrown directly, and `URLError.cancelled`
                // (-999) from a URLSession or WKWebView navigation torn down mid-flight.
                // Only the first was recognised, so the second reached the catch-all below
                // and surfaced as 章節載入失敗 on a chapter that fetched fine the moment it
                // was asked again — the failure users worked around by refreshing.
                if Self.isCancellation(error) || Task.isCancelled {
                    self.clearInFlight(chapterIndex: chapterIndex, token: token)
                    return
                }
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
        guard inFlightRequests[chapterIndex]?.token == token else { return }
        inFlightRequests.removeValue(forKey: chapterIndex)
        setChapterState(result, for: chapterIndex, contentAvailable: result == .ready)
    }

    /// Errors that mean "this request was torn down", not "this chapter cannot be read".
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func clearInFlight(chapterIndex: Int, token: UUID) {
        guard inFlightRequests[chapterIndex]?.token == token else { return }
        inFlightRequests.removeValue(forKey: chapterIndex)
        if chapterStates[chapterIndex] == .loading {
            // `.idle` reads as "never asked" and had nothing driving a retry, so a preempted
            // chapter sat on the loading surface forever. `.cancelled` says a re-request is
            // owed; `handleChapterStateChanges` issues it.
            setChapterState(.cancelled, for: chapterIndex, contentAvailable: false)
        }
    }
}
