import Foundation
import PDFKit
import Testing
import UIKit
@testable import yuedu_app

/// 固定頁閱讀器的「自動裁切留白邊框」要對 PDF 頁也有效。
///
/// 開關原本只接到圖片頁（Nuke 處理器）；PDF 頁走 `PDFPageRasterizer`，從來沒收到這個設定，
/// 選單照樣顯示、按了沒有效果。放大時會用更大的寬度重新光柵化，同一頁在每個寬度都必須裁到同一塊。
@Suite("Fixed page PDF crop", .serialized)
struct FixedPagePDFCropTests {

    /// 測試頁內容的灰（white: 0.5）；紙張留白是 255。
    private static let contentGray = 90...170

    @Test("cropping a PDF page removes its blank margins")
    @MainActor
    func croppingRemovesMargins() async throws {
        let (page, url) = try makePDFPage { context in
            // 400 × 600 的頁面，內容只佔中間 300 × 300。
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 50, y: 100, width: 300, height: 300))
        }
        defer { cleanup(url) }

        let full = try #require(await FixedPageImageLoader.loadImage(
            for: page, targetWidth: 320, renderScale: 1, cropBorders: false
        ))
        let cropped = try #require(await FixedPageImageLoader.loadImage(
            for: page, targetWidth: 320, renderScale: 1, cropBorders: true
        ))
        await PDFPageRasterizer.shared.purge()

        #expect(abs(full.size.height / full.size.width - 1.5) < 0.01)
        // 對照：取樣本身可用——沒裁的頁中央是內容、上緣是留白。
        #expect(Self.contentGray.contains(channel(full, x: 0.5, y: 0.4)))
        #expect(channel(full, x: 0.5, y: 0.05) > 230)

        #expect(cropped.size.width == 320)
        #expect(abs(cropped.size.height / cropped.size.width - 1.0) < 0.03)
        #expect(Self.contentGray.contains(channel(cropped, x: 0.1, y: 0.1)))
        #expect(Self.contentGray.contains(channel(cropped, x: 0.9, y: 0.9)))
    }

    @Test("zoomed re-renders crop the same region")
    @MainActor
    func zoomedRendersCropTheSameRegion() async throws {
        let (page, url) = try makePDFPage { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 50, y: 100, width: 300, height: 300))
        }
        defer { cleanup(url) }

        let base = try #require(await FixedPageImageLoader.loadImage(
            for: page, targetWidth: 320, renderScale: 1, cropBorders: true
        ))
        let zoomed = try #require(await FixedPageImageLoader.loadImage(
            for: page, targetWidth: 960, renderScale: 1, cropBorders: true
        ))
        await PDFPageRasterizer.shared.purge()

        let baseRatio = base.size.height / base.size.width
        let zoomedRatio = zoomed.size.height / zoomed.size.width
        #expect(abs(baseRatio - 1.0) < 0.03)
        #expect(abs(zoomedRatio - baseRatio) < 0.01)
        #expect(Self.contentGray.contains(channel(zoomed, x: 0.05, y: 0.05)))
        #expect(Self.contentGray.contains(channel(zoomed, x: 0.95, y: 0.95)))
    }

    @Test("a PDF page rendered wider than its own box still fills the width")
    @MainActor
    func widerRenderFillsWidth() async throws {
        let (page, url) = try makePDFPage { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        defer { cleanup(url) }

        // `getDrawingTransform` 只縮小不放大：畫布比頁面寬時頁面會原尺寸置中、四周留白。
        let image = try #require(await FixedPageImageLoader.loadImage(
            for: page, targetWidth: 800, renderScale: 1, cropBorders: false
        ))
        await PDFPageRasterizer.shared.purge()

        #expect(image.size.width == 800)
        // 對照：頁面中央一定有內容。
        #expect(Self.contentGray.contains(channel(image, x: 0.5, y: 0.5)))
        #expect(Self.contentGray.contains(channel(image, x: 0.02, y: 0.5)))
        #expect(Self.contentGray.contains(channel(image, x: 0.5, y: 0.02)))
    }

    /// Crashlytics 19bca592：條漫快速滑過掃描 PDF 時，格子取消了載入，排在光柵化 actor 上的請求
    /// 卻照樣把頁畫完（背景 140 秒用掉 90 秒 CPU）。被取消的載入輪到時不能再畫。
    @Test("a load its cell cancelled does not rasterize the page")
    @MainActor
    func cancelledLoadIsNotRasterized() async throws {
        let (page, url) = try makePDFPage { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        defer { cleanup(url) }
        await PDFPageRasterizer.shared.purge()

        let cancelled = Task { @MainActor () -> UIImage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await FixedPageImageLoader.loadImage(for: page, targetWidth: 320, renderScale: 1)
        }
        #expect(await cancelled.value == nil, "a cancelled load still drew the page")

        // 對照：同一頁沒被取消時照常畫出來。
        let image = await FixedPageImageLoader.loadImage(for: page, targetWidth: 320, renderScale: 1)
        await PDFPageRasterizer.shared.purge()
        #expect(image?.size.width == 320)
    }

    // MARK: - Helpers

    /// 寫一份單頁 400 × 600 的 PDF 到 `LocalPDFArchive.archiveURL`，回傳對應的固定頁。
    private func makePDFPage(draw: (UIGraphicsPDFRendererContext) -> Void) throws -> (FixedPage, URL) {
        let filename = "FixedPagePDFCropTests-\(UUID().uuidString).pdf"
        let url = LocalPDFArchive.archiveURL(for: filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            draw(context)
        }
        try data.write(to: url)
        let page = FixedPage(
            id: 0,
            imageURL: url.absoluteString,
            headers: [:],
            localURL: nil,
            renderSource: .pdf(sourceFilename: filename, pageIndex: 0)
        )
        return (page, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 以左上為原點、依比例取樣一個像素的紅色通道（測試頁都是灰階）。
    /// 回傳 Int 而不是 tuple，失敗時訊息才看得到實際值；取不到回 -1。
    private func channel(_ image: UIImage, x: CGFloat, y: CGFloat) -> Int {
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width
        let height = cgImage.height
        let px = min(width - 1, max(0, Int(CGFloat(width) * x)))
        let py = min(height - 1, max(0, Int(CGFloat(height) * y)))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return -1 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Int(buffer[(py * width + px) * 4])
        }
    }
}
