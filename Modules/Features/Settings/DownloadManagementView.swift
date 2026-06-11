import SwiftUI

struct DownloadManagementView: View {
    @EnvironmentObject var store: BookStore
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.presentationMode) private var presentationMode

    private var onlineBooks: [ReadingBook] {
        store.books.filter { $0.isOnline }
    }

    private var activeDownloads: [ReadingBook] {
        onlineBooks.filter { book in
            book.offlineDownloadState == .downloading
                || (book.offlineDownloadState == .failed && book.offlineDownloadTask != nil)
        }
    }

    private var downloadedBooks: [ReadingBook] {
        onlineBooks.filter { $0.offlineDownloadState == .available }
    }

    private var totalDownloadedMegabytes: Double {
        onlineBooks.reduce(0) { partial, book in
            partial + cacheSizeMB(for: book)
        }
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
                resumeInterruptedDownloads()
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
                                .font(.body)
                            Spacer()
                            Text(progressLabel(for: book))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(DSColor.textSecondary)
                        }
                        ProgressView(value: downloadProgress(for: book))
                            .tint(.blue)
                        HStack {
                            Text(String(format: "%.1f MB", cacheSizeMB(for: book)))
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                            Spacer()
                            Button(localized("繼續下載")) {
                                resumeDownload(for: book)
                            }
                            .font(DSFont.caption)
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
                            store.clearOnlineDownload(bookId: book.id)
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

    private func resumeInterruptedDownloads() {
        for book in activeDownloads where book.offlineDownloadState == .downloading {
            resumeDownload(for: book)
        }
    }

    private func resumeDownload(for book: ReadingBook) {
        if let task = book.offlineDownloadTask?.clamped(to: chapterTotal(for: book)) {
            OnlineBookCoordinator.shared.downloadBook(
                book,
                store: store,
                startChapterIndex: task.startChapterIndex,
                chapterCount: task.totalChapterCount
            )
        } else {
            OnlineBookCoordinator.shared.downloadBook(book, store: store)
        }
    }

    private func cacheSizeMB(for book: ReadingBook) -> Double {
        let fileManager = FileManager.default
        let cacheDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("online_cache")
            .appendingPathComponent(book.id.uuidString)

        guard let enumerator = fileManager.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
        }
        return Double(totalBytes) / 1_048_576
    }
}
