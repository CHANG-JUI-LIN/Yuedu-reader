import Foundation

/// Persists 換源 (in-book source switch) search results per book so reopening the
/// sheet doesn't re-run a full cross-source search every time. Honors
/// 網路設定 →「搜索結果快取天數」(`GlobalSettings.searchCacheDays`): `<= 0` disables
/// the cache, otherwise results within that window are reused.
///
/// Also remembers which origins failed to switch (TOC fetch threw) so the list
/// can flag them — failure flags survive a re-search of the same book.
final class ChangeSourceCache {
    static let shared = ChangeSourceCache()

    struct Entry: Codable {
        var origins: [BookOrigin]
        var failedKeys: [String]
        var timestamp: Date
    }

    private let queue = DispatchQueue(label: "com.yuedu.changeSourceCache")

    private lazy var directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChangeSourceCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func fileURL(for bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }

    /// Raw cached entry (results + failure flags), regardless of freshness.
    func entry(for bookId: UUID) -> Entry? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(for: bookId)) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }

    /// Cached entry only if it exists and is within `days` (days <= 0 = disabled).
    func freshEntry(for bookId: UUID, days: Int) -> Entry? {
        guard days > 0, let entry = entry(for: bookId), !entry.origins.isEmpty else { return nil }
        let maxAge = TimeInterval(days) * 86_400
        guard Date().timeIntervalSince(entry.timestamp) < maxAge else { return nil }
        return entry
    }

    /// Replace the cached origin list, preserving any still-relevant failure flags.
    func store(origins: [BookOrigin], for bookId: UUID) {
        let previousFailed = entry(for: bookId)?.failedKeys ?? []
        let validKeys = Set(origins.map { Self.urlKey($0.bookUrl) })
        let entry = Entry(
            origins: origins,
            failedKeys: previousFailed.filter { validKeys.contains($0) },
            timestamp: Date()
        )
        write(entry, for: bookId)
    }

    /// Flag a book-URL key as having failed to switch.
    func markFailed(bookUrlKey: String, for bookId: UUID) {
        guard !bookUrlKey.isEmpty else { return }
        var entry = self.entry(for: bookId)
            ?? Entry(origins: [], failedKeys: [], timestamp: Date())
        if !entry.failedKeys.contains(bookUrlKey) {
            entry.failedKeys.append(bookUrlKey)
        }
        write(entry, for: bookId)
    }

    func clear(for bookId: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: fileURL(for: bookId)) }
    }

    private func write(_ entry: Entry, for bookId: UUID) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: fileURL(for: bookId), options: .atomic)
        }
    }

    /// Normalized book-URL key for matching origins (drops fragment, lowercased).
    /// Kept identical to `ReaderViewModel`'s dedup key so failure flags line up.
    static func urlKey(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "" }
        if var components = URLComponents(string: trimmed) {
            components.fragment = nil
            return (components.string ?? trimmed).lowercased()
        }
        return trimmed.lowercased()
    }
}
