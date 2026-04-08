import UIKit

/// A UIViewController that tracks its position in the global page sequence.
protocol PageIndexProviding: AnyObject {
    var globalPageIndex: Int { get }
}

protocol CoreTextReadingPositionProviding: AnyObject {
    var coreTextReadingPosition: CoreTextReadingPosition? { get }
}

/// 閱讀引擎抽象層。ReaderView 只認識這個 protocol，不依賴具體引擎實作。
@MainActor
protocol PageRenderingProvider: AnyObject {
    /// 全書總頁數（跨所有章節）
    var totalPages: Int { get }
    /// 當前全局頁碼（0-based）
    var currentPage: Int { get }

    /// 取得第 index 頁的 ViewController（供 UIPageViewController data source 使用）
    func pageViewController(at index: Int) -> UIViewController

    /// 章節 + charOffset → 全局頁碼
    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int

    /// 穩定內容位置 → 全局頁碼。章節未載入時回傳 nil。
    func pageIndex(for position: CoreTextReadingPosition) -> Int?

    /// 全局頁碼 → 穩定內容位置。若只能推估則回傳最接近的值。
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition?

    /// 全局頁碼 → (spineIndex, charOffset)，供 CharOffsetStore 存檔用
    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int)

    /// 預熱指定章節（背景計算 NSAttributedString + 分頁）
    func preloadChapter(at spineIndex: Int) async

    /// 依穩定內容位置建立對應頁面。章節未載入時可回傳 placeholder。
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController

    /// 視窗大小改變（旋轉 / iPad 分屏）後觸發全書重排
    /// 完成前應凍結翻頁手勢
    func invalidateLayout(newSize: CGSize) async

    /// 在 UIPageViewController.didFinishAnimating 中呼叫
    /// 當前章節剩餘 ≤ 20% 時自動預熱下一章
    func warmUpNext(currentGlobalPage: Int)

    /// 回傳指定章節最後一頁的全局頁碼。章節未載入時回傳 nil。
    func lastPageIndex(ofChapter spineIndex: Int) -> Int?

    /// 全局頁碼 → (spineIndex, localPage)，供跨章邊界導航使用。
    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int)

    /// 取得第 index 頁的快照 ViewController（跨章節動畫接力用）。
    /// 只在該頁為章節第一頁且快照已就緒時才回傳非 nil；其餘情況回傳 nil。
    func snapshotViewController(at index: Int) -> UIViewController?

    /// 離屏渲染指定全局頁為 UIImage，供 cover 動畫使用。
    func renderSnapshot(forPage globalPage: Int) -> UIImage?

    /// 章節就緒回呼（取代 Notification 廣播）
    var onChapterReady: ((Int?) -> Void)? { get set }
    /// 引擎請求跳頁回呼（取代 Notification 廣播）
    var onNavigateToPage: ((Int) -> Void)? { get set }
    
    var offsetStore: CharOffsetStore { get }
    var renderSize: CGSize { get }
    var layouts: [Int: CoreTextPaginator.ChapterLayout] { get }
    
    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor)
    func start(renderSize: CGSize, bookId: String) async
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int?
    func plainText(forPage page: Int) -> String
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double
    func cancelPendingWork()
}

extension PageRenderingProvider {
    func pageIndex(for position: CoreTextReadingPosition) -> Int? { nil }
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? { nil }
    func snapshotViewController(at index: Int) -> UIViewController? { nil }
    func renderSnapshot(forPage globalPage: Int) -> UIImage? { nil }
    func lastPageIndex(ofChapter spineIndex: Int) -> Int? { nil }
    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) { (0, globalPage) }
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? { nil }
    var onChapterReady: ((Int?) -> Void)? {
        get { nil }
        set {}
    }
    var onNavigateToPage: ((Int) -> Void)? {
        get { nil }
        set {}
    }
    func cancelPendingWork() {}
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        if let page = pageIndex(for: position) {
            return pageViewController(at: page)
        }
        return pageViewController(at: 0)
    }
}
