import Foundation
import os

/// How many times, and how many bytes, each of the app's whole-file writers has written in
/// this process — so a MetricKit disk-write exception names the caller, not only the frame.
///
/// 3.0.0 (143) reported two of them, each a gigabyte in 24 hours: one sampled in
/// `BookSourceStore.writeLibraryJSON`, one in `ICloudSyncManager.uploadData`. Both writers
/// rewrite a whole file every time, so the gigabyte was a count of calls, and nothing said
/// which caller made them. Each write here leaves a Crashlytics breadcrumb naming its reason
/// and the running total, and keeps the total in a custom key (`disk_<writer>`), which the
/// next MetricKit report carries alongside its `scale_*` keys.
enum DiskWriteTally {
    struct Total: Equatable {
        var count = 0
        var bytes = 0
    }

    private static let totals = OSAllocatedUnfairLock(initialState: [String: Total]())

    /// One write of `bytes` by `writer`, for `reason`.
    static func record(_ writer: String, reason: String, bytes: Int) {
        let total = totals.withLock { totals -> Total in
            totals[writer, default: Total()].count += 1
            totals[writer, default: Total()].bytes += bytes
            return totals[writer, default: Total()]
        }
        let megabytes = String(format: "%.1f", Double(total.bytes) / 1_048_576)
        let line = "⟐ diskwrite \(writer) reason=\(reason) bytes=\(bytes) · this process n=\(total.count) \(megabytes) MB"
        AppLogger.cache(line, level: .notice)
        CrashContext.breadcrumb(line)
        CrashContext.setKey("disk_\(writer)", "n=\(total.count) mb=\(megabytes) last=\(reason)")
    }

    /// What `writer` has written so far in this process.
    static func total(_ writer: String) -> Total {
        totals.withLock { $0[writer, default: Total()] }
    }
}
