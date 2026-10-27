import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 漫畫來源的 `ruleContent.imageDecode`：固定頁（條漫、分頁）載入的每一頁都要先跑過來源的
/// 解碼腳本才解成圖，快取裡也只能有解碼後的圖。
///
/// 反饋 #13：韓漫來源把每張圖切成橫條打亂，靠 imageDecode 拼回去；固定頁閱讀器從來不跑它，
/// 畫面就是一道道硬切邊、一格的橫條疊在另一格的對話框上。
@Suite("Fixed page image decode", .serialized)
@MainActor
struct FixedPageImageDecodeTests {

    @Test("a page goes through the source's imageDecode, and its cached copy is the decoded one")
    func pageIsDecodedAndCachedDecoded() async throws {
        let png = try #require(Self.pngData(width: 5, height: 9))
        // On disk the bytes are reversed: not an image until the rule reverses them back.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixedPageImageDecodeTests-\(UUID().uuidString).jpg")
        try Data(png.reversed()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var source = BookSource(bookSourceUrl: "https://imagedecode-\(UUID().uuidString).test", bookSourceName: "imageDecode stub")
        source.ruleContent.imageDecode = "@js:result.reverse()"
        let decoder = try #require(FixedPageImageDecoder(source: source))
        let raw = FixedPage(id: 0, imageURL: "https://cdn.example.test/page/0.jpg", headers: [:], localURL: url)
        var decoded = raw
        decoded.imageDecoder = decoder

        // Without the rule the bytes are no image at all.
        let undecoded = await FixedPageImageLoader.loadImage(for: raw, targetWidth: 0, renderScale: 1)
        #expect(undecoded == nil)

        let firstLoad = await FixedPageImageLoader.loadImage(for: decoded, targetWidth: 0, renderScale: 1)
        let first = try #require(firstLoad)
        #expect(first.cgImage?.width == 5)
        #expect(first.cgImage?.height == 9)

        // The file is gone: the second load is the cache's, and the cache holds the decoded image.
        try FileManager.default.removeItem(at: url)
        let secondLoad = await FixedPageImageLoader.loadImage(for: decoded, targetWidth: 0, renderScale: 1)
        let second = try #require(secondLoad)
        #expect(second.cgImage?.width == 5)
        #expect(second.cgImage?.height == 9)
    }

    @Test("a raw copy of the same page already in the cache is never served for the decoded page")
    func decodedPageHasItsOwnCacheKey() async throws {
        // A strip-shuffled page is a valid image as downloaded, so the raw one can be cached.
        let downloaded = try #require(Self.pngData(width: 5, height: 9))
        let picture = try #require(Self.pngData(width: 7, height: 3))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixedPageImageDecodeTests-key-\(UUID().uuidString).png")
        try downloaded.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var source = BookSource(bookSourceUrl: "https://imagedecode-key-\(UUID().uuidString).test", bookSourceName: "imageDecode key")
        source.ruleContent.imageDecode = "@js:\"\(picture.base64EncodedString())\""
        let raw = FixedPage(id: 0, imageURL: "https://cdn.example.test/key/0.png", headers: [:], localURL: url)
        var decoded = raw
        decoded.imageDecoder = try #require(FixedPageImageDecoder(source: source))

        let rawLoad = await FixedPageImageLoader.loadImage(for: raw, targetWidth: 0, renderScale: 1)
        let rawImage = try #require(rawLoad)
        #expect(rawImage.cgImage?.width == 5)

        let decodedLoad = await FixedPageImageLoader.loadImage(for: decoded, targetWidth: 0, renderScale: 1)
        let decodedImage = try #require(decodedLoad)
        #expect(decodedImage.cgImage?.width == 7)
        #expect(decodedImage.cgImage?.height == 3)
    }

    @Test("a megabyte-sized page makes the round trip through the rule, not the fallback")
    func largePageIsDecoded() async throws {
        let width = 720
        let height = 720
        let png = try #require(Self.noisePNGData(width: width, height: height))
        #expect(png.count > 1_000_000)
        let name = "FixedPageImageDecodeTests-large-\(UUID().uuidString).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var source = BookSource(bookSourceUrl: "https://imagedecode-large-\(UUID().uuidString).test", bookSourceName: "imageDecode large")
        source.ruleContent.imageDecode = "@js:result"
        var page = FixedPage(id: 0, imageURL: "https://cdn.example.test/large/\(name)", headers: [:], localURL: url)
        page.imageDecoder = try #require(FixedPageImageDecoder(source: source))

        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        let load = await FixedPageImageLoader.loadImage(for: page, targetWidth: 0, renderScale: 1)
        let image = try #require(load)
        #expect(image.cgImage?.width == width)
        // The rule's own output, not the downloaded bytes it falls back to on a timeout.
        let fallback = DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains(name) }
        #expect(fallback.isEmpty)
    }

    @Test("a source without imageDecode gives its pages no decoder")
    func noRuleNoDecoder() {
        var source = BookSource(bookSourceUrl: "https://plain-\(UUID().uuidString).test", bookSourceName: "plain")
        source.ruleContent.imageDecode = "  \n"
        #expect(FixedPageImageDecoder(source: source) == nil)
    }

    @Test("pages carry the decoder and the src as written, options included")
    func pagesCarryDecoderAndOriginalSrc() throws {
        var source = BookSource(bookSourceUrl: "https://src-\(UUID().uuidString).test", bookSourceName: "src")
        source.ruleContent.imageDecode = "@js:result"
        let decoder = try #require(FixedPageImageDecoder(source: source))
        let content = #"""
        <img src="https://cdn.example.test/a/1.webp,{"headers":{"referer":"https://example.test/"}}"><img src="https://cdn.example.test/a/2.webp">
        """#
        let pages = MangaChapterParser.pages(from: content, headers: [:], imageDecoder: decoder)
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0.imageDecoder === decoder })
        #expect(pages[0].imageURL == "https://cdn.example.test/a/1.webp")
        #expect(pages[0].imageDecodeSrc == #"https://cdn.example.test/a/1.webp,{"headers":{"referer":"https://example.test/"}}"#)
        #expect(pages[1].imageDecodeSrc == "https://cdn.example.test/a/2.webp")
    }

    /// Random pixels, which PNG cannot compress: about 4 bytes a pixel on disk.
    private static func noisePNGData(width: Int, height: Int) -> Data? {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    private static func pngData(width: Int, height: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
