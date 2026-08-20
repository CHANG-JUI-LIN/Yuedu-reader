import ActivityKit
import Foundation

/// The payload behind the offline-download Live Activity.
///
/// **This file is duplicated, deliberately.** One copy lives under `Modules/` (the app target)
/// and one under `Widget/` (the widget extension); the two targets use file-system-synchronized
/// groups, so a single file cannot belong to both without editing the project. That costs
/// nothing here: a file shared between an app and its widget extension is compiled into two
/// separate modules anyway, so ActivityKit already has to match these types by their plain
/// name rather than a module-qualified one. What matters is that the **name and the encoded
/// shape stay identical** — change one copy and you must change the other.
///
/// One activity covers every book. The downloader runs up to `maximumConcurrentBooks` at once,
/// so "the book being downloaded" is not a single value, and the system only ever surfaces one
/// Live Activity in the Dynamic Island: an aggregate total with a per-book breakdown in the
/// expanded presentation says more than an arbitrary pick would.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        struct Book: Codable, Hashable, Identifiable, Sendable {
            var id: String
            var title: String
            var completedChapters: Int
            var totalChapters: Int
            var isPaused: Bool
            /// File name inside `DownloadActivityAttributes.coverDirectory()`, or nil when the
            /// book has no cover saved. Never image bytes — see `coverDirectory()`.
            var coverFilename: String?

            var fraction: Double {
                guard totalChapters > 0 else { return 0 }
                return min(1, max(0, Double(completedChapters) / Double(totalChapters)))
            }
        }

        /// Books still downloading, longest-running first. Never empty while the activity is
        /// alive — the controller ends the activity instead of publishing an empty list.
        var books: [Book]

        var completedChapters: Int { books.reduce(0) { $0 + $1.completedChapters } }
        var totalChapters: Int { books.reduce(0) { $0 + $1.totalChapters } }
        var isPaused: Bool { !books.isEmpty && books.allSatisfy(\.isPaused) }

        var fraction: Double {
            guard totalChapters > 0 else { return 0 }
            return min(1, max(0, Double(completedChapters) / Double(totalChapters)))
        }
    }
}

extension DownloadActivityAttributes {
    /// Shared with the widget extension; also used by the share extension's import queue.
    static let appGroupID = "group.com.zhangruilin.yuedureader"

    /// Where the app writes the cover thumbnails the activity shows.
    ///
    /// Covers live in `Application Support/Covers`, inside the app's own container, which the
    /// widget extension cannot read — and `ContentState` cannot carry the bytes instead: the
    /// whole payload has only a few kilobytes of budget. So the app writes one downsampled
    /// JPEG per downloading book into the shared container and the state carries a file name.
    static func coverDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("DownloadActivityCovers", isDirectory: true)
    }

    static func coverURL(filename: String) -> URL? {
        coverDirectory()?.appendingPathComponent(filename)
    }
}
