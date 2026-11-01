import Foundation
import Nuke
import Testing
import UIKit
@testable import yuedu_app

/// 條漫接章時，畫面上已經載好的頁不能被清掉再重載。
///
/// 回饋 #114（iOS 27.2、線上漫畫、條漫）：下滑偶爾閃黑一下，「圖片已加載」。接下一章（或上一章）
/// 原本整個 reloadData：畫面上每一格都被回收，prepareForReuse 清掉圖，willDisplay 再向 Nuke
/// 非同步要——就算記憶體快取裡就有，Nuke 也要先跳到自己的佇列才查快取，中間至少一幀露出閱讀器的
/// 黑底。捲回看過的頁、捲到預抓好的頁，也是同一個非同步空檔。
@Suite("Fixed page webtoon image continuity", .serialized)
@MainActor
struct FixedPageWebtoonImageContinuityTests {

    private static let size = CGSize(width: 400, height: 800)
    private static let configuration = FixedPageReaderConfiguration.recommendedDefault(for: .webtoon)

    @Test("the watch sees an image view being cleared")
    func watchSeesClears() {
        // The continuity tests below pass when this watch counts nothing; make sure it counts.
        let imageView = UIImageView(image: UIImage())
        let watch = ImageClearWatch([imageView])
        imageView.image = nil
        #expect(watch.clears == 1)
    }

    @Test("a page whose image is already in memory shows it before load() returns")
    func cachedImageIsShownSynchronously() {
        let page = Self.cachedPages(count: 1, chapter: "sync", imageSize: CGSize(width: 100, height: 200))[0]
        let cell = FixedPageWebtoonCell(frame: CGRect(origin: .zero, size: Self.size))
        var reports: [(index: Int, ratio: CGFloat)] = []
        cell.configure(
            page: page,
            index: 3,
            targetWidth: Self.size.width,
            cropBorders: Self.configuration.cropBorders
        ) { index, _, ratio in
            reports.append((index, ratio))
        }

        cell.load()

        #expect(cell.imageView.image != nil)
        #expect(reports.count == 1)
        #expect(reports.first?.index == 3)
        #expect(abs((reports.first?.ratio ?? 0) - 2) < 0.01)
    }

    @Test("appending the next chapter leaves the pages on screen untouched")
    func appendKeepsPagesOnScreen() async throws {
        try await Self.withReader(Self.cachedPages(count: 4, chapter: "append")) { reader in
            let shown = try await Self.pagesOnScreen(in: reader)
            let watch = ImageClearWatch(shown.map(\.cell.imageView))

            reader.appendPages(Self.cachedPages(count: 3, chapter: "append-next"))
            reader.collectionView.layoutIfNeeded()

            #expect(reader.pages.count == 7)
            #expect(watch.clears == 0, "a page on screen lost its image while the next chapter was added")
            Self.expectStillShown(shown, movedBy: 0, in: reader)
        }
    }

    @Test("prepending the previous chapter leaves the pages on screen untouched and in place")
    func prependKeepsPagesOnScreen() async throws {
        try await Self.withReader(Self.cachedPages(count: 4, chapter: "prepend")) { reader in
            let shown = try await Self.pagesOnScreen(in: reader)
            let watch = ImageClearWatch(shown.map(\.cell.imageView))

            reader.insertPagesAbove(Self.cachedPages(count: 2, chapter: "prepend-previous"))
            reader.collectionView.layoutIfNeeded()

            #expect(reader.pages.count == 6)
            #expect(watch.clears == 0, "a page on screen lost its image while the previous chapter was added")
            Self.expectStillShown(shown, movedBy: 2, in: reader)
        }
    }

