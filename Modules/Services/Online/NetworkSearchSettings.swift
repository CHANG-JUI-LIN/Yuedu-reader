import Foundation

enum NetworkSearchSettings {
    static func clampedConcurrency(_ value: Int) -> Int {
        min(30, max(1, value))
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
