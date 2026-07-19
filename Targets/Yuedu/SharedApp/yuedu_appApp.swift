import SwiftUI

@main
struct yuedu_appApp: App {
    @UIApplicationDelegateAdaptor(RSSAppNotificationDelegate.self) private var rssNotificationDelegate
    @StateObject private var bookStore = BookStore()
    @StateObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserFontStorageManager.shared.registerAllOnLaunch()
        GlobalSettings.shared.validateGlobalFontSelection()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bookStore)
                .environmentObject(subscriptionStore)
                .environment(\.appDependencies, .live)
                .onAppear {
                    CoreTextFontRegistrationService.cleanupStaleTemporaryFonts()
                    // Remove the retired discover-page cache directory written by
                    // earlier test builds; nothing reads it anymore. No-op once gone.
                    Task.detached(priority: .background) {
                        let dir = FileManager.default
                            .urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("discover_cache")
                        try? FileManager.default.removeItem(at: dir)
                    }
                    // Bind the book store before the auth listener fires, so the
                    // first post-launch sync (triggered by the listener) sees it.
                    FirestoreSyncManager.shared.bind(bookStore: bookStore)
                    ICloudSyncManager.shared.bind(bookStore: bookStore)
                    SharedImportQueueDrainer.shared.bind(bookStore: bookStore)
                    _ = FirebaseAuthManager.shared
                    Task {
                        await WebFetcher.shared.setCloudflareChallengeHandler { url in
                            try await CloudflareChallengePresenter.present(url: url)
                        }
                        await ChapterUpdater.refreshAll(bookStore: bookStore, auto: true)
                    }
                    // Finish any book-source imports the Share Extension queued
                    // (it can only stash the payload; the merge must happen here).
                    Task { await SharedImportQueueDrainer.shared.drain() }
                    // Seamless iCloud: merge with the cloud on launch.
                    if GlobalSettings.shared.iCloudAutoSync {
                        Task { try? await ICloudSyncManager.shared.sync(reason: "launch") }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Pick up sources shared while the app was backgrounded.
                    if newPhase == .active {
                        Task { await subscriptionStore.refreshAllEntitlements() }
                        Task { await SharedImportQueueDrainer.shared.drain() }
                        // Returning to the foreground also checks online books for
                        // new chapters (throttled). Cold launch already kicked one
                        // off in onAppear; the throttle skips the duplicate.
                        Task { await ChapterUpdater.refreshAll(bookStore: bookStore, auto: true) }
                    }
                    // Seamless iCloud: push/merge when leaving the app.
                    if newPhase == .background, GlobalSettings.shared.iCloudAutoSync {
                        Task { try? await ICloudSyncManager.shared.sync(reason: "background") }
                    }
                }
        }
    }
}

// MARK: - Auto-Update Latest Chapters

enum ChapterUpdater {
    /// Timestamp of the last automatic refresh, used to throttle launch /
    /// foreground refreshes. Manual pull-to-refresh bypasses it. Main-actor
    /// isolated for Swift 6 concurrency safety.
    @MainActor private static var lastAutoRefresh: Date?

    /// Returns true (and records the time) when an automatic refresh is allowed
    /// under the throttle window; false when one ran too recently.
    @MainActor private static func consumeAutoRefreshAllowance() -> Bool {
        let now = Date()
        if let last = lastAutoRefresh, now.timeIntervalSince(last) < AppConfig.autoRefreshMinInterval {
            return false
        }
        lastAutoRefresh = now
        return true
    }

    /// Scans all online books on the bookshelf and refreshes their table of contents (adds new chapters).
    /// - Parameter auto: `true` for launch / foreground refreshes (throttled by
    ///   `AppConfig.autoRefreshMinInterval`); `false` for explicit pull-to-refresh,
    ///   which always runs.
    static func refreshAll(bookStore: BookStore, auto: Bool = false) async {
        if auto {
            let allowed = await MainActor.run { consumeAutoRefreshAllowance() }
            guard allowed else { return }
        }

        let onlineBooks = await MainActor.run { bookStore.books.filter { $0.isOnline } }
        guard !onlineBooks.isEmpty else { return }

        let maxConcurrentTasks = AppConfig.startupRefreshMaxConcurrentTasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<min(maxConcurrentTasks, onlineBooks.count) {
                group.addTask {
                    await refreshBook(book: onlineBooks[i], bookStore: bookStore)
                }
            }
            
            var index = maxConcurrentTasks
            for await _ in group {
                if index < onlineBooks.count {
                    let nextBook = onlineBooks[index]
                    group.addTask {
                        await refreshBook(book: nextBook, bookStore: bookStore)
                    }
                    index += 1
                }
            }
        }
    }

    private static func refreshBook(book: ReadingBook, bookStore: BookStore) async {
        do {
            let needInfoRefresh = (book.tocURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || (book.onlineChapters?.isEmpty != false)
            _ = try await bookStore.refreshOnlineBookMetadata(
                bookId: book.id,
                forceInfoRefresh: needInfoRefresh
            )
        } catch {
            AppLogger.network(
                "Failed to auto-update book TOC",
                error: error,
                context: ["bookId": book.id.uuidString, "title": book.title]
            )
        }
    }
}
