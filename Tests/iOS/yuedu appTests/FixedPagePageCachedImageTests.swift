import Foundation
import Nuke
import Testing
import UIKit
@testable import yuedu_app

/// 翻頁模式翻到一頁時，圖已經在記憶體裡就要當下放上去。
///
/// 跟條漫的回饋 #114 同一個空檔：頁面控制器一律向 Nuke 非同步要圖，就算記憶體快取裡就有，
/// Nuke 也要先跳到自己的佇列才查快取，新建出來的頁至少一幀是空的，露出閱讀器的黑底。
/// 翻回看過的頁、翻到預抓好的頁，都會走到這裡。
@Suite("Fixed page page cached image", .serialized)
@MainActor
struct FixedPagePageCachedImageTests {

    private static let targetWidth: CGFloat = 400
    private static let configuration = FixedPageReaderConfiguration.recommendedDefault(for: .rtl)

    @Test("a page whose image is already in memory shows it as soon as its view loads")
    func cachedImageIsShownWhenViewLoads() {
        let page = Self.cachedPage(imageSize: CGSize(width: 200, height: 300))
        let controller = FixedPagePageViewController(
            page: page,
            index: 0,
            fixedPageReaderConfiguration: Self.configuration,
            targetWidth: Self.targetWidth
        )
        var loaded: [UIImage] = []
        controller.onImageLoaded = { loaded.append($0) }

        controller.loadViewIfNeeded()

        #expect(controller.imageView.image != nil)
        #expect(loaded.count == 1)
        #expect(controller.imageView.accessibilityIdentifier == "fixed_page_image")
        // Nothing left to load: no second report, no spinner coming back.
        #expect(controller.loadTask == nil)
    }

    /// A page with a file of its own that does not exist, whose image is in Nuke's memory
    /// cache under the request the page makes: nothing but that cache can give it an image.
    private static func cachedPage(imageSize: CGSize) -> FixedPage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FixedPagePageCachedImageTests-\(UUID().uuidString).jpg"
        )
        let page = FixedPage(id: 0, imageURL: url.absoluteString, headers: [:], localURL: url)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }
        let request = FixedPageImageLoader.request(
            for: page,
            targetWidth: targetWidth,
            cropBorders: configuration.cropBorders
        )
        ImagePipeline.shared.cache[request] = ImageContainer(image: image)
        return page
    }
}
