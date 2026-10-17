import YueduCoreText
import SwiftUI
import GoogleSignIn

@main
struct yuedu_appApp: App {
    @UIApplicationDelegateAdaptor(RSSAppNotificationDelegate.self) private var rssNotificationDelegate
    // The app's own store is the only one that takes over the reading modes older builds
    // kept in UserDefaults, the only one whose removed books leave their names in
    // 搜索's 最近閱讀, and the only one whose opened books feed 為你推薦's genres.
    @StateObject private var bookStore = BookStore(
        legacyReaderSettingsDefaults: .standard,
        offShelfReadRecordsDefaults: .standard,
        readingGenres: .shared
    )
    @StateObject private var subscriptionStore = SubscriptionStore.shared
    @StateObject private var bookSourceDeepLinkHandler = BookSourceDeepLinkHandler()
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// UI-test hook: imports the Documents-relative EPUB named by
    /// `-auto-import-epub` once (idempotent — skips when already on the shelf). An absolute
    /// path is taken as it is: a UI test writes its own book beside it on the simulator.
    @MainActor
    private static func runAutoImportIfNeeded(bookStore: BookStore) async {
        guard let filename = autoImportFilename else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = filename.hasPrefix("/") ? URL(fileURLWithPath: filename) : docs.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("AUTO-IMPORT file missing: \(url.path)")
            return
        }
        // Skip if already imported (same filename) to keep the shelf stable.
        let exists = bookStore.books.contains { $0.contentFilename == filename }
            || bookStore.books.contains { $0.title.contains("红楼梦") }
            || autoImportTitle.map { title in bookStore.books.contains { $0.title == title } } == true
        if exists { return }
        do {
            // The generic importer, not importEpub: the same flag has to seed
            // .cbz manga and .pdf for the screenshot harness, and it already
            // dispatches on the extension.
            let book = try await LocalBookImportService.importBook(
                at: url, title: autoImportTitle, author: autoImportAuthor, store: bookStore)
            print("AUTO-IMPORT ok: \(book.title)")
        } catch {
            print("AUTO-IMPORT failed: \(error)")
        }
    }

    nonisolated private static var autoImportFilename: String? {
        argument(after: "-auto-import-epub")
    }

    /// Comics and PDFs take their title from the filename and leave the author
    /// blank, which reads as "Unknown" on the shelf. These let the harness seed
    /// the real ones.
    nonisolated private static var autoImportTitle: String? { argument(after: "-auto-import-title") }
    nonisolated private static var autoImportAuthor: String? { argument(after: "-auto-import-author") }

    nonisolated private static func argument(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: flag),
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
        // Immediately after the migration and before anything else can log: every
        // `AppLogger` call from here on is captured for 設定 → 診斷與回報, and the
        // session record is what tells the next launch whether this one survived.
        DiagnosticLog.shared.beginSession()
        #if DEBUG
        // Isolate first-install / upgrade UI cases without clearing the reader's books.
        if ProcessInfo.processInfo.arguments.contains("-reset-public-library-explore") {
            UserDefaults.standard.removeObject(forKey: ExploreSettings.modeKey)
        }
        // Reading settings as the launch arguments give them (`-yd_scroll_mode`,
        // `-yd_page_turn_style`, …). Since 排版生效範圍 (2026-09-28) the reader wears the
        // shared and per-theme stores over those keys, so a value an earlier run left there
        // (a scroll-mode test's) would win. Emptied, the next read captures them from the keys.
        if ProcessInfo.processInfo.arguments.contains("-reset-reading-settings") {
            for key in GlobalSettings.readingSettingsStoreKeys + [GlobalSettings.readingSettingSyncRecordsKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // 資源庫's first-launch card, shown again.
        if ProcessInfo.processInfo.arguments.contains("-reset-library-notice") {
            UserDefaults.standard.removeObject(forKey: LibraryTabRoot.noticeDismissedKey)
        }
        // The home as a new install sees it: no saved sections, 範圍 全部, no 聚合設定. Before
        // anything reads `HomePageStore.shared` or `AggregationSettingsStore.shared`.
        if ProcessInfo.processInfo.arguments.contains("-reset-explore-home") {
            for key in [ExploreSettings.scopeKey, AggregationSettingsStore.defaultsKey,
                        ExploreSettings.legacyLandingKey, HomePageStore.forYouInsertedKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            for name in ["explore_home.json", "custom_explore_pages.json"] {
                let file = StorageLocations.applicationSupportRoot.appendingPathComponent(name)
                do {
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                } catch {
                    AppLogger.error("Explore home reset failed: \(error)")
                }
            }
        }
        // AI 推薦 as before its first run (8f): no stored list, so the row offers 產生推薦.
        if ProcessInfo.processInfo.arguments.contains("-reset-ai-recommendations") {
            do {
                if FileManager.default.fileExists(atPath: AIRecommendationStore.directory.path) {
                    try FileManager.default.removeItem(at: AIRecommendationStore.directory)
                }
            } catch {
                AppLogger.error("AI recommendations reset failed: \(error)")
            }
        }
        // A custom page saved before 5d-4, chosen as the old 首屏頁面, for the move into 首頁配置.
        if ProcessInfo.processInfo.arguments.contains("-seed-custom-explore-page") {
            LegacyCustomExplorePages.seedForTesting()
        }
        // A feed with two articles, for 訂閱的最新文章 (unified library 5g).
        if ProcessInfo.processInfo.arguments.contains("-seed-rss-articles") {
            RSSStore.shared.seedForTesting()
        } else {
            RSSStore.shared.removeTestSeed()
        }
        #endif
        // First launch only, and only once the library is read: the read runs off the main
        // thread now, and evaluating `sources` here used to read the whole file inline on
        // every launch just to pass an argument that is ignored after the first.
        BookSourceStore.shared.whenLoaded { library in
            ExploreMode.initializeIfNeeded(hasImportedSources: !library.isEmpty)
        }
        _ = ExploreTabModel.shared
        #if DEBUG
        // UI tests pose as a storefront (`-debug-storefront-country CHN`) instead of reading
        // the App Store's, which the simulator cannot change.
        if let country = UserDefaults.standard.string(forKey: "debug-storefront-country") {
            PublicLibraryAvailability.shared.receive(countryCode: country)
        } else {
            PublicLibraryAvailability.shared.start()
        }
        #else
        PublicLibraryAvailability.shared.start()
        #endif
        // Frees the retired semantic-search model's ~258 MB on devices that had downloaded it.
        Task.detached(priority: .utility) { AIRetiredEmbeddingCleanup.run() }
        #if DEBUG
        // EPUB rollout remains Legacy. The separate Simulator-only interaction
        // hook lives in EPUBPageRenderer; old -browser-mode arguments stay inert.
        let args = ProcessInfo.processInfo.arguments
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
        UserFontStorageManager.shared.removeSupersededCopies(keeping: GlobalSettings.shared.userFonts)
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
            get: { TestFlightAccessController.shared.state.allowsUse && bookSourceDeepLinkHandler.phase != .idle },
            set: { presented in
                if !presented, bookSourceDeepLinkHandler.phase != .idle {
                    bookSourceDeepLinkHandler.finish()
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-continuous-scroll-gesture-test") {
                    ContinuousScrollGestureFixture()
                } else if ProcessInfo.processInfo.arguments.contains(AIChatDesignFixture.launchArgument) {
                    AIChatDesignFixture()
                } else if ProcessInfo.processInfo.arguments.contains(HomeDesignFixture.launchArgument) {
                    HomeDesignFixture()
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                .environmentObject(bookStore)
                .environment(bookStore.filledCovers)
                .environmentObject(subscriptionStore)
                .environment(\.appDependencies, .live)
                #if DEBUG
                .task {
                    await Self.runAutoImportIfNeeded(bookStore: bookStore)
                }
                #endif
                .onOpenURL { incomingURL in
                    if incomingURL.isFileURL {
                        guard TestFlightAccessController.shared.state.allowsUse else { return }
                        let importer = SharedImportQueueDrainer.shared
                        // A cold-launch URL may arrive before onAppear binds stores.
                        importer.bind(bookStore: bookStore)
                        Task { await importer.openFile(incomingURL) }
                        return
                    }
                    // Google Sign-In OAuth callback: hand off first so a Google
                    // sign-in round-trip completes. `handle(_:)` returns false
                    // for non-Google URLs, in which case we route to book-source
                    // import. Routing one concern per URL keeps a deep link from
                    // accidentally invoking both handlers.
                    if GIDSignIn.sharedInstance.handle(incomingURL) {
                        return
                    }
                    guard TestFlightAccessController.shared.state.allowsUse else { return }
                    if case .module(let address) = BookSourceImportDeepLink.target(from: incomingURL) {
                        RuleModuleLinkPresenter.present(address)
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
                    DiagnosticScale.publish(bookStore: bookStore, reason: "launch")
                    _ = FirebaseAuthManager.shared
                    Task {
                        await AppDependencies.live.offlineDownloadManager
                            .reconcileInterruptedDownloads(store: bookStore)
                    }
                    // Before anything runs a source: `java.startBrowser(Await)` opens its page
                    // through this from any script — search, a chapter, 書源驗證.
                    SourceBrowserPresenter.install()
                    // `.utility`: this walks every online book's table of contents through
                    // its source's bridge, and a chapter the reader opens meanwhile must
                    // not wait behind it (`BookSourceSession.withBridge`).
                    Task(priority: .utility) {
                        await ChapterUpdater.refreshAll(bookStore: bookStore, auto: true)
                    }
                    // Prime the WebView cookie mirror before the first source request
                    // needs it, so no fetch pays a cold WebKit round trip.
                    WebViewCookieMirror.shared.start()
                    // Finish any book-source imports the Share Extension queued
                    // (it can only stash the payload; the merge must happen here).
                    Task { await SharedImportQueueDrainer.shared.drain() }
                    // The download Live Activity's pause button records a request rather than
                    // calling the downloader; this is the end that applies it.
                    DownloadActivityCommandApplier.start(
                        store: bookStore,
                        manager: AppDependencies.live.offlineDownloadManager
                    )
                    #if DEBUG
                    DownloadActivityDebugHarness.startIfRequested()
                    #endif
                    // Unified library 2d: WebDAV libraries index in the foreground, on Wi-Fi.
                    NetworkPathMonitor.shared.start()
                    // The phase is set here, now, and by every change below; never after the
                    // attach below, which awaits and would overwrite a newer phase with this one.
                    WebDAVIndexCoordinator.shared.setActive(scenePhase == .active)
                    Task { await WebDAVIndexCoordinator.shared.attach(store: bookStore.remoteRecords) }
                    // Unified library 3d: empty covers and descriptions fill in the foreground, on Wi-Fi.
                    bookStore.metadataFill.setActive(scenePhase == .active)
                    // Seamless iCloud: merge with the cloud on launch.
                    if GlobalSettings.shared.iCloudAutoSync {
                        Task { try? await ICloudSyncManager.shared.sync(reason: "launch") }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    MainThreadMonitor.shared.notePhase(String(describing: newPhase))
                    WebDAVIndexCoordinator.shared.setActive(newPhase == .active)
                    bookStore.metadataFill.setActive(newPhase == .active)
                    // Diagnostics session bookkeeping: reaching the background is
                    // this app's definition of "survived", and is also the last
                    // reliable moment to get buffered log lines onto disk.
                    switch newPhase {
                    case .background:
                        DiagnosticLog.shared.noteEnteredBackground()
                        BookSourceStore.shared.flushPendingWrites()
                        DiagnosticScale.publish(bookStore: bookStore, reason: "background")
                    case .active: DiagnosticLog.shared.noteBecameActive()
                    default: break
                    }
                    // Inactive, not only background: the app switcher kills the app
                    // while it is inactive, before a debounced shelf save has run.
                    if newPhase != .active { bookStore.flushPendingMetadataSave() }
                    // Pick up sources shared while the app was backgrounded.
                    if newPhase == .active {
                        Task { await subscriptionStore.refreshAllEntitlements() }
                        Task { await subscriptionStore.reloadProductsIfStorefrontChanged() }
                        Task { await SharedImportQueueDrainer.shared.drain() }
                        // A button tap while the app was suspended is waiting in the queue.
                        Task { await DownloadActivityCommandApplier.drainObserved() }
                        Task {
                            await AppDependencies.live.offlineDownloadManager
                                .reconcileInterruptedDownloads(store: bookStore)
                        }
                        // Returning to the foreground also checks online books for
                        // new chapters (throttled). Cold launch already kicked one
                        // off in onAppear; the throttle skips the duplicate.
                        Task(priority: .utility) {
                            await ChapterUpdater.refreshAll(bookStore: bookStore, auto: true)
                        }
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

/// When the last automatic "check for new chapters" ran, kept across launches.
///
/// It used to be a static in memory, so every cold launch re-walked every online book's
/// table of contents however recently the last launch had — the field timeline showed two
/// full refreshes (and two 90 s CPU exceptions) seven minutes apart, one per launch.
struct AutoRefreshThrottle {
    static let defaultsKey = "yd_last_auto_chapter_refresh"
    let defaults: UserDefaults
    let minimumInterval: TimeInterval

    /// True, and records `now`, when the last refresh is older than the interval. A stored
    /// time in the future (the clock was moved back) does not block refreshing forever.
    func consume(now: Date = Date()) -> Bool {
        if let last = defaults.object(forKey: Self.defaultsKey) as? Date,
           last <= now, now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        defaults.set(now, forKey: Self.defaultsKey)
        return true
    }
}

enum ChapterUpdater {
    /// Returns true (and records the time) when an automatic refresh is allowed
    /// under the throttle window; false when one ran too recently. Manual
    /// pull-to-refresh bypasses it.
    @MainActor private static func consumeAutoRefreshAllowance() -> Bool {
        AutoRefreshThrottle(defaults: .standard, minimumInterval: AppConfig.autoRefreshMinInterval).consume()
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

        // Every refreshed book looks its source up on the main thread; wait for the library
        // read here, off it, rather than there.
        await BookSourceStore.shared.waitUntilLoaded()
        let onlineBooks = await MainActor.run { bookStore.books.filter { $0.isOnline } }
        guard !onlineBooks.isEmpty else { return }
        // Bracketed in the Crashlytics log: a hang, CPU or disk-write report that arrives
        // during or after it shows the refresh was running and how big it was.
        let started = SourcePerfTrace.now
        CrashContext.breadcrumb("refresh.all start books=\(onlineBooks.count) auto=\(auto)")
        defer {
            CrashContext.breadcrumb(
                "refresh.all end books=\(onlineBooks.count) ms=\(Int((SourcePerfTrace.now - started) * 1000))"
            )
        }

        // legado-E / MD3: each listening source among the refreshed books hears the refresh start
        // and end (`SourceCallBack.START_SHELF_REFRESH` / `END_SHELF_REFRESH`).
        await MainActor.run { SourceCallBackService.notifyShelfRefresh(.startShelfRefresh, books: onlineBooks) }

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
        await MainActor.run { SourceCallBackService.notifyShelfRefresh(.endShelfRefresh, books: onlineBooks) }
    }

    private static func refreshBook(book: ReadingBook, bookStore: BookStore) async {
        do {
            let needInfoRefresh = (book.tocURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || (book.totalChapterNum ?? 0) == 0
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
