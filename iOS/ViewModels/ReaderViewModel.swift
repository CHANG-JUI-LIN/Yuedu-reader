import Combine
import Foundation
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapterStates: [Int: ChapterLoadState] = [:]

    // MARK: - 換源狀態（從 ReaderView 移入，由 ViewModel 統一管理）
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

    // MARK: - 章節加載

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

    // MARK: - 章節取消

    /// 取消指定書籍的所有進行中章節請求
    func cancelAll(for bookId: UUID) async {
        await chapterFetcher.cancelAll(for: bookId)
    }

    // MARK: - 下載動作

    /// 啟動或取消書籍離線下載，取代 View 直接呼叫 OnlineBookCoordinator.shared
    func handleDownloadAction(book: ReadingBook, store: BookStore) {
        switch book.offlineDownloadState {
        case .none, .failed:
            bookCoordinator.downloadBook(book, store: store)
        case .downloading, .available:
            break  // .available 由 View 層透過 store.clearOnlineDownload 處理
        }
    }

    // MARK: - 鄰域預加載

    /// 預加載指定章節的前後章節，取代 View 直接呼叫 OnlineBookCoordinator.shared
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore) {
        Task {
            await bookCoordinator.prefetchAround(book: book, center: center, store: store)
        }
    }

    // MARK: - 換源搜尋

    /// 搜尋同書名的替代書源，結果更新至 changeSourceOrigins/@Published，取代 View 內 Task
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

    /// 由 View 回報換源操作（切換書源按鈕）所產生的錯誤
    func reportChangeSourceError(_ message: String?) {
        changeSourceError = message
    }

    // MARK: - Private

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
