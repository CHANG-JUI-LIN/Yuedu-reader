import Foundation

enum CacheCategory: String, CaseIterable, Identifiable, Sendable {
    case chapters
    case ttsAudio
    case mangaImages
    case covers
    case diagnostics
    case remoteBooks
    case exploreHome

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .chapters: return "章節快取"
        case .ttsAudio: return "聽書音頻快取"
        case .mangaImages: return "漫畫圖片快取"
        case .covers: return "封面圖片快取"
        case .diagnostics: return "診斷紀錄"
        case .remoteBooks: return "遠端書籍快取"
        case .exploreHome: return "探索首頁快取"
        }
    }

    var clearTitleKey: String {
        switch self {
        case .chapters: return "清除章節快取"
        case .ttsAudio: return "清除音頻快取"
        case .mangaImages: return "清除漫畫快取"
        case .covers: return "清除封面快取"
        case .diagnostics: return "清除診斷紀錄"
        case .remoteBooks: return "清除遠端書籍快取"
        case .exploreHome: return "清除探索首頁快取"
        }
    }

    var detailKey: String {
        switch self {
        case .chapters: return "小說正文內容的離線快取"
        case .ttsAudio: return "TTS 合成的音頻文件快取"
        case .mangaImages: return "漫畫頁面圖片的離線快取"
        case .covers: return "書籍封面圖片的快取"
        case .diagnostics: return "設定 → 回饋中心 → 診斷紀錄 顯示的日誌與崩潰記錄"
        case .remoteBooks: return "線上閱讀暫存；清除時保留正在閱讀的內容、進度與離線副本"
        case .exploreHome: return "探索首頁各列上次載入的書目，打開探索時先顯示，再於背景更新"
        }
    }

    var systemImage: String {
        switch self {
        case .chapters: return "doc.text"
        case .ttsAudio: return "waveform"
        case .mangaImages: return "photo.on.rectangle.angled"
        case .covers: return "photo"
        case .diagnostics: return "stethoscope"
        case .remoteBooks: return "books.vertical"
        case .exploreHome: return "safari"
        }
    }
}

struct CacheStorageRoots: Equatable, Sendable {
    var chapters: URL
    var ttsAudio: URL
    var mangaImages: URL
    var covers: URL
    /// Network covers saved behind the pipeline's memory. Counted and cleared with
    /// `covers`: to the user both are 封面圖片快取.
    var networkCovers: URL
    var diagnostics: URL
    var remoteBooks: URL
    /// The book-source pages the Explore home last drew (`ForYouCandidateStore`). Counted and
    /// cleared with `homeFeeds`: to the user both are 探索首頁快取.
    var exploreHome: URL
    /// The OPDS, Calibre and Gutenberg rows the Explore home last drew (`HomeFeedPageStore`).
    var homeFeeds: URL
    /// Tables of contents fetched from book sources (`BookSourceFetcher.saveTOCPackage`).
    /// Counted and cleared with `chapters`: to the user both are 章節快取. A shelf book's own
    /// list lives in `BookChapterStore`, so this is only a fetch cache.
    var tableOfContents: URL
    /// Book-detail pages fetched from book sources (`BookSourceFetcher.saveBookInfoPackage`),
    /// counted and cleared with `chapters` like `tableOfContents`.
    var bookInfo: URL

    init(
        chapters: URL,
        ttsAudio: URL,
        mangaImages: URL,
        covers: URL,
        diagnostics: URL,
        remoteBooks: URL? = nil,
        networkCovers: URL? = nil,
        exploreHome: URL? = nil,
        homeFeeds: URL? = nil,
        tableOfContents: URL? = nil,
        bookInfo: URL? = nil
    ) {
        self.chapters = chapters
        self.ttsAudio = ttsAudio
        self.mangaImages = mangaImages
        self.covers = covers
        self.networkCovers = networkCovers ?? chapters.deletingLastPathComponent().appendingPathComponent("NetworkCovers", isDirectory: true)
        self.diagnostics = diagnostics
        self.remoteBooks = remoteBooks ?? chapters.deletingLastPathComponent().appendingPathComponent("RemoteLibrary", isDirectory: true)
        self.exploreHome = exploreHome ?? chapters.deletingLastPathComponent().appendingPathComponent("ForYou", isDirectory: true)
        self.homeFeeds = homeFeeds ?? chapters.deletingLastPathComponent().appendingPathComponent("HomeFeeds", isDirectory: true)
        self.tableOfContents = tableOfContents ?? chapters.deletingLastPathComponent().appendingPathComponent("toc_cache", isDirectory: true)
        self.bookInfo = bookInfo ?? chapters.deletingLastPathComponent().appendingPathComponent("book_info_cache", isDirectory: true)
    }

