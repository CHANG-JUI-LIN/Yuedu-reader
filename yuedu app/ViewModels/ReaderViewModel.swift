import SwiftUI
import Combine

/// 負責處理閱讀器「資料獲取」與「狀態管理」的 ViewModel (遵循 MVVM)
@MainActor
final class ReaderViewModel: ObservableObject {
    // MARK: - 狀態管理 (State)
    @Published var fetchingChapters: Set<Int> = []
    @Published var failedChapters: Set<Int> = []
    @Published var lastChapterError: String = ""
    
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
        
        // 此處假設存在 BookSourceFetcher 可同步檢查快取
        // 注意：原 ReaderView 內的檢查邏輯需根據專案實際情況調整
        // 若有快取，則直接呼叫 onSuccess() 返回
        
        fetchingChapters.insert(chapterIndex)
        
        Task {
            do {
                // 這裡留出接口：原程式碼呼叫 `ChapterFetchManager.shared.fetchChapter(...)`
                // 這邊我們假設它會被正確呼叫，並處理結果
                // (請根據實際的 ChapterFetchManager 進行橋接，以下為概念代碼)
                
                /*
                let pkg = try await ChapterFetchManager.shared.fetchChapter(
                    book: b,
                    chapterIndex: chapterIndex,
                    priority: .immediate,
                    store: store
                )
                */
                // 暫時代替原程式碼中的網路請求
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                await MainActor.run {
                    self.fetchingChapters.remove(chapterIndex)
                    // 這裡的狀態可以依據 pkg.state 等來決定
                    self.failedChapters.remove(chapterIndex)
                    onSuccess()
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
