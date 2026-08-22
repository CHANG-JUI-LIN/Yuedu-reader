import SwiftUI

struct DownloadManagementView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.appDependencies) private var dependencies
    @StateObject private var viewModel = DownloadManagementViewModel()
    @State private var bookPendingRemoval: ReadingBook?

    private var onlineBooks: [ReadingBook] {
        store.books.filter { $0.isOnline }
    }

    private var activeDownloads: [ReadingBook] {
        onlineBooks.filter { book in
            book.offlineDownloadState == .downloading
                || book.offlineDownloadState == .paused
                || book.offlineDownloadState == .partial
                || (book.offlineDownloadState == .failed && book.offlineDownloadTask != nil)
        }
    }

    private var downloadedBooks: [ReadingBook] {
        onlineBooks.filter { $0.offlineDownloadState == .available }
    }

    private var totalDownloadedMegabytes: Double {
        viewModel.totalMegabytes
    }

    private var storageStateToken: String {
        onlineBooks
            .map { "\($0.id.uuidString):\($0.offlineDownloadState.rawValue)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                activeDownloadsSection
                downloadedBooksSection
            }
            .navigationTitle(localized("下載管理"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .task {
                await dependencies.offlineDownloadManager
                    .reconcileInterruptedDownloads(store: store)
                await viewModel.refreshStorage(
                    for: onlineBooks,
                    chapterStore: dependencies.offlineChapterStore
                )
            }
            .onChange(of: storageStateToken) { _, _ in
                Task {
                    await viewModel.refreshStorage(
                        for: onlineBooks,
                        chapterStore: dependencies.offlineChapterStore
                    )
                }
            }
            // Removal throws away a download the user spent time and data on, so it
            // confirms first — and the message says what survives, because "移除"
            // next to a book title reads like it deletes the book itself.
            .alert(
                localized("移除下載內容？"),
                isPresented: Binding(
                    get: { bookPendingRemoval != nil },
                    set: { if !$0 { bookPendingRemoval = nil } }
                ),
                presenting: bookPendingRemoval
            ) { book in
                Button(localized("移除"), role: .destructive) {
                    removeDownload(for: book)
                    bookPendingRemoval = nil
                }
                Button(localized("取消"), role: .cancel) {
                    bookPendingRemoval = nil
                }
            } message: { book in
                Text(
                    String(
                        format: localized("將刪除《%@》已下載的章節。書籍仍留在書架，可重新下載。"),
                        book.title
                    )
                )
            }
        }
    }

    private var summarySection: some View {
        Section(header: Text(localized("總覽"))) {
            statRow(
                title: localized("下載中"),
                value: "\(activeDownloads.count)",
                detail: localized("本")
            )
            statRow(
                title: localized("已下載"),
                value: "\(downloadedBooks.count)",
                detail: localized("本")
            )
            statRow(
                title: localized("佔用空間"),
                value: String(format: "%.1f", totalDownloadedMegabytes),
                detail: "MB"
            )
        }
        .interfaceSectionSurface()
    }

    private var activeDownloadsSection: some View {
        Section(header: Text(localized("下載中"))) {
            if activeDownloads.isEmpty {
                Text(localized("目前沒有下載任務"))
                    .foregroundColor(DSColor.textSecondary)
            } else {
                ForEach(activeDownloads) { book in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(book.title)
                                .font(DSFont.body)
                            Spacer()
                            Text(progressLabel(for: book))
                                .font(DSFont.caption.monospacedDigit())
                                .foregroundColor(DSColor.textSecondary)
                        }
                        ProgressView(value: downloadProgress(for: book))
                            .tint(book.offlineDownloadState == .paused ? DSColor.textSecondary : DSColor.accent)
                        HStack {
                            Text(String(format: "%.1f MB", cacheSizeMB(for: book)))
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                            Spacer()
                            // `.bordered` makes these read as real buttons; the explicit
                            // style also confines the tap to the button instead of the
                            // whole Form row.
                            if book.offlineDownloadState == .downloading {
                                Button {
                                    pauseDownload(for: book)
                                } label: {
                                    Label(localized("暫停下載"), systemImage: "pause.circle")
                                }
                                .font(DSFont.caption.weight(.medium))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button {
                                    resumeDownload(for: book)
                                } label: {
                                    Label(
                                        isRetryState(for: book)
                                            ? localized("重試失敗章節")
                                            : localized("繼續下載"),
                                        systemImage: isRetryState(for: book)
                                            ? "arrow.clockwise.circle"
                                            : "play.circle"
                                    )
                                }
                                .font(DSFont.caption.weight(.medium))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                if isRetryState(for: book) {
                                    Menu {
                                        Button {
                                            skipFailedChapters(for: book)
                                        } label: {
                                            Label(
                                                localized("略過失敗章節"),
                                                systemImage: "forward.end"
                                            )
                                        }
                                        Button(role: .destructive) {
                                            bookPendingRemoval = book
                                        } label: {
                                            Label(localized("移除"), systemImage: "trash")
                                        }
                                    } label: {
                                        Label(localized("更多"), systemImage: "ellipsis.circle")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(DSColor.textSecondary)
                                } else {
                                    Button(role: .destructive) {
                                        bookPendingRemoval = book
                                    } label: {
                                        // `Label` + `.iconOnly` keeps the button's own name for
                                        // VoiceOver; a bare `Image(systemName:)` would stay a
                                        // focusable element reading out "trash".
                                        Label(localized("移除"), systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(DSColor.destructive)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            bookPendingRemoval = book
                        } label: {
                            Label(localized("移除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var downloadedBooksSection: some View {
        Section(header: Text(localized("已下載書籍"))) {
            if downloadedBooks.isEmpty {
                Text(localized("尚未下載任何書籍"))
                    .foregroundColor(DSColor.textSecondary)
            } else {
                ForEach(downloadedBooks) { book in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                            Text(
                                "\(progressLabel(for: book)) \(localized("章"))  ·  \(rangeLabel(for: book))  ·  \(String(format: "%.1f", cacheSizeMB(for: book))) MB"
                            )
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                        }
                        Spacer()
                        // `.bordered` confines the tap to the button. Without an
                        // explicit style this row's single button swallowed the whole
                        // row, so tapping the book title removed the download outright.
                        Button(role: .destructive) {
                            bookPendingRemoval = book
                        } label: {
                            Label(localized("移除"), systemImage: "trash")
                        }
                        .font(DSFont.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(DSColor.destructive)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            bookPendingRemoval = book
                        } label: {
                            Label(localized("移除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .interfaceSectionSurface()
    }

    private func statRow(title: String, value: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value) \(detail)")
                .foregroundColor(DSColor.textSecondary)
        }
    }

    private func chapterTotal(for book: ReadingBook) -> Int {
        max(book.onlineChapters?.count ?? 0, 0)
    }

    private func isRetryState(for book: ReadingBook) -> Bool {
        book.offlineDownloadState == .partial || book.offlineDownloadState == .failed
    }

    private func downloadProgress(for book: ReadingBook) -> Double {
        let total = max(downloadTotal(for: book), 1)
        return min(max(Double(downloadCompleted(for: book)) / Double(total), 0), 1)
    }

    private func progressLabel(for book: ReadingBook) -> String {
        "\(downloadCompleted(for: book))/\(downloadTotal(for: book))"
    }

    private func downloadCompleted(for book: ReadingBook) -> Int {
        book.offlineDownloadTask?.clamped(to: chapterTotal(for: book))?.clampedCompletedChapterCount
            ?? book.downloadedChapterCount
    }

    private func downloadTotal(for book: ReadingBook) -> Int {
        book.offlineDownloadTask?.clamped(to: chapterTotal(for: book))?.totalChapterCount
            ?? max(chapterTotal(for: book), 0)
    }

    private func rangeLabel(for book: ReadingBook) -> String {
        guard let task = book.offlineDownloadTask?.clamped(to: chapterTotal(for: book)) else {
            return localized("全本")
        }
        return String(
            format: localized("第 %d 到 %d 章"),
            task.startChapterIndex + 1,
            task.endChapterIndex + 1
        )
    }

    private func resumeDownload(for book: ReadingBook) {
        Task {
            if book.offlineDownloadState == .partial || book.offlineDownloadState == .failed {
                await dependencies.offlineDownloadManager.retryFailed(book: book, store: store)
            } else {
                await dependencies.offlineDownloadManager.resume(book: book, store: store)
            }
        }
    }

    private func pauseDownload(for book: ReadingBook) {
        Task {
            await dependencies.offlineDownloadManager.pause(bookId: book.id, store: store)
        }
    }

    private func skipFailedChapters(for book: ReadingBook) {
        Task {
            await dependencies.offlineDownloadManager.skipFailed(bookId: book.id, store: store)
        }
    }

    private func removeDownload(for book: ReadingBook) {
        Task {
            do {
                try await dependencies.offlineDownloadManager.remove(
                    bookId: book.id,
                    store: store
                )
                await viewModel.refreshStorage(
                    for: onlineBooks,
                    chapterStore: dependencies.offlineChapterStore
                )
            } catch {
                AppLogger.error("Offline book removal failed", error: error)
            }
        }
    }

    private func cacheSizeMB(for book: ReadingBook) -> Double {
        viewModel.megabytes(for: book.id)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("下載管理") {
    DownloadManagementView()
        .environmentObject(DownloadManagementPreview.store)
        .environment(\.appDependencies, DownloadManagementPreview.dependencies)
}

/// Fake shelf and no-op services so every download state (and its buttons) can be
/// inspected in the canvas without a real source, network, or storage.
private enum DownloadManagementPreview {

    private static let chapterCount = 120

    static let store: BookStore = {
        let store = BookStore(
            metadataFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("download_management_preview_meta.json")
        )
        store.books = [
            makeBook(title: "巫師：從合成寶石開始", state: .downloading, completed: 37),
            makeBook(title: "劍來", state: .paused, completed: 12, paused: true),
            makeBook(title: "詭祕之主", state: .partial, completed: 80, failed: 3),
            makeBook(title: "我有一座冒險屋", state: .failed, completed: 60, failed: 5),
            makeBook(title: "全職高手", state: .available, completed: chapterCount),
        ]
        return store
    }()

    static let dependencies: AppDependencies = AppDependencies(
        webContentFetcher: PreviewWebContentFetcher(),
        bookSourceFetcher: PreviewBookSourceFetcher(),
        chapterFetcher: PreviewChapterFetcher(),
        onlineBookCoordinator: PreviewOnlineBookCoordinator(),
        offlineDownloadManager: PreviewOfflineDownloadManager(),
        offlineChapterStore: PreviewOfflineChapterStore(),
        readingPositionStore: JSONFileReadingPositionStore()
    )

    private static func makeBook(
        title: String,
        state: BookOfflineDownloadState,
        completed: Int,
        failed: Int = 0,
        paused: Bool = false
    ) -> ReadingBook {
        var book = ReadingBook(title: title, source: "https://example.com", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = UUID()
        book.contentPipelineKind = .html
        book.onlineChapters = (0..<chapterCount).map { index in
            OnlineChapterRef(
                index: index,
                title: "第 \(index + 1) 章",
                url: "https://example.com/\(index + 1)"
            )
        }
        var task = BookOfflineDownloadTask(
            requestedIndices: Set(0..<chapterCount),
            isPaused: paused
        )
        for index in 0..<completed {
            task.markCompleted(index)
        }
        for index in completed..<(completed + failed) {
            task.markFailed(
                OfflineChapterFailure(
                    chapterIndex: index,
                    title: "第 \(index + 1) 章",
                    category: .network,
                    message: "preview",
                    occurredAt: Date()
                )
            )
        }
        book.offlineDownloadTask = task
        book.offlineDownloadState = state
        book.downloadedChapterCount = completed
        return book
    }
}

private enum PreviewStubError: Error {
    case unavailable
}

private struct PreviewWebContentFetcher: WebContentFetching {
    func fetchHTML(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String?,
        allowInteractiveChallengeOn503: Bool
    ) async throws -> String {
        throw PreviewStubError.unavailable
    }
}

private struct PreviewBookSourceFetcher: BookSourceFetching {
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        throw PreviewStubError.unavailable
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        throw PreviewStubError.unavailable
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

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        throw PreviewStubError.unavailable
    }

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

private struct PreviewChapterFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool {
        false
    }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        throw PreviewStubError.unavailable
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}

    func cancelAll(for bookId: UUID) async {}
}

private final class PreviewOnlineBookCoordinator: OnlineBookCoordinating {
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}

private struct PreviewOfflineDownloadManager: OfflineDownloadManaging {
    func start(
        book: ReadingBook,
        selection: OfflineChapterSelection,
        store: BookStore
    ) async {}

    func pause(bookId: UUID, store: BookStore) async {}

    func resume(book: ReadingBook, store: BookStore) async {}

    func retryFailed(book: ReadingBook, store: BookStore) async {}

    func skipFailed(bookId: UUID, store: BookStore) async {}

    func remove(bookId: UUID, store: BookStore) async throws {}

    func reconcileInterruptedDownloads(store: BookStore) async {}
}

private struct PreviewOfflineChapterStore: OfflineChapterStoring {
    func validationState(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?,
        requiresManga: Bool,
        hasBookSource: Bool
    ) async -> OfflineChapterValidation {
        .incomplete
    }

    func persistMangaImages(_ request: OfflineMangaChapterRequest) async throws {
        throw PreviewStubError.unavailable
    }

    func removeBook(bookId: UUID) async throws {}

    func reconcileBook(
        bookId: UUID,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef],
        disposition: OfflineContentDisposition
    ) async throws {}

    func storageByteCount(bookId: UUID?) async -> Int64 {
        guard let bookId else { return 0 }
        // Deterministic per-book size so the rows don't all read "0.0 MB".
        return Int64(abs(bookId.hashValue % 9) + 3) * 4_000_000
    }
}
#endif
