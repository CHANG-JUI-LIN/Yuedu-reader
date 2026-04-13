import SwiftUI

@main
struct yuedu_appApp: App {
    @StateObject private var bookStore = BookStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bookStore)
                .environment(\.appDependencies, .live)
                .onAppear {
                    CoreTextFontRegistrationService.cleanupStaleTemporaryFonts()
                    Task {
                        await WebFetcher.shared.setCloudflareChallengeHandler { url in
                            try await CloudflareChallengePresenter.present(url: url)
                        }
                        // App 啟動時自動更新線上書籍目錄
                        await ChapterUpdater.refreshAll(bookStore: bookStore)
                    }
                }
        }
    }
}

// MARK: - 自動更新最新章節

enum ChapterUpdater {
    /// 掃描書架所有線上書籍，刷新目錄（新增章節）
    static func refreshAll(bookStore: BookStore) async {
        let onlineBooks = bookStore.books.filter { $0.isOnline }
        guard !onlineBooks.isEmpty else { return }

        // Limit concurrency to avoid network request storms on startup that trigger Rate Limiting/Cloudflare
        let maxConcurrentTasks = 3
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
            // 靜默失敗，不打擾使用者
        }
    }
}
