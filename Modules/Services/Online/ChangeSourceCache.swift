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
        /// True only when every source answered or timed out. A search cut short by
        /// 自動暫停 is kept (so its failure flags survive) but never served as the book's
        /// list. Optional so entries written before this field decode as `nil` = not
        /// known complete: those include the 10-result lists the hidden large-pack pause
        /// cached for 5 days (feedback #16), which must be searched again once.
        var isComplete: Bool?
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

    /// Cached entry only if it exists, is a complete search, and is within `days`
    /// (days <= 0 = disabled).
    func freshEntry(for bookId: UUID, days: Int) -> Entry? {
        guard days > 0, let entry = entry(for: bookId), entry.isComplete == true,
              !entry.origins.isEmpty else { return nil }
        let maxAge = TimeInterval(days) * 86_400
        guard Date().timeIntervalSince(entry.timestamp) < maxAge else { return nil }
        return entry
    }

    /// Replace the cached origin list, preserving any still-relevant failure flags.
    ///
    /// `isComplete: false` (a paused search) keeps every previous failure flag: an origin
    /// missing from a partial list may simply not have been reached.
    func store(origins: [BookOrigin], for bookId: UUID, isComplete: Bool = true) {
        let previousFailed = entry(for: bookId)?.failedKeys ?? []
        // Keep the legacy URL-only key readable so caches written before source
        // identity was added do not silently lose their failure markers.
        let validKeys = Set(origins.flatMap { origin in
            [Self.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl),
             Self.urlKey(origin.bookUrl)]
        })
        let entry = Entry(
            origins: origins,
            failedKeys: isComplete ? previousFailed.filter { validKeys.contains($0) } : previousFailed,
            timestamp: Date(),
            isComplete: isComplete
        )
        write(entry, for: bookId)
    }

    /// Flag a source-qualified origin key as having failed to switch.
    func markFailed(originKey: String, for bookId: UUID) {
        guard !originKey.isEmpty else { return }
        var entry = self.entry(for: bookId)
            ?? Entry(origins: [], failedKeys: [], timestamp: Date(), isComplete: false)
        if !entry.failedKeys.contains(originKey) {
            entry.failedKeys.append(originKey)
        }
        write(entry, for: bookId)
    }

    /// Clear a failure flag after that origin switched successfully. Without this a source
    /// that failed once stayed badged 載入失敗 forever, including in every later session,
    /// because `markFailed` only ever appended.
    func clearFailure(originKeys: [String], for bookId: UUID) {
        let keys = Set(originKeys.filter { !$0.isEmpty })
        guard !keys.isEmpty, var entry = self.entry(for: bookId) else { return }
        let remaining = entry.failedKeys.filter { !keys.contains($0) }
        guard remaining.count != entry.failedKeys.count else { return }
        entry.failedKeys = remaining
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

    /// Source-qualified origin identity. Two sources may intentionally return
    /// the same detail URL, so URL-only keys would merge their failure state and
    /// hide one of the switchable origins.
    static func originKey(sourceId: UUID, bookUrl: String?) -> String {
        let url = urlKey(bookUrl)
        let sourceKey = sourceId.uuidString.lowercased()
        guard !url.isEmpty else { return sourceKey + "|" }
        return sourceKey + "|" + url
    }
}
