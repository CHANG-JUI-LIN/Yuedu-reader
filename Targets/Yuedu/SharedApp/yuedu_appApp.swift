import SwiftUI
import GoogleSignIn

@main
struct yuedu_appApp: App {
    @UIApplicationDelegateAdaptor(RSSAppNotificationDelegate.self) private var rssNotificationDelegate
    @StateObject private var bookStore = BookStore()
    @StateObject private var subscriptionStore = SubscriptionStore.shared
    @StateObject private var bookSourceDeepLinkHandler = BookSourceDeepLinkHandler()
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// UI-test hook: imports the Documents-relative EPUB named by
    /// `-auto-import-epub` once (idempotent — skips when already on the shelf).
    @MainActor
    private static func runAutoImportIfNeeded(bookStore: BookStore) async {
        guard let filename = autoImportFilename else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("AUTO-IMPORT file missing: \(url.path)")
            return
        }
        // Skip if already imported (same filename) to keep the shelf stable.
        let exists = bookStore.books.contains { $0.contentFilename == filename }
            || bookStore.books.contains { $0.title.contains("红楼梦") }
        if exists { return }
        do {
            let book = try await bookStore.importEpub(url: url)
            print("AUTO-IMPORT ok: \(book.title)")
        } catch {
            print("AUTO-IMPORT failed: \(error)")
        }
    }

    nonisolated private static var autoImportFilename: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-auto-import-epub"),
              args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }
    #endif

    init() {
        // First statement on purpose: this relocates books_meta.json, book_sources.json,
        // covers and the caches out of the now user-visible Documents directory, and
        // every store below reads from the new locations. A launch that touched a store
        // before this ran would come up with an empty shelf.
        StorageMigration.runIfNeeded()
        #if DEBUG
        // Debug-only engine selection via launch arguments (UI tests / driver).
        // The default is `.legacy` in every build — the browser engine is
        // feature-incomplete and off; these flags are the only way to turn it
        // back on, for development and the browser-layout UI tests.
        //   -browser-mode browserForced | browserAuto | legacy
        //   -browser-overlay 1        (show engine badge + geometry overlay)
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-browser-mode"), args.indices.contains(idx + 1) {
            switch args[idx + 1] {
            case "browserForced": BrowserLayoutFeature.mode = .browserForced
            case "browserAuto": BrowserLayoutFeature.mode = .browserAuto
            default: BrowserLayoutFeature.mode = .legacy
            }
        }
        if args.contains("-browser-overlay") { BrowserLayoutFeature.showDebugOverlay = true }
        // UI-test automation: `-auto-import-epub <filename>` (relative to
        // Documents) imports the book once at launch (see runAutoImportIfNeeded).
        _ = args.contains("-auto-import-epub")
        // Launch banner: confirms the running binary + engine mode + flags.
        BrowserLayoutDeviceDiagnostic.log(
            .launch, spine: -1, generation: -1,
            message: "app commit=\(BrowserLayoutDeviceDiagnostic.commitSHA) build=\(BrowserLayoutDeviceDiagnostic.buildDate) "
                + "mode=\(BrowserLayoutFeature.mode) overlay=\(BrowserLayoutFeature.showDebugOverlay) "
                + "browserEnabled=\(BrowserLayoutFeature.browserEnabled)"
        )
        #endif
        UserFontStorageManager.shared.registerAllOnLaunch()
        GlobalSettings.shared.validateGlobalFontSelection()
        // Must run before any source JS does: a source reads its cached device id
        // straight back out of its own key/value store.
        BookSourceRuntimeStateStore.shared.purgeLegacyAndroidIds()
    }

    /// Presents the book-source import sheet whenever the deep-link handler
    /// is in any non-`.idle` phase. Dismiss is driven by `finish()` /
    /// `cancel()`, which flip back to `.idle` and let SwiftUI animate the sheet
    /// down naturally instead of fighting a separate `isPresented` flag.
    private var bookSourceImportSheetBinding: Binding<Bool> {
        Binding(
            get: { bookSourceDeepLinkHandler.phase != .idle },
            set: { presented in
                if !presented, bookSourceDeepLinkHandler.phase != .idle {
                    bookSourceDeepLinkHandler.finish()
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bookStore)
                .environmentObject(subscriptionStore)
                .environment(\.appDependencies, .live)
                #if DEBUG
                .task {
                    await Self.runAutoImportIfNeeded(bookStore: bookStore)
                }
                #endif
                .onOpenURL { incomingURL in
                    // Google Sign-In OAuth callback: hand off first so a Google
                    // sign-in round-trip completes. `handle(_:)` returns false
                    // for non-Google URLs, in which case we route to book-source
                    // import. Routing one concern per URL keeps a deep link from
                    // accidentally invoking both handlers.
                    if GIDSignIn.sharedInstance.handle(incomingURL) {
                        return
                    }
                    bookSourceDeepLinkHandler.handle(url: incomingURL)
                }
                .sheet(isPresented: bookSourceImportSheetBinding) {
                    BookSourceImportConfirmSheet(handler: bookSourceDeepLinkHandler)
                }
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
                    WebDAVManager.shared.bind(bookStore: bookStore)
                    _ = FirebaseAuthManager.shared
                    Task {
                        await AppDependencies.live.offlineDownloadManager
                            .reconcileInterruptedDownloads(store: bookStore)
                    }
                    Task {
                        await WebFetcher.shared.setCloudflareChallengeHandler { url in
                            try await CloudflareChallengePresenter.present(url: url)
                        }
                        await ChapterUpdater.refreshAll(bookStore: bookStore, auto: true)
                    }
                    // Prime the WebView cookie mirror before the first source request
                    // needs it, so no fetch pays a cold WebKit round trip.
                    WebViewCookieMirror.shared.start()
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
                        Task {
                            await AppDependencies.live.offlineDownloadManager
                                .reconcileInterruptedDownloads(store: bookStore)
                        }
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
                forceInfoRefresh: needInfoRefresh,
                bookSourceFetcher: AppDependencies.live.bookSourceFetcher,
                offlineChapterStore: AppDependencies.live.offlineChapterStore
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
