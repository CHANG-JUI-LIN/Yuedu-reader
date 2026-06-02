import Foundation
import Combine

/// Completes book-source imports that the Share Extension could only *queue*.
///
/// The Share Extension (`ShareViewController`) runs in its own process and cannot
/// touch `BookSourceStore`, so it stashes the shared payload in the App Group's
/// `UserDefaults`:
///   - `shared_book_sources_queue` — an array of raw Legado JSON `Data` blobs
///   - `shared_source_urls_queue`  — an array of book-source URL strings
///
/// and tells the user to "open the reading app to finish importing". This drainer
/// is the missing other half of that handshake: it reads both queues, merges the
/// sources into `BookSourceStore`, clears the queues, and publishes an `Outcome`
/// the UI can surface as a toast.
///
/// Call `drain()` on launch and whenever the app returns to the foreground.
@MainActor
final class SharedImportQueueDrainer: ObservableObject {
    static let shared = SharedImportQueueDrainer()

    nonisolated static let appGroupID = "group.com.zhangruilin.yuedureader"
    nonisolated static let bookSourcesQueueKey = "shared_book_sources_queue"
    nonisolated static let sourceURLsQueueKey = "shared_source_urls_queue"

    /// Result of the most recent non-empty drain, for surfacing user feedback.
    struct Outcome: Equatable {
        var importedCount: Int
        var failureCount: Int
    }

    /// Set after a drain that processed at least one queued item. The UI observes
    /// this to show a toast, then resets it to `nil`.
    @Published var lastOutcome: Outcome?

    private let defaults: UserDefaults?
    private let importData: (Data) throws -> Int
    private let fetchURL: (URL) async throws -> Data
    private var isDraining = false

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedImportQueueDrainer.appGroupID),
        importData: @escaping (Data) throws -> Int = {
            try BookSourceStore.shared.importFromData($0, fileExtension: "json")
        },
        fetchURL: @escaping (URL) async throws -> Data = {
            try await URLSession.shared.data(from: $0).0
        }
    ) {
        self.defaults = defaults
        self.importData = importData
        self.fetchURL = fetchURL
    }

    /// Drain both queues into `BookSourceStore`. Safe to call repeatedly; the
    /// queues are cleared as they're read, and a re-entrancy guard prevents
    /// overlapping runs (e.g. launch + foreground firing back-to-back).
    @discardableResult
    func drain() async -> Outcome {
        guard let defaults, !isDraining else {
            return Outcome(importedCount: 0, failureCount: 0)
        }
        isDraining = true
        defer { isDraining = false }

        var imported = 0
        var failures = 0

        // 1. Raw JSON payloads queued as [Data]. Snapshot-and-clear up front so a
        //    malformed blob can't re-fail on every launch.
        if let jsonQueue = defaults.array(forKey: Self.bookSourcesQueueKey) as? [Data],
           !jsonQueue.isEmpty {
            defaults.removeObject(forKey: Self.bookSourcesQueueKey)
            for data in jsonQueue {
                do {
                    imported += try importData(data)
                } catch {
                    failures += 1
                    AppLogger.error("Shared book-source JSON import failed", error: error)
                }
            }
        }

        // 2. Book-source URLs queued as [String]. Fetch each, then import the
        //    response as Legado JSON (mirrors the in-app network import).
        if let urlQueue = defaults.array(forKey: Self.sourceURLsQueueKey) as? [String],
           !urlQueue.isEmpty {
            defaults.removeObject(forKey: Self.sourceURLsQueueKey)
            for urlString in urlQueue {
                guard let url = URL(string: urlString) else {
                    failures += 1
                    continue
                }
                do {
                    let data = try await fetchURL(url)
                    imported += try importData(data)
                } catch {
                    failures += 1
                    AppLogger.network(
                        "Shared book-source URL import failed",
                        error: error,
                        context: ["url": urlString]
                    )
                }
            }
        }

        let outcome = Outcome(importedCount: imported, failureCount: failures)
        if imported > 0 || failures > 0 {
            lastOutcome = outcome
        }
        return outcome
    }
}
