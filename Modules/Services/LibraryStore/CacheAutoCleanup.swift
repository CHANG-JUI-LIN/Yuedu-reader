import Foundation
import os

// Automatic cache cleanup (feedback #47, #129).
//
// Until 2026-11 the app's caches only shrank when the user opened 設定 → 快取管理 and pressed
// 清除: nothing had a size cap, and the chapter cache lives in Application Support, which iOS
// never purges. #129 reported 3.65 GB of 文稿與數據 on 3.0.0 (143) with only a few MB of
// imported books. This file is the one place that decides what may be deleted to keep the
// caches under a size cap, oldest use first; `CacheManagementService` lists the candidates and
// deletes them, and `CacheAutoCleaner` decides when.

/// One thing automatic cleanup deletes as a whole: a book's chapter directory, a cached table
/// of contents with its fingerprint, a saved cover.
struct CacheEvictionCandidate: Equatable, Sendable {
    /// Removed together; a book's chapters are useless without its directory's other files.
    var items: [URL]
    var bytes: Int64
    /// The last time anything used it: its newest file, or the book's last opening when that
    /// is later (reading a chapter from the cache rewrites nothing).
    var lastUsed: Date
}

/// Least-recently-used eviction under a size cap.
enum CacheEvictionPolicy {
    /// A pass trims to this share of the cap, so the writes right after it do not start
    /// another one. The same four fifths the network-cover cache trimmed to before it was
    /// folded in here.
    static let targetNumerator: Int64 = 4
    static let targetDenominator: Int64 = 5

    /// What to delete so `candidates` fit `limit`: nothing while they already fit; otherwise
    /// the least recently used first, until what is left fits four fifths of `limit`.
    static func victims(of candidates: [CacheEvictionCandidate], limit: Int64) -> [CacheEvictionCandidate] {
        var total = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return [] }
        let target = limit / targetDenominator * targetNumerator
        var victims: [CacheEvictionCandidate] = []
        // Ties (same timestamp) break on the path, so a pass is deterministic.
        let ordered = candidates.sorted {
            $0.lastUsed != $1.lastUsed
                ? $0.lastUsed < $1.lastUsed
                : ($0.items.first?.path ?? "") < ($1.items.first?.path ?? "")
        }
        for candidate in ordered {
            guard total > target else { break }
            victims.append(candidate)
            total -= candidate.bytes
        }
        return victims
    }
}

/// What the books say automatic cleanup must keep.
struct CacheRetention: Equatable, Sendable {
    /// Books whose chapters, manga pages and remote-file caches are never deleted
    /// automatically: on the shelf and downloaded (or being downloaded) for offline reading,
    /// or open in a reader right now.
    var keptBooks: Set<UUID>
    /// When each known book was last opened, on the shelf or off it.
    var lastOpened: [UUID: Date]
}

/// The books behind the per-book caches (`BookStore`).
@MainActor
protocol CacheRetentionOwner: AnyObject {
    /// Nil while the books are not all known (an unreadable shelf file): no book's chapters can
    /// then be shown to be unwanted, and cleanup leaves every per-book cache alone.
    func cacheRetention() -> CacheRetention?
}

/// The cap the user picked in 設定 → 快取管理, stored on this device only: it is about this
/// device's storage, so it is not part of the settings that sync.
enum CacheAutoCleanupLimit {
    static let defaultsKey = "yd_cache_auto_cleanup_limit_mb"
    /// The choices 快取管理 offers, in MB.
    static let optionsMB = [512, 1024, 2048, 5120]
    /// Maintainer, 2026-11-10.
    static let defaultMB = 1024

    static func megabytes(in defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: defaultsKey)
        return optionsMB.contains(stored) ? stored : defaultMB
    }

    static func bytes(in defaults: UserDefaults = .standard) -> Int64 {
        Int64(megabytes(in: defaults)) * 1024 * 1024
    }
}

/// Decides when caches are trimmed: once at launch, when the cap is lowered, and each time
/// the caches' writers have added `checkInterval` bytes since the last check. A check lists
/// the caches (`CacheManagementService.trimAutomaticCaches`) on a background task and deletes
/// only when they are over the cap; there are no timers.
final class CacheAutoCleaner: @unchecked Sendable {
    static let shared = CacheAutoCleaner()

    /// Bytes written between checks. Listing the caches costs a directory walk; a chapter
    /// read online takes ~70 KB on disk (measured 2026-11-10: 4–13 KB of text, 14 KB of
    /// rebuilt XHTML, 33–46 KB of the page's raw HTML), so this is a check every ~450
    /// chapters or a few hundred covers.
    static let checkInterval: Int64 = 32 * 1024 * 1024

    private struct State {
        var service: CacheManagementService?
        /// Starts at the interval, so the first write of a launch checks if launch did not.
        var bytesSinceCheck: Int64 = CacheAutoCleaner.checkInterval
        var isChecking = false
        /// A check was asked for while one ran: run one more when it ends.
        var checkPending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The cap, read at each check so a change in 快取管理 applies to the next one.
    private let limitBytes: @Sendable () -> Int64

    init(limitBytes: @escaping @Sendable () -> Int64 = { CacheAutoCleanupLimit.bytes() }) {
        self.limitBytes = limitBytes
    }

    /// The service a check runs; until one is bound, writes are only counted.
    func bind(_ service: CacheManagementService) {
        state.withLock { $0.service = service }
    }

    /// A cache writer saved `bytes`. Starts a check once enough has been written, and
    /// returns its task.
    @discardableResult
    func noteWrite(bytes: Int) -> Task<Void, Never>? {
        guard bytes > 0 else { return nil }
        let due = state.withLock { state -> Bool in
            state.bytesSinceCheck += Int64(bytes)
            return state.bytesSinceCheck >= Self.checkInterval && state.service != nil
        }
        return due ? requestCheck(reason: "writes") : nil
    }

    /// Checks now, off the caller's thread: at launch, and when the cap changes. Returns the
    /// check's task, or nil when none was started (nothing bound, or one already running,
    /// which then runs once more when it ends).
    @discardableResult
    func requestCheck(reason: String) -> Task<Void, Never>? {
        let service = state.withLock { state -> CacheManagementService? in
            guard let service = state.service else { return nil }
            state.bytesSinceCheck = 0
            if state.isChecking {
                state.checkPending = true
                return nil
            }
            state.isChecking = true
            return service
        }
        guard let service else { return nil }
        return Task.detached(priority: .utility) { [self] in
            await runChecks(service: service, reason: reason)
        }
    }

    /// Runs one check, then another for each request that arrived meanwhile.
    func runChecks(service: CacheManagementService, reason: String) async {
        var reason = reason
        while true {
            await service.trimAutomaticCaches(toLimit: limitBytes(), reason: reason)
            let again = state.withLock { state -> Bool in
                guard state.checkPending else {
                    state.isChecking = false
                    return false
                }
                state.checkPending = false
                return true
            }
            guard again else { return }
            reason = "pending"
        }
    }
}
