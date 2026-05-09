import UIKit

// MARK: - PageIndexProviding / CoreTextReadingPositionProviding

/// A UIViewController that tracks its position in the global page sequence.
protocol PageIndexProviding: AnyObject {
    var globalPageIndex: Int { get }
}

protocol CoreTextReadingPositionProviding: AnyObject {
    var coreTextReadingPosition: CoreTextReadingPosition? { get }
}

// MARK: - PageLayoutEngine（純排版層。不 import UIKit 以外的 UI 型別）

/// 排版引擎抽象：只負責「接收資料 → 計算佈局 → 輸出幾何數據」，
/// 不製造任何 UIView / UIViewController。
/// 未來若要支援垂直捲動、條漫等新排版方式，只需實作此 protocol，
/// 上層 UI 容器自行決定如何消費 layouts。
@MainActor
protocol PageLayoutEngine: AnyObject {
    /// 全書總頁數（跨所有章節）
    var totalPages: Int { get }
    /// 當前全局頁碼（0-based）
    var currentPage: Int { get }
    /// 排版結果（spineIndex → ChapterLayout）
    var layouts: [Int: CoreTextPaginator.ChapterLayout] { get }
    /// 當前畫面尺寸
    var renderSize: CGSize { get }
    /// CharOffset 持久化倉庫
    var offsetStore: CharOffsetStore { get }

    /// 章節 + charOffset → 全局頁碼
    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int
    /// 穩定座標 → 全局頁碼
    func pageIndex(for position: CoreTextReadingPosition) -> Int?
    /// 全局頁碼 → 穩定座標
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition?
    /// 全局頁碼 → (spineIndex, charOffset)
    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int)
    /// 全局頁碼 → (spineIndex, localPage)
    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int)
    /// 指定章節最後一頁的全局頁碼
    func lastPageIndex(ofChapter spineIndex: Int) -> Int?
    /// 全局頁碼 → 純文字（供 TTS / 搜尋）
    func plainText(forPage page: Int) -> String
    /// 全書閱讀進度（0…1）
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double
    /// 進度 → 座標
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int)
    /// 章節內部連結解析
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int?

    // MARK: 引擎生命週期
    func start(renderSize: CGSize, bookId: String) async
    func preloadChapter(at spineIndex: Int) async
    func invalidateLayout(newSize: CGSize) async
    func warmUpNext(currentGlobalPage: Int)
    func cancelPendingWork()

    /// 通知引擎：指定章節的底層資料已更新（如網路抓取完成）。
    /// 引擎清除該章節的 layout 並重新載入，不影響其他章節。
    func notifyChapterDataChanged(at spineIndex: Int) async

    // MARK: 樣式更新
    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor)
    func updateRenderSettings(_ settings: ReaderRenderSettings)
    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation])

    // MARK: 回呼（取代 Notification 廣播）
    var onChapterReady: ((Int?) -> Void)? { get set }
    var onNavigateToPage: ((Int) -> Void)? { get set }
}

// MARK: - PageViewControllerVending（UIKit 橋接層）

/// ViewController 工廠協定。
/// 職責：把 PageLayoutEngine 產出的幾何數據包裝成 UIViewController，
/// 供 UIPageViewController data source 使用。
/// 刻意獨立於 PageLayoutEngine，讓未來的 ScrollReaderBridge 只實作
/// PageLayoutEngine 而不必理會任何 ViewController 的建構細節。
@MainActor
protocol PageViewControllerVending: AnyObject {
    /// 取得第 index 頁的 ViewController
    func pageViewController(at index: Int) -> UIViewController
    /// 依穩定座標取得 ViewController
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController
    /// 取得跨章節動畫用快照 ViewController
    func snapshotViewController(at index: Int) -> UIViewController?
    /// 離屏渲染為 UIImage（cover 動畫）
    func renderSnapshot(forPage globalPage: Int) -> UIImage?
}

// MARK: - PageRenderingProvider（組合型別別名）

/// ReaderView 所依賴的完整引擎型別。
/// 等於「排版引擎 + ViewController 工廠」的聯集。
/// 若未來要實作垂直捲動閱讀器，只需實作 PageLayoutEngine，
/// 不需實作 PageViewControllerVending。
typealias PageRenderingProvider = PageLayoutEngine & PageViewControllerVending

// MARK: - PageLayoutEngine 預設實作

extension PageLayoutEngine {
    func pageIndex(for position: CoreTextReadingPosition) -> Int? { nil }
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? { nil }
    func lastPageIndex(ofChapter spineIndex: Int) -> Int? { nil }
    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) { (0, globalPage) }
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? { nil }
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) { (0, 0) }
    var onChapterReady: ((Int?) -> Void)? {
        get { nil }
        set {}
    }
    var onNavigateToPage: ((Int) -> Void)? {
        get { nil }
        set {}
    }
    func cancelPendingWork() {}
    func notifyChapterDataChanged(at spineIndex: Int) async {}
    func updateRenderSettings(_ settings: ReaderRenderSettings) {}
    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {}
}

// MARK: - PageViewControllerVending 預設實作

extension PageViewControllerVending where Self: PageLayoutEngine {
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        if let page = pageIndex(for: position) {
            return pageViewController(at: page)
        }
        return pageViewController(at: 0)
    }
    func snapshotViewController(at index: Int) -> UIViewController? { nil }
    func renderSnapshot(forPage globalPage: Int) -> UIImage? { nil }
}
