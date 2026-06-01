import SwiftUI

@main
struct yuedu_appApp: App {
    @UIApplicationDelegateAdaptor(RSSAppNotificationDelegate.self) private var rssNotificationDelegate
    @StateObject private var bookStore = BookStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bookStore)
                .environment(\.appDependencies, .live)
                .onAppear {
                    CoreTextFontRegistrationService.cleanupStaleTemporaryFonts()
                    UserFontStorageManager.shared.registerAllOnLaunch()
                    _ = FirebaseAuthManager.shared
                    FirestoreSyncManager.shared.bind(bookStore: bookStore)
                    Task {
                        await FirestoreSyncManager.shared.syncAfterSignIn()
                        await WebFetcher.shared.setCloudflareChallengeHandler { url in
                            try await CloudflareChallengePresenter.present(url: url)
                        }
                        await ChapterUpdater.refreshAll(bookStore: bookStore)
                    }
                }
        }
    }
}

// MARK: - Auto-Update Latest Chapters

enum ChapterUpdater {
    /// Scans all online books on the bookshelf and refreshes their table of contents (adds new chapters).
    static func refreshAll(bookStore: BookStore) async {
        let onlineBooks = bookStore.books.filter { $0.isOnline }
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
