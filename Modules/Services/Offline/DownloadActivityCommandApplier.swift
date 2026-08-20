import Foundation

/// Applies the pause / resume requests the Live Activity's button recorded.
///
/// The button cannot call the downloader itself — see `ToggleDownloadPauseIntent` for why it
/// writes a request instead. This is the other end: the only place that turns those requests
/// into `OfflineDownloadManaging` calls, so "a request is applied exactly once" lives in one
/// function.
@MainActor
enum DownloadActivityCommandApplier {

    private static var isObserving = false
    /// Held for the Darwin callback, which is a C function pointer and can capture nothing.
    /// Weak on the store so this never becomes the reason the shelf outlives the app session.
    private static weak var observedStore: BookStore?
    private static var observedManager: (any OfflineDownloadManaging)?

    /// Starts reacting to requests posted while the app is running, and drains anything left
    /// from before. Idempotent.
    static func start(store: BookStore, manager: any OfflineDownloadManaging) {
        observedStore = store
        observedManager = manager

        if !isObserving {
            isObserving = true
            // Darwin, not `NotificationCenter`: the request may have been written by the widget
            // extension, which is a different process.
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                // Fully qualified: an unqualified reference would capture the enclosing type,
                // and a C function pointer cannot be formed from a closure that captures.
                { _, _, _, _, _ in
                    Task { @MainActor in
                        await DownloadActivityCommandApplier.drainObserved()
                    }
                },
                DownloadActivityCommandQueue.didChangeNotification as CFString,
                nil,
                .deliverImmediately
            )
        }

        Task { await drain(store: store, manager: manager) }
    }

    /// Drains using whatever `start` last registered. The Darwin callback's only entry point.
    static func drainObserved() async {
        guard let store = observedStore, let manager = observedManager else { return }
        await drain(store: store, manager: manager)
    }

    /// Toggles each requested book. The queue is cleared before anything is applied, so a
    /// request is never applied twice even if two drains overlap.
    static func drain(store: BookStore, manager: any OfflineDownloadManaging) async {
        let requested = DownloadActivityCommandQueue.drain()
        guard !requested.isEmpty else { return }

        for rawId in requested {
            guard let bookId = UUID(uuidString: rawId),
                  let book = store.books.first(where: { $0.id == bookId })
            else { continue }

            let isPaused = book.offlineDownloadTask?.isPaused == true
            AppLogger.cache("⟐ download activity button", context: [
                "bookId": rawId,
                "action": isPaused ? "resume" : "pause",
            ])
            if isPaused {
                await manager.resume(book: book, store: store)
            } else {
                await manager.pause(bookId: bookId, store: store)
            }
        }
    }
}
