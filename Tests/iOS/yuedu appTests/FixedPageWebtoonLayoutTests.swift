import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 條漫（連續捲動）的版面：每一格的高度要跟著「那一頁」的圖走。
///
/// 反饋 #13（iOS 17、線上漫畫、條漫）：圖比螢幕窄、和下一格對不上、畫面跳。量到的
/// 圖片比例原本按「第幾格」存，往上接上一章時頁面整串往後挪、比例卻留在原格，之後每一頁
/// 都用別頁的比例排，圖就以 aspect-fit 畫進高度不對的格子。圖還在載入時接上一章，
/// 載完回報的舊格號也會把比例寫進已經換成別頁的格子。上方的格子載完圖改變高度時，
/// 正在看的內容也不能被往下推。
@Suite("Fixed page webtoon layout", .serialized)
@MainActor
struct FixedPageWebtoonLayoutTests {

    private static let width: CGFloat = 400
    private static let defaultHeight: CGFloat = 400 * 1.435

    @Test("a measured height follows its page when a previous chapter is prepended")
    func ratioFollowsPageThroughPrepend() {
        let (reader, pages) = Self.makeReader(pageCount: 3, chapter: "follows")
        reader.pageImageDidLoad(index: 0, page: pages[0], ratio: 3)
        reader.pageImageDidLoad(index: 1, page: pages[1], ratio: 0.5)
        reader.collectionView.layoutIfNeeded()

        reader.insertPagesAbove(Self.makePages(count: 2, chapter: "follows-previous"))
        reader.collectionView.layoutIfNeeded()

        #expect(reader.pages[2] == pages[0])
        #expect(Self.isClose(Self.frame(of: 2, in: reader).height, Self.width * 3))
        #expect(Self.isClose(Self.frame(of: 3, in: reader).height, Self.width * 0.5))
        // The prepended pages have not loaded yet, so they keep the placeholder height.
        #expect(Self.isClose(Self.frame(of: 0, in: reader).height, Self.defaultHeight))
        #expect(Self.isClose(Self.frame(of: 1, in: reader).height, Self.defaultHeight))
    }

    @Test("a load that finishes after a prepend does not size the page now in its old slot")
    func staleCompletionIsDropped() {
        let (reader, pages) = Self.makeReader(pageCount: 3, chapter: "stale")
        reader.insertPagesAbove(Self.makePages(count: 1, chapter: "stale-previous"))

        // The cell was configured for item 0 before the prepend; item 0 is another page now.
        reader.pageImageDidLoad(index: 0, page: pages[0], ratio: 3)
        reader.collectionView.layoutIfNeeded()
        #expect(Self.isClose(Self.frame(of: 0, in: reader).height, Self.defaultHeight))
        #expect(Self.isClose(Self.frame(of: 1, in: reader).height, Self.defaultHeight))

        // Reconfigured for its new index, the same page sizes its own item.
        reader.pageImageDidLoad(index: 1, page: pages[0], ratio: 3)
        reader.collectionView.layoutIfNeeded()
        #expect(Self.isClose(Self.frame(of: 1, in: reader).height, Self.width * 3))
    }

    @Test("a page above the screen that changes height leaves the page being read where it was")
    func heightChangeAboveKeepsViewport() {
        let (reader, pages) = Self.makeReader(pageCount: 10, chapter: "anchor")
        let collectionView = reader.collectionView
        collectionView.contentOffset = CGPoint(x: 0, y: 2000)
        collectionView.layoutIfNeeded()
        // Item 4 is the first page starting on screen.
        let onScreenBefore = Self.frame(of: 4, in: reader).minY - collectionView.contentOffset.y

        reader.pageImageDidLoad(index: 0, page: pages[0], ratio: 3)
        collectionView.layoutIfNeeded()

        #expect(Self.isClose(collectionView.contentOffset.y, 2000 + Self.width * 3 - Self.defaultHeight))
        #expect(Self.isClose(Self.frame(of: 4, in: reader).minY - collectionView.contentOffset.y, onScreenBefore))

        // A page below the screen grows downwards, out of view: nothing on screen moves.
        let offset = collectionView.contentOffset.y
        reader.pageImageDidLoad(index: 8, page: pages[8], ratio: 3)
        collectionView.layoutIfNeeded()
        #expect(Self.isClose(collectionView.contentOffset.y, offset))
    }

    @Test("prepending a chapter at the top keeps the page on screen in place")
    func prependKeepsViewport() {
        let (reader, pages) = Self.makeReader(pageCount: 4, chapter: "prepend")
        let collectionView = reader.collectionView
        collectionView.contentOffset = CGPoint(x: 0, y: 100)
        collectionView.layoutIfNeeded()

        reader.insertPagesAbove(Self.makePages(count: 2, chapter: "prepend-previous"))
        collectionView.layoutIfNeeded()

        #expect(reader.pages[2] == pages[0])
        #expect(Self.isClose(collectionView.contentOffset.y, 100 + 2 * Self.defaultHeight))
        #expect(reader.currentPageIndex() == 2)
    }

