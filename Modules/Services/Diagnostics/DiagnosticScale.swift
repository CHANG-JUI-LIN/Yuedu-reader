import Foundation
import os

/// How much data this install carries — attached to every Crashlytics report and logged once
/// per launch and per trip to the background.
///
/// The app's cost grows with the user's data: online books × table-of-contents length, book
/// sources, downloaded books. The developer's own install is small, which is why hangs that
/// some users hit on every launch never reproduced. With these keys a Crashlytics issue can
/// be filtered by scale, and a hang report says whether it came from a 20-book or a 400-book
/// shelf.
enum DiagnosticScale {
    private static let summary = OSAllocatedUnfairLock(initialState: "")

    /// The last published line, for a report the user sends.
    static var lastSummary: String { summary.withLock { $0 } }
    struct Counts: Equatable, Sendable {
        var shelfBooks = 0
        var onlineBooks = 0
        var downloadedBooks = 0
        var readingRecords = 0
        var bookSources = 0
        var rssSources = 0
        var iCloudAutoSync = false
    }

    /// Counts are taken on the main thread (the stores live there; each is one pass); the
    /// directory sizes are measured off it.
    @MainActor
    static func publish(bookStore: BookStore, reason: String) {
        let shelf = bookStore.books
        let counts = Counts(
            shelfBooks: shelf.count,
            onlineBooks: shelf.reduce(0) { $0 + ($1.isOnline ? 1 : 0) },
            downloadedBooks: shelf.reduce(0) { $0 + ($1.offlineDownloadTask != nil ? 1 : 0) },
            readingRecords: bookStore.readingBooks.count - shelf.count,
            bookSources: BookSourceStore.shared.sources.count,
            rssSources: RSSStore.shared.sources.count,
            iCloudAutoSync: GlobalSettings.shared.iCloudAutoSync
        )
        let shelfFile = BookStore.booksMetaFileURL
        Task.detached(priority: .utility) {
            let chapterLists = shelfFile.deletingPathExtension().appendingPathExtension("chapters")
            let tocBytes = directoryBytes(chapterLists)
            let shelfBytes = fileBytes(shelfFile)
            let sourceBytes = fileBytes(StorageLocations.bookSourcesFile)
            CrashContext.setKey("scale_shelf_books", counts.shelfBooks)
            CrashContext.setKey("scale_online_books", counts.onlineBooks)
            CrashContext.setKey("scale_downloaded_books", counts.downloadedBooks)
            CrashContext.setKey("scale_reading_records", counts.readingRecords)
            CrashContext.setKey("scale_book_sources", counts.bookSources)
            CrashContext.setKey("scale_rss_sources", counts.rssSources)
            CrashContext.setKey("scale_toc_mb", Int(tocBytes / 1_048_576))
            CrashContext.setKey("scale_shelf_file_kb", Int(shelfBytes / 1024))
            CrashContext.setKey("scale_sources_file_mb", Int(sourceBytes / 1_048_576))
            CrashContext.setKey("icloud_auto_sync", counts.iCloudAutoSync)
            let line = "shelf=\(counts.shelfBooks) online=\(counts.onlineBooks) "
                + "downloaded=\(counts.downloadedBooks) reading=\(counts.readingRecords) "
                + "sources=\(counts.bookSources) rss=\(counts.rssSources) "
                + "tocMB=\(tocBytes / 1_048_576) shelfKB=\(shelfBytes / 1024) sourcesMB=\(sourceBytes / 1_048_576) "
                + "iCloud=\(counts.iCloudAutoSync)"
            summary.withLock { $0 = line }
            AppLogger.info("⟐ scale (\(reason)): \(line)", level: .notice)
        }
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            AppLogger.cache("Scale: file size unreadable", error: error, context: ["file": url.lastPathComponent])
            return 0
        }
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            do {
                total += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            } catch {
                AppLogger.cache("Scale: file size unreadable", error: error, context: ["file": file.lastPathComponent])
            }
        }
        return total
    }
}
