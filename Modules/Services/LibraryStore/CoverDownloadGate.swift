import Foundation

/// Lets at most a given number of cover downloads run at once (網路設定 › 封面並發數);
/// the rest wait their turn, first come first served. A limit of 0 lets every download
/// straight through, as covers always downloaded before the setting.
actor CoverDownloadGate {
    static let shared = CoverDownloadGate()

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once this download may start.
    func enter(limit: Int) async {
        if limit <= 0 || running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        // `leave()` handed its slot straight to this download; `running` already counts it.
    }

    /// Downloads under way and downloads waiting for a slot, for tests to observe.
    var runningCount: Int { running }
    var waitingCount: Int { waiting.count }

    /// Every `enter` is paired with one `leave`, whether the download succeeded or not.
    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