    static var live: CacheStorageRoots {
        CacheStorageRoots(
            chapters: StorageLocations.onlineCache,
            ttsAudio: StorageLocations.ttsAudioCache,
            mangaImages: StorageLocations.mangaCache,
            covers: StorageLocations.covers,
            diagnostics: StorageLocations.diagnostics,
            remoteBooks: StorageLocations.remoteLibraryCache,
            networkCovers: StorageLocations.networkCoverCache,
            exploreHome: ForYouCandidateStore.shared.directory,
            homeFeeds: HomeFeedPageStore.shared.directory,
            tableOfContents: StorageLocations.tocCache,
            bookInfo: StorageLocations.bookInfoCache
        )
    }

    subscript(category: CacheCategory) -> URL {
        switch category {
        case .chapters: return chapters
        case .ttsAudio: return ttsAudio
        case .mangaImages: return mangaImages
        case .covers: return covers
        case .diagnostics: return diagnostics
        case .remoteBooks: return remoteBooks
        case .exploreHome: return exploreHome
        }
    }
}

struct CacheStorageSnapshot: Equatable, Sendable {
    var chapters: Int64 = 0
    var ttsAudio: Int64 = 0
    var mangaImages: Int64 = 0
    var covers: Int64 = 0
    var diagnostics: Int64 = 0
    var remoteBooks: Int64 = 0
    var exploreHome: Int64 = 0

    subscript(category: CacheCategory) -> Int64 {
        switch category {
        case .chapters: return chapters
        case .ttsAudio: return ttsAudio
        case .mangaImages: return mangaImages
        case .covers: return covers
        case .diagnostics: return diagnostics
        case .remoteBooks: return remoteBooks
        case .exploreHome: return exploreHome
        }
    }

    var total: Int64 {
        chapters + ttsAudio + mangaImages + covers + diagnostics + remoteBooks + exploreHome
    }
}

enum CacheManagementError: LocalizedError, Equatable {
    case clearFailed(category: CacheCategory, message: String)

    var errorDescription: String? {
        switch self {
        case let .clearFailed(category, message):
            return "Unable to clear \(category.rawValue) cache: \(message)"
        }
    }
}

/// The books behind `CacheStorageRoots.covers`. That directory holds the covers books
/// downloaded beside covers nothing can fetch again, an imported book's own artwork among
/// them, so 快取管理 asks the books which files those are before deleting and tells them
/// afterwards. Feedback #116: covers were deleted wholesale while every book kept pointing
/// at its file, and nothing ever fetched one back.
@MainActor
protocol SavedCoverOwner: AnyObject {
    /// Files in `covers` no download brings back; clearing keeps them. Nil while the books
    /// are not all known (an unreadable shelf file): no file can then be shown to be
    /// replaceable, and the directory is left alone.
    func irreplaceableCoverFilenames() -> Set<String>?
    /// `covers` has just been cleared: fetch back the covers books still show.
    func downloadedCoversRemoved()
}

/// Owns the cache-management use cases exposed by Settings.
///
/// Only app-maintained, re-downloadable artifacts are included here. Imported
/// books, local manga archives, audiobook files, settings, and sync payloads are
/// deliberately outside these roots and are never removed by this service.
final class CacheManagementService: @unchecked Sendable {
    private let coverOwner: any SavedCoverOwner
    /// Says which books' caches automatic cleanup keeps (`trimAutomaticCaches`).
    private let retentionOwner: any CacheRetentionOwner
    private let fileManager: FileManager
    private let roots: CacheStorageRoots
    /// The live writer behind the diagnostics directory, when there is one. Tests
    /// pass `nil` so clearing stays inside their own fixture instead of reaching
    /// through the singleton to the real device log.
    private let diagnosticLog: DiagnosticLog?
    private let remoteLibraryCache: RemoteLibraryCache
    /// Told when the downloaded-cover directory is emptied, so no screen keeps
    /// drawing a deleted cover and no load already reading one can put it back.
    private let coverPipeline: CoverImagePipeline

    init(
        coverOwner: any SavedCoverOwner,
        retentionOwner: any CacheRetentionOwner,
        fileManager: FileManager = .default,
        roots: CacheStorageRoots = .live,
        diagnosticLog: DiagnosticLog? = .shared,
        remoteLibraryCache: RemoteLibraryCache? = nil,
        coverPipeline: CoverImagePipeline = .shared
    ) {
        self.coverOwner = coverOwner
        self.retentionOwner = retentionOwner
        self.fileManager = fileManager
        self.roots = roots
        self.diagnosticLog = diagnosticLog
        self.coverPipeline = coverPipeline
        self.remoteLibraryCache = remoteLibraryCache
            ?? (roots.remoteBooks == StorageLocations.remoteLibraryCache ? .shared : RemoteLibraryCache(root: roots.remoteBooks))
    }

