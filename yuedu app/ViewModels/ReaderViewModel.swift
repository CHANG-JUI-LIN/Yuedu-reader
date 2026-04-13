import SwiftUI
import Combine

/// 負責處理閱讀器「資料獲取」與「狀態管理」的 ViewModel (遵循 MVVM)
@MainActor
final class ReaderViewModel: ObservableObject {
    // MARK: - 狀態管理 (State)
    @Published var fetchingChapters: Set<Int> = []
    @Published var failedChapters: Set<Int> = []
    @Published var lastChapterError: String = ""

    private let bookSourceFetcher: BookSourceFetching
    private let chapterFetcher: ChapterFetching

    init(
        bookSourceFetcher: BookSourceFetching,
        chapterFetcher: ChapterFetching
    ) {
        self.bookSourceFetcher = bookSourceFetcher
        self.chapterFetcher = chapterFetcher
    }
    
    // MARK: - 資料獲取 (Data Fetching)
    /// 擷取線上章節
    func fetchChapterIfNeeded(
        book: ReadingBook?,
        chapterIndex: Int,
        currentChapterIndex: Int,
        store: BookStore,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard let b = book, b.isOnline, let refs = b.onlineChapters, chapterIndex < refs.count,
              !fetchingChapters.contains(chapterIndex) else {
            return
        }
        
        let bookId = b.id

        if bookSourceFetcher.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: nil,
            expectedTOCTitle: nil
        ) {
            failedChapters.remove(chapterIndex)
            onSuccess()
            return
        }
        
        fetchingChapters.insert(chapterIndex)
        let priority: ChapterFetchPriority = (chapterIndex == currentChapterIndex) ? .jump : .immediate
        
        Task {
            do {
                let pkg = try await chapterFetcher.fetchChapter(
                    book: b,
                    chapterIndex: chapterIndex,
                    priority: priority,
                    store: store
                )

                await MainActor.run {
                    self.fetchingChapters.remove(chapterIndex)
                    if pkg.state == .cached && !pkg.content.isEmpty {
                        self.failedChapters.remove(chapterIndex)
                        onSuccess()
                    } else {
                        self.failedChapters.insert(chapterIndex)
                        let reason = pkg.failureReason ?? "empty"
                        self.lastChapterError = "ch\(chapterIndex): \(reason)"
                        onFailure(self.lastChapterError)
                    }
                }
            } catch {
                await MainActor.run {
                    self.fetchingChapters.remove(chapterIndex)
                    self.failedChapters.insert(chapterIndex)
                    self.lastChapterError = "ch\(chapterIndex): \(error.localizedDescription)"
                    onFailure(self.lastChapterError)
                }
            }
        }
    }
}
