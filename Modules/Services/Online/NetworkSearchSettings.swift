import Foundation

enum NetworkSearchSettings {
    static let largeSourcePackThreshold = 300
    static let largeSourcePackAutoPauseCount = 10

    static func clampedConcurrency(_ value: Int) -> Int {
        min(30, max(1, value))
    }

    /// Ceiling for offline downloads, which read the same 網路設定 → 並發數 knob as search.
    /// A search spreads its N requests over N different sites; a download aims all N at the
    /// ONE host the book's source lives on, so the same number is far less polite there.
    /// Legado drives both from a single `threadCount` (default 16), but its MD3 fork clamps
    /// the cache path with `maxDownloadConcurrency = 8` — follow that ceiling so raising the
    /// knob for search cannot turn a download into a hammer on a single site.
    static let maximumDownloadConcurrency = 8

    static func clampedDownloadConcurrency(_ value: Int) -> Int {
        min(maximumDownloadConcurrency, max(1, value))
    }

    static func effectiveAutoPauseCount(configured value: Int, sourceCount: Int) -> Int {
        let configured = max(0, value)
        guard configured == 0, sourceCount >= largeSourcePackThreshold else {
            return configured
        }
        return largeSourcePackAutoPauseCount
    }
}

struct SearchAutoPausePolicy {
    let exactThreshold: Int

    init(count: Int) {
        exactThreshold = max(0, count)
    }

    var isEnabled: Bool {
        exactThreshold > 0
    }

    func shouldPause(exactCount: Int, fuzzyCount: Int) -> Bool {
        guard isEnabled else { return false }
        if exactCount >= exactThreshold { return true }
        return fuzzyCount >= exactThreshold * 5
    }
}