    func snapshot() async -> CacheStorageSnapshot {
        let keptCovers = await coverOwner.irreplaceableCoverFilenames()
        return CacheStorageSnapshot(
            chapters: byteCount(in: roots.chapters) + byteCount(in: roots.tableOfContents)
                + byteCount(in: roots.bookInfo),
            ttsAudio: byteCount(in: roots.ttsAudio),
            mangaImages: byteCount(in: roots.mangaImages),
            covers: clearableCoverBytes(keeping: keptCovers) + byteCount(in: roots.networkCovers),
            diagnostics: byteCount(in: roots.diagnostics),
            remoteBooks: byteCount(in: roots.remoteBooks),
            exploreHome: byteCount(in: roots.exploreHome) + byteCount(in: roots.homeFeeds)
        )
    }

    func clear(_ category: CacheCategory) async throws {
        // The diagnostics directory has a live writer behind it. Deleting the files
        // from under it would race the batched append; `DiagnosticLog.clear()` does
        // the same work on the queue that owns those files.
        if category == .diagnostics, let diagnosticLog {
            diagnosticLog.clear()
            return
        }
        do {
            if category == .remoteBooks {
                try remoteLibraryCache.clearInactive()
                return
            }
            if category == .covers {
                try await clearCovers()
                return
            }
            if category == .exploreHome {
                try clearDirectory(roots.exploreHome)
                try clearDirectory(roots.homeFeeds)
                return
            }
            if category == .chapters {
                try clearDirectory(roots.chapters)
                try clearDirectory(roots.tableOfContents)
                try clearDirectory(roots.bookInfo)
                return
            }
            try clearDirectory(roots[category])
        } catch {
            AppLogger.error(
                "CacheManagementService failed to clear \(category.rawValue)",
                error: error
            )
            throw CacheManagementError.clearFailed(
                category: category,
                message: error.localizedDescription
            )
        }
    }

    func clearAll() async throws {
        for category in CacheCategory.allCases {
            try await clear(category)
        }
    }

    /// Deletes every file in `covers` but those the books cannot fetch again, and all of
    /// `networkCovers`; then the books fetch back the covers they show.
    private func clearCovers() async throws {
        let kept = await coverOwner.irreplaceableCoverFilenames()
        if kept == nil {
            AppLogger.cache("⟐ saved covers kept: the shelf did not load completely", level: .notice)
        }
        let deletion = Result {
            if let kept { try clearDirectory(roots.covers, keeping: kept) }
            try clearDirectory(roots.networkCovers)
        }
        // Also when the delete stopped partway: whatever did go must not keep drawing from
        // memory, and the books fetch it back. Told only now, so nothing they fetch back is
        // deleted after.
        coverPipeline.invalidateDownloadedBookCovers()
        await coverOwner.downloadedCoversRemoved()
        try deletion.get()
    }

    /// What clearing `covers` frees, without the files it keeps: a size that stays after
    /// 清除 reads as a broken button.
    private func clearableCoverBytes(keeping kept: Set<String>?) -> Int64 {
        guard let kept else { return 0 }
        return byteCount(in: roots.covers) { !kept.contains($0.lastPathComponent) }
    }

    private func byteCount(in directory: URL, counting isCounted: (URL) -> Bool = { _ in true }) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                ),
                values.isRegularFile == true,
                isCounted(fileURL)
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func clearDirectory(_ directory: URL, keeping kept: Set<String> = []) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in contents where !kept.contains(item.lastPathComponent) {
            try fileManager.removeItem(at: item)
        }
    }
}

// MARK: - Automatic cleanup

/// What one automatic-cleanup pass found and did.
struct CacheTrimReport: Equatable, Sendable {
    /// Bytes cleanup may delete, before the pass.
    var candidateBytes: Int64 = 0
    var removedBytes: Int64 = 0
    var removedCount = 0
    /// False when the books were not all known, so no per-book cache was considered.
    var consideredBooks = false
}

