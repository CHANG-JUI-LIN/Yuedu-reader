import Foundation

/// Where a source script's video link was left (`java.openVideoPlayer`), kept as legado-E keeps
/// it: per link, for 20 days (`video_pos_<url>` in its cache). The key is the whole URL, so a
/// link signed afresh on every call starts from the beginning again, as it does in legado-E.
enum VideoLinkPositions {
    static let storageKey = "video_link_positions"
    static let lifetime: TimeInterval = 20 * 24 * 60 * 60

    struct Entry: Codable, Equatable {
        var time: Double
        var savedAt: Date
    }

    static func time(for url: URL, defaults: UserDefaults = .standard, now: Date = Date()) -> Double? {
        guard let entry = entries(in: defaults)[url.absoluteString],
              now.timeIntervalSince(entry.savedAt) < lifetime else { return nil }
        return entry.time
    }

    /// Saves where the link is; 0 — the start, or a video played to its end — forgets it.
    /// Entries older than `lifetime` go on every save.
    static func save(_ time: Double, for url: URL, defaults: UserDefaults = .standard, now: Date = Date()) {
        var entries = entries(in: defaults).filter { now.timeIntervalSince($0.value.savedAt) < lifetime }
        entries[url.absoluteString] = time > 0 ? Entry(time: time, savedAt: now) : nil
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: storageKey)
        } catch {
            AppLogger.error("[Video] link position not saved", error: error, context: [:])
        }
    }

    private static func entries(in defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            AppLogger.error("[Video] link positions unreadable", error: error, context: [:])
            return [:]
        }
    }
}