    /// 回饋 #127（3.0.1、線上漫畫、條漫）：某些頁交界出現一條細黑線，別的 App 同一張圖沒有。
    /// 截圖（3×）白色對話框上 255 → 193 → 99 → 255：兩格交界落在半像素，兩邊各自反鋸齒，
    /// 透出閱讀器的深色底。每一格的上下緣都要落在像素格上，相鄰兩格共用同一條像素邊界。
    @Test("adjacent pages meet on an exact pixel boundary", arguments: [CGFloat(1), 1.37])
    func pagesMeetOnPixelBoundary(zoomScale: CGFloat) {
        let ratios: [CGFloat] = [1.4371, 0.7777, 2.123456, 1.0001, 3.33333, 0.61803]
        let (reader, pages) = Self.makeReader(pageCount: ratios.count, chapter: "seam", displayScale: 3)
        for (index, ratio) in ratios.enumerated() {
            reader.pageImageDidLoad(index: index, page: pages[index], ratio: ratio)
        }
        reader.layout.zoomScale = zoomScale
        reader.layout.invalidateLayout()
        reader.collectionView.layoutIfNeeded()

        let spacing = reader.layout.minimumLineSpacing
        #expect(spacing == 0, "the webtoon default has no gap between pages")
        let frames = ratios.indices.map { Self.frame(of: $0, in: reader) }
        for (item, frame) in frames.enumerated() {
            for edge in [frame.minY, frame.maxY, frame.minX, frame.maxX] {
                #expect(Self.isOnPixelGrid(edge, scale: 3), "item \(item) edge \(edge) falls between pixels")
            }
            // Still the page's own height, to within the pixel the edges were moved by.
            let expected = frame.width * ratios[item]
            #expect(abs(frame.height - expected) <= 1.0 / 3 + 0.0001, "item \(item) height \(frame.height) vs \(expected)")
        }
        for item in frames.indices.dropLast() {
            #expect(frames[item].maxY + spacing == frames[item + 1].minY, "items \(item) and \(item + 1) do not share an edge")
        }
        #expect(reader.layout.collectionViewContentSize.height == frames.last?.maxY)
    }

    @Test("a page image that fails to load leaves one log line; a cancelled load leaves none")
    func loaderLogsFailuresButNotCancellation() async throws {
        let failing = Self.missingFilePage(named: "FixedPageImageLoader-fails-\(UUID().uuidString).jpg")
        let failingName = try #require(failing.localURL?.lastPathComponent)
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        let image = await FixedPageImageLoader.loadImage(for: failing, targetWidth: 100, renderScale: 1)
        #expect(image == nil)
        let added = DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains(failingName) }
        #expect(added.count == 1)
        #expect(added.first?.severity == .error)

        let cancelled = Self.missingFilePage(named: "FixedPageImageLoader-cancelled-\(UUID().uuidString).jpg")
        let cancelledName = try #require(cancelled.localURL?.lastPathComponent)
        let task = Task { await FixedPageImageLoader.loadImage(for: cancelled, targetWidth: 100, renderScale: 1) }
        task.cancel()
        let cancelledImage = await task.value
        #expect(cancelledImage == nil)
        let afterCancel = DiagnosticLog.shared.snapshot().filter { $0.message.contains(cancelledName) }
        #expect(afterCancel.isEmpty)
    }

    // MARK: - Helpers

    /// A webtoon reader 400pt wide holding `pageCount` pages whose images never load
    /// (missing files), so every height comes from what the test reports.
    private static func makeReader(
        pageCount: Int,
        chapter: String,
        displayScale: CGFloat? = nil
    ) -> (FixedPageWebtoonViewController, [FixedPage]) {
        let targetWidth = FixedPageTargetWidth()
        targetWidth.value = width
        let reader = FixedPageWebtoonViewController(
            fixedPageReaderConfiguration: .recommendedDefault(for: .webtoon),
            targetWidth: targetWidth
        )
        if let displayScale {
            reader.traitOverrides.displayScale = displayScale
        }
        reader.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        reader.view.layoutIfNeeded()
        let pages = makePages(count: pageCount, chapter: chapter)
        reader.setPages(pages, startPage: 0)
        return (reader, pages)
    }

    private static func makePages(count: Int, chapter: String) -> [FixedPage] {
        (0..<count).map { index in
            missingFilePage(named: "FixedPageWebtoonLayoutTests-\(chapter)-\(index)-\(UUID().uuidString).jpg", id: index)
        }
    }

    private static func missingFilePage(named name: String, id: Int = 0) -> FixedPage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return FixedPage(id: id, imageURL: url.absoluteString, headers: [:], localURL: url)
    }

    /// The item's laid-out frame; `.null` (which fails every comparison) when it has none.
    private static func frame(of item: Int, in reader: FixedPageWebtoonViewController) -> CGRect {
        let attributes = reader.layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))
        #expect(attributes != nil, "item \(item) has no layout attributes")
        return attributes?.frame ?? .null
    }

    private static func isOnPixelGrid(_ value: CGFloat, scale: CGFloat) -> Bool {
        let pixels = value * scale
        return abs(pixels - pixels.rounded()) < 0.0001
    }

    private static func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 0.01
    }
}
