import BackgroundTasks
import Foundation

/// Foreground and background refresh share the same fetch, merge, and notification path.
@MainActor
enum RSSFeedRefreshService {
    @discardableResult
    static func refreshAll(
        store: RSSStore = .shared,
        makeFetcher: @MainActor () -> RSSFetcher = { RSSFetcher() },
        notify: @MainActor ([RSSArticleRecord], RSSSource) -> Void = {
            RSSNotificationManager.shared.notifyNewArticles($0, source: $1)
        },
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Bool {
        await store.performRefreshBatch {
            await refreshEach(store: store, makeFetcher: makeFetcher, notify: notify, onProgress: onProgress)
        }
    }

    private static func refreshEach(
        store: RSSStore,
        makeFetcher: @MainActor () -> RSSFetcher,
        notify: @MainActor ([RSSArticleRecord], RSSSource) -> Void,
        onProgress: @MainActor (Int, Int) -> Void
    ) async -> Bool {
        let sources = store.sources.filter { $0.enabled && !$0.opensAsWebPage }
        onProgress(0, sources.count)
        var succeeded = true
        for (index, source) in sources.enumerated() {
            guard !Task.isCancelled else { return false }
            // A source may have been removed or disabled while the preceding feed loaded.
            guard let current = store.source(id: source.id), current.enabled else {
                onProgress(index + 1, sources.count)
                continue
            }
            let fetcher = makeFetcher()
            await fetcher.fetchItems(from: current, metadata: store.feedMetadata(for: source.id))
            guard !Task.isCancelled else { return false }
            guard let refreshedSource = store.source(id: source.id), refreshedSource.enabled else {
                onProgress(index + 1, sources.count)
                continue
            }
            if let error = fetcher.error {
                succeeded = false
                AppLogger.network("RSS refresh failed", context: ["source": source.id, "error": error], level: .warning)
            } else {
                store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
                let newArticles: [RSSArticleRecord]
                if let response = fetcher.response {
                    newArticles = store.applyFeedResponse(response, for: source.id)
                } else {
                    newArticles = store.mergeFetchedItems(fetcher.items, for: source.id)
                }
                notify(newArticles, refreshedSource)
            }
            onProgress(index + 1, sources.count)
        }
        return succeeded && !Task.isCancelled
    }
}

@MainActor
final class RSSBackgroundRefresh {
    static let shared = RSSBackgroundRefresh()
    static let identifier = "com.yuedu.rss.feedRefresh"

    private(set) var isRegistered = false

    private init() {}

    /// Called exactly once from didFinishLaunching, before UIKit completes launch.
    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            // The registration above explicitly delivers the callback on the main queue.
            MainActor.assumeIsolated { self.handle(task) }
        }
        if !isRegistered {
            AppLogger.network("RSS background refresh registration failed", level: .error)
        }
    }

    func schedule() {
        guard isRegistered else { return }
        guard RSSStore.shared.sources.contains(where: { $0.enabled && !$0.opensAsWebPage }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.network("Failed to schedule background refresh: \(error.localizedDescription)", level: .warning)
        }
    }

    private func handle(_ task: BGTask) {
        schedule()
        let work = Task {
            let succeeded = await RSSFeedRefreshService.refreshAll()
            task.setTaskCompleted(success: succeeded && !Task.isCancelled)
        }
        // Cancellation reaches URLSession and stops the loop before another feed or write.
        // Only the work task completes BGTask, including the expiration path.
        task.expirationHandler = { work.cancel() }
    }
}
