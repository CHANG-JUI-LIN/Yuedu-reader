import SwiftUI

struct DownloadManagementView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.appDependencies) private var dependencies
    @StateObject private var viewModel = DownloadManagementViewModel()

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
                            if book.offlineDownloadState == .downloading {
                                Button(localized("暫停下載")) {
                                    pauseDownload(for: book)
                                }
                                .font(DSFont.caption)
                            } else {
                                Button(
                                    book.offlineDownloadState == .partial || book.offlineDownloadState == .failed
                                        ? localized("重試失敗章節")
                                        : localized("繼續下載")
                                ) {
                                    resumeDownload(for: book)
                                }
                                .font(DSFont.caption)
                                Button(role: .destructive) {
                                    removeDownload(for: book)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
                        Button(role: .destructive) {
                            removeDownload(for: book)
                        } label: {
                            Text(localized("移除"))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
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
