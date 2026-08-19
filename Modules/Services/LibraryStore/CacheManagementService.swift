import Foundation

enum CacheCategory: String, CaseIterable, Identifiable, Sendable {
    case chapters
    case ttsAudio
    case mangaImages
    case covers
    case diagnostics

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .chapters: return "章節快取"
        case .ttsAudio: return "聽書音頻快取"
        case .mangaImages: return "漫畫圖片快取"
        case .covers: return "封面圖片快取"
        case .diagnostics: return "診斷紀錄"
        }
    }

    var clearTitleKey: String {
        switch self {
        case .chapters: return "清除章節快取"
        case .ttsAudio: return "清除音頻快取"
        case .mangaImages: return "清除漫畫快取"
        case .covers: return "清除封面快取"
        case .diagnostics: return "清除診斷紀錄"
        }
    }

    var detailKey: String {
        switch self {
        case .chapters: return "小說正文內容的離線快取"
        case .ttsAudio: return "TTS 合成的音頻文件快取"
        case .mangaImages: return "漫畫頁面圖片的離線快取"
        case .covers: return "書籍封面圖片的快取"
        case .diagnostics: return "設定 → 診斷與回報 顯示的日誌與崩潰記錄"
        }
    }

    var systemImage: String {
        switch self {
        case .chapters: return "doc.text"
        case .ttsAudio: return "waveform"
        case .mangaImages: return "photo.on.rectangle.angled"
        case .covers: return "photo"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct CacheStorageRoots: Equatable, Sendable {
    var chapters: URL
    var ttsAudio: URL
    var mangaImages: URL
    var covers: URL
    var diagnostics: URL

    static var live: CacheStorageRoots {
        CacheStorageRoots(
            chapters: StorageLocations.onlineCache,
            ttsAudio: StorageLocations.ttsAudioCache,
            mangaImages: StorageLocations.mangaCache,
            covers: StorageLocations.covers,
            diagnostics: StorageLocations.diagnostics
        )
    }

    subscript(category: CacheCategory) -> URL {
        switch category {
        case .chapters: return chapters
        case .ttsAudio: return ttsAudio
        case .mangaImages: return mangaImages
        case .covers: return covers
        case .diagnostics: return diagnostics
        }
    }
}

struct CacheStorageSnapshot: Equatable, Sendable {
    var chapters: Int64 = 0
    var ttsAudio: Int64 = 0
    var mangaImages: Int64 = 0
    var covers: Int64 = 0
    var diagnostics: Int64 = 0

    subscript(category: CacheCategory) -> Int64 {
        switch category {
        case .chapters: return chapters
        case .ttsAudio: return ttsAudio
        case .mangaImages: return mangaImages
        case .covers: return covers
        case .diagnostics: return diagnostics
        }
    }

    var total: Int64 {
        chapters + ttsAudio + mangaImages + covers + diagnostics
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

/// Owns the cache-management use cases exposed by Settings.
///
/// Only app-maintained, re-downloadable artifacts are included here. Imported
/// books, local manga archives, audiobook files, settings, and sync payloads are
/// deliberately outside these roots and are never removed by this service.
final class CacheManagementService: @unchecked Sendable {
    private let fileManager: FileManager
    private let roots: CacheStorageRoots
    /// The live writer behind the diagnostics directory, when there is one. Tests
    /// pass `nil` so clearing stays inside their own fixture instead of reaching
    /// through the singleton to the real device log.
    private let diagnosticLog: DiagnosticLog?

    init(
        fileManager: FileManager = .default,
        roots: CacheStorageRoots = .live,
        diagnosticLog: DiagnosticLog? = .shared
    ) {
        self.fileManager = fileManager
        self.roots = roots
        self.diagnosticLog = diagnosticLog
    }

    func snapshot() -> CacheStorageSnapshot {
        CacheStorageSnapshot(
            chapters: byteCount(in: roots.chapters),
            ttsAudio: byteCount(in: roots.ttsAudio),
            mangaImages: byteCount(in: roots.mangaImages),
            covers: byteCount(in: roots.covers),
            diagnostics: byteCount(in: roots.diagnostics)
        )
    }

    func clear(_ category: CacheCategory) throws {
        // The diagnostics directory has a live writer behind it. Deleting the files
        // from under it would race the batched append; `DiagnosticLog.clear()` does
        // the same work on the queue that owns those files.
        if category == .diagnostics, let diagnosticLog {
            diagnosticLog.clear()
            return
        }
        do {
            try clearDirectory(roots[category])
            if category == .covers {
                BookCoverLoader.clearMemoryCache()
            }
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

    func clearAll() throws {
        for category in CacheCategory.allCases {
            try clear(category)
        }
    }

    private func byteCount(in directory: URL) -> Int64 {
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
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func clearDirectory(_ directory: URL) throws {
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
        for item in contents {
            try fileManager.removeItem(at: item)
        }
    }
}