extension CacheManagementService {
    /// Deletes the least recently used re-downloadable caches until they fit `limit`, if they
    /// are over it. Never touched: a book's chapters, manga pages and remote-file caches while
    /// the book is on the shelf and downloaded for offline reading, or open in a reader; saved
    /// book covers (`covers`, which the shelf draws); imported books and reading positions,
    /// which live outside every root listed here. Blocking file work; `CacheAutoCleaner` calls
    /// it off the main thread.
    @discardableResult
    func trimAutomaticCaches(toLimit limit: Int64, reason: String) async -> CacheTrimReport {
        let started = Date()
        let retention = await retentionOwner.cacheRetention()
        let candidates = automaticCleanupCandidates(retention: retention)
        var report = CacheTrimReport(
            candidateBytes: candidates.reduce(0) { $0 + $1.bytes },
            consideredBooks: retention != nil
        )
        if retention == nil {
            AppLogger.cache("⟐ cache cleanup kept every book's chapters: the shelf did not load completely", level: .notice)
        }
        for victim in CacheEvictionPolicy.victims(of: candidates, limit: limit) {
            var removedAll = true
            for item in victim.items {
                do {
                    try fileManager.removeItem(at: item)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue  // Gone since it was listed.
                } catch {
                    removedAll = false
                    AppLogger.cache("⟐ cache cleanup could not remove an item", error: error, context: [
                        "item": item.lastPathComponent,
                    ])
                }
            }
            if removedAll {
                report.removedBytes += victim.bytes
                report.removedCount += 1
            }
        }
        AppLogger.cache("⟐ cache cleanup", context: [
            "reason": reason,
            "limitMB": limit / 1_048_576,
            "candidateMB": report.candidateBytes / 1_048_576,
            "removed": report.removedCount,
            "removedMB": report.removedBytes / 1_048_576,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
        ], level: report.removedCount > 0 ? .notice : .trace)
        return report
    }

    /// Everything automatic cleanup may delete, each with its size and last use.
    func automaticCleanupCandidates(retention: CacheRetention?) -> [CacheEvictionCandidate] {
        var candidates: [CacheEvictionCandidate] = []
        if let retention {
            // A book's chapters (and their illustrations), its manga pages, and the remote
            // file a library book is read from: one candidate per book directory.
            for root in [roots.chapters, roots.mangaImages, roots.remoteBooks] {
                for directory in children(of: root) {
                    guard let bookID = UUID(uuidString: directory.lastPathComponent),
                          !retention.keptBooks.contains(bookID) else { continue }
                    if root == roots.remoteBooks, remoteLibraryCache.isActive(bookID) { continue }
                    guard var candidate = candidate(for: [directory]) else { continue }
                    if let opened = retention.lastOpened[bookID], opened > candidate.lastUsed {
                        candidate.lastUsed = opened
                    }
                    candidates.append(candidate)
                }
            }
        }
        // Saved network covers and synthesized audio: one candidate per file.
        for root in [roots.networkCovers, roots.ttsAudio] {
            for file in children(of: root) {
                if let candidate = candidate(for: [file]) { candidates.append(candidate) }
            }
        }
        // A fetched table of contents or detail page is a few files with one stem
        // (`<key>.json`, `<key>.sha256`, `<key>.raw.html`): one candidate per stem.
        for root in [roots.tableOfContents, roots.bookInfo] {
            let groups = Dictionary(grouping: children(of: root)) { url in
                url.lastPathComponent.split(separator: ".", maxSplits: 1).first.map(String.init) ?? url.lastPathComponent
            }
            for (_, files) in groups.sorted(by: { $0.key < $1.key }) {
                if let candidate = candidate(for: files) { candidates.append(candidate) }
            }
        }
        return candidates
    }

    private func children(of directory: URL) -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []  // Nothing was ever written there, or 快取管理 just removed it.
        } catch {
            AppLogger.cache("⟐ cache cleanup could not list a cache", error: error, context: [
                "directory": directory.lastPathComponent,
            ])
            return []
        }
    }

    /// The size and newest modification of `items` (files, or directories walked whole).
    private func candidate(for items: [URL]) -> CacheEvictionCandidate? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        var bytes: Int64 = 0
        var newest = Date.distantPast
        func add(_ url: URL) -> Bool {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if let modified = values.contentModificationDate, modified > newest { newest = modified }
                if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
                return values.isDirectory == true
            } catch {
                AppLogger.cache("⟐ cache cleanup could not inspect an item", error: error, context: [
                    "item": url.lastPathComponent,
                ])
                return false
            }
        }
        for item in items where add(item) {
            guard let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: Array(keys)) else { continue }
            for case let url as URL in enumerator { _ = add(url) }
        }
        guard newest != .distantPast || bytes > 0 else { return nil }
        return CacheEvictionCandidate(items: items, bytes: bytes, lastUsed: newest)
    }
}
