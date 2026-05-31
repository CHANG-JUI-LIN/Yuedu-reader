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
    func handleDownloadAction(book: ReadingBook, store: BookStore) {
        switch book.offlineDownloadState {
        case .none, .failed:
            bookCoordinator.downloadBook(book, store: store)
        case .downloading, .available:
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
    func loadOtherOrigins(
        book: ReadingBook,
        currentSourceId: UUID,
        enabledSources: [BookSource],
        store: BookStore
    ) {
        changeSourceLoading = true
        changeSourceError = nil
        changeSourceOrigins = []
        let searchTitle = book.title
        let key = SearchBook.makeKey(name: book.title, author: book.author)
        let sources = enabledSources.filter { $0.id != currentSourceId }
        Task { [weak self] in
            guard let self else { return }
            var byKey: [String: [OnlineBook]] = [:]
            for source in sources {
                do {
                    let list = try await self.bookSourceFetcher.search(query: searchTitle, in: source)
                    for ob in list {
                        let k = SearchBook.makeKey(name: ob.name, author: ob.author)
                        byKey[k, default: []].append(ob)
                    }
                } catch { continue }
            }
            let candidates = byKey[key] ?? []
            let origins: [BookOrigin] = candidates
                .filter { $0.sourceId != currentSourceId }
                .map { ob in
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
                }
            self.changeSourceOrigins = origins
            self.changeSourceLoading = false
        }
    }

    /// Reports an error from a source change operation.
    func reportChangeSourceError(_ message: String?) {
        changeSourceError = message
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
            store.upgradeToMangaIfDetected(bookId: book.id, content: package.content)
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
                        print("[MangaDetect] ch=\(chapterIndex) len=\(package.content.count) imgURLs=\(imgs.count) looksManga=\(MangaChapterParser.looksLikeMangaContent(package.content)) head=\(head)")
                    }
                    #endif
                    store.upgradeToMangaIfDetected(bookId: book.id, content: package.content)
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