    @Test("a page's image that lands after a prepend sizes the item the page moved to")
    func reportAfterPrependSizesMovedPage() async throws {
        var strip = Self.cachedPages(count: 3, chapter: "late")
        // Its image only arrives once the previous chapter is above it.
        let late = Self.page(chapter: "late-arrival", id: 1)
        strip[1] = late
        try await Self.withReader(strip) { reader in
            let collectionView = reader.collectionView
            _ = try await Self.pagesOnScreen(in: reader, items: [0])
            let lateCell = try #require(collectionView.cellForItem(at: IndexPath(item: 1, section: 0)) as? FixedPageWebtoonCell)

            reader.insertPagesAbove(Self.cachedPages(count: 2, chapter: "late-previous"))
            collectionView.layoutIfNeeded()
            #expect(reader.pages[3] == late)

            // What a redisplay or a display-scale change does with the cell on screen.
            Self.cache(late, imageSize: CGSize(width: 100, height: 300))
            let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 3, section: 0)) as? FixedPageWebtoonCell)
            #expect(cell === lateCell)
            cell.load()
            collectionView.layoutIfNeeded()

            let frame = try #require(reader.layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame)
            #expect(abs(frame.height - Self.size.width * 3) < 0.01)
            #expect(cell.imageView.accessibilityIdentifier == "webtoon_page_3")
        }
    }

    // MARK: - Helpers

    struct ShownPage {
        let item: Int
        let cell: FixedPageWebtoonCell
        let image: UIImage
        /// Where the page starts on screen.
        let screenY: CGFloat
    }

    /// A webtoon reader in a key window, so the list displays cells and `willDisplay` loads them.
    private static func withReader(
        _ pages: [FixedPage],
        _ body: (FixedPageWebtoonViewController) async throws -> Void
    ) async throws {
        let targetWidth = FixedPageTargetWidth()
        targetWidth.value = size.width
        let reader = FixedPageWebtoonViewController(
            fixedPageReaderConfiguration: configuration,
            targetWidth: targetWidth
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        reader.view.layoutIfNeeded()
        reader.setPages(pages, startPage: 0)
        try await body(reader)
    }

    /// The pages on screen (or just `items` of them) once each shows its image. A reader that
    /// was just given its pages may still be fetching the first ones.
    private static func pagesOnScreen(
        in reader: FixedPageWebtoonViewController,
        items: Set<Int>? = nil
    ) async throws -> [ShownPage] {
        let collectionView = reader.collectionView
        let deadline = ContinuousClock.now + .seconds(5)
        var shown: [ShownPage] = []
        var expected = 0
        repeat {
            collectionView.layoutIfNeeded()
            let visible = collectionView.indexPathsForVisibleItems
                .filter { items?.contains($0.item) ?? true }
                .sorted()
            expected = visible.count
            shown = visible.compactMap { indexPath in
                guard let cell = collectionView.cellForItem(at: indexPath) as? FixedPageWebtoonCell,
                      let image = cell.imageView.image
                else { return nil }
                return ShownPage(
                    item: indexPath.item,
                    cell: cell,
                    image: image,
                    screenY: cell.frame.minY - collectionView.contentOffset.y
                )
            }
            if expected > 0, shown.count == expected { return shown }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        Issue.record("only \(shown.count) of \(expected) pages on screen got their images")
        return shown
    }

    /// Each page that was on screen is still there, `movedBy` items further down the strip:
    /// in the same cell, with the same image, at the same place on screen.
    private static func expectStillShown(
        _ shown: [ShownPage],
        movedBy offset: Int,
        in reader: FixedPageWebtoonViewController
    ) {
        let collectionView = reader.collectionView
        #expect(!shown.isEmpty)
        for page in shown {
            let indexPath = IndexPath(item: page.item + offset, section: 0)
            let cell = collectionView.cellForItem(at: indexPath)
            #expect(cell === page.cell, "item \(indexPath.item) is in another cell")
            #expect(page.cell.imageView.image === page.image, "item \(indexPath.item) shows another image")
            #expect(
                abs(page.cell.frame.minY - collectionView.contentOffset.y - page.screenY) < 0.5,
                "item \(indexPath.item) moved on screen"
            )
        }
    }

    /// Pages whose images are in Nuke's memory cache, under the request the reader makes.
    /// 200×287 is the layout's placeholder ratio, so their arrival changes no height.
    private static func cachedPages(
        count: Int,
        chapter: String,
        imageSize: CGSize = CGSize(width: 200, height: 287)
    ) -> [FixedPage] {
        (0..<count).map { index in
            let page = page(chapter: chapter, id: index)
            cache(page, imageSize: imageSize)
            return page
        }
    }

    /// A page with a file of its own that does not exist: nothing but the memory cache can
    /// give it an image.
    private static func page(chapter: String, id: Int) -> FixedPage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FixedPageWebtoonImageContinuityTests-\(chapter)-\(id)-\(UUID().uuidString).jpg"
        )
        return FixedPage(id: id, imageURL: url.absoluteString, headers: [:], localURL: url)
    }

    private static func cache(_ page: FixedPage, imageSize: CGSize) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }
        let request = FixedPageImageLoader.request(
            for: page,
            targetWidth: size.width,
            cropBorders: configuration.cropBorders
        )
        ImagePipeline.shared.cache[request] = ImageContainer(image: image)
    }
}

/// Counts every time one of `imageViews` is left without an image: a frame in which the
/// reader's black background shows through that page.
@MainActor
private final class ImageClearWatch {
    private(set) var clears = 0
    private var observations: [NSKeyValueObservation] = []

    init(_ imageViews: [UIImageView]) {
        observations = imageViews.map { imageView in
            imageView.observe(\.image, options: [.new]) { [weak self] _, change in
                let cleared = change.newValue.map { $0 == nil } ?? false
                MainActor.assumeIsolated {
                    if cleared { self?.clears += 1 }
                }
            }
        }
    }
}
