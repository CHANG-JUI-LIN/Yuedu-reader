import UIKit

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

    /// 全局頁碼 → (spineIndex, charOffset)，供 CharOffsetStore 存檔用
    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int)

    /// 預熱指定章節（背景計算 NSAttributedString + 分頁）
    func preloadChapter(at spineIndex: Int) async

    /// 視窗大小改變（旋轉 / iPad 分屏）後觸發全書重排
    /// 完成前應凍結翻頁手勢
    func invalidateLayout(newSize: CGSize) async

    /// 在 UIPageViewController.didFinishAnimating 中呼叫
    /// 當前章節剩餘 ≤ 3 頁時自動預熱下一章
    func warmUpNext(currentGlobalPage: Int)
}
