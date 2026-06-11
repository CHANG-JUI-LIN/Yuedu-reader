import Foundation

enum NetworkSearchSettings {
    static let largeSourcePackThreshold = 300
    static let largeSourcePackAutoPauseCount = 10

    static func clampedConcurrency(_ value: Int) -> Int {
        min(30, max(1, value))
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
