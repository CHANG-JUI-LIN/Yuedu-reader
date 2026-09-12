@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserReaderParityTests {
    @Test func snapshotUsesReaderArtworkOverAuthoredBackground() throws {
        let size = CGSize(width: 16, height: 16)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let artwork = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let authored = DisplayList(items: [.fill(DisplayFillItem(
            rect: PageLocalRect(rawValue: CGRect(origin: .zero, size: size)),
            color: .blue, cornerRadius: 0, borderTop: .zero, borderBottom: .zero,
            borderLeft: .zero, borderRight: .zero, nodeID: 0, writingMode: .horizontal,
            isBackgroundPaint: true
        ))])
        let replaced = DisplayListRenderer.render(authored, size: size, readerBackgroundImage: artwork)
        let original = DisplayListRenderer.render(authored, size: size)
        // Compare rendered pixels, not PNG metadata/compression: redrawing an
        // image may produce a different PNG stream with identical artwork.
        #expect(try rgbaPixel(replaced) == [255, 0, 0, 255])
        #expect(try rgbaPixel(original) == [0, 0, 255, 255])
    }

    private func rgbaPixel(_ image: UIImage) throws -> [UInt8] {
        let source = try #require(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    @Test func readerLineHeightInheritsAndAuthorDeclarationWins() async throws {
        let parsed = await HTMLBuilderDOMParser().parse(
            html: "<html><body><p>Reader spacing</p><p class='authored'>Author spacing</p></body></html>",
            collectStyles: { _ in [] }, stylesheetCache: nil
        )
        let body = try #require(parsed?.body)
        let builder = ComputedStyleTreeBuilder(
            rules: CSSParser.parse(css: ".authored { line-height: 1.5; }"),
            config: BrowserLayoutConfig(rootFontSize: 20, lineHeight: 2)
        )
        let tree = builder.buildTree(body: body)
        let paragraphs = tree.children.compactMap { child -> ComputedStyleNode? in
            if case .element(let node) = child { return node }
            return nil
        }
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].style.lineHeight == 40)
        #expect(paragraphs[1].style.lineHeight == 30)
    }
}
