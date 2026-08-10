import CoreGraphics
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Vertical painting of a chapter-title plan.
///
/// Horizontal layers are drawn with `NSAttributedString.draw(with:)`, which overflows its rect
/// instead of clipping, so designs are routinely saved with a box shorter than the font. Rotated
/// for vertical writing that height becomes the column width, where CoreText clips hard — a box
/// one point too narrow used to return zero columns and blank the title.
@Suite("Chapter title vertical painting")
struct ChapterTitleVerticalPaintingTests {
    private static let canvasSize = CGSize(width: 160, height: 320)
    private static let fontSize: CGFloat = 28
    private static let boxOriginX: CGFloat = 60

    @Test("a column narrower than the font still paints the title")
    func narrowColumnStillPaints() throws {
        let ink = try paintedInk(columnWidth: Self.fontSize - 3)

        #expect(ink.pixels > 0)
    }

    @Test("an overflowing title stays centred on its box")
    func narrowColumnStaysCentred() throws {
        let columnWidth = Self.fontSize - 3
        let ink = try paintedInk(columnWidth: columnWidth)

        let boxMidX = Self.boxOriginX + columnWidth / 2
        let inkMidX = CGFloat(ink.minX + ink.maxX) / 2
        #expect(abs(inkMidX - boxMidX) <= 2)
    }

    @Test("a box wide enough keeps CoreText's own column placement")
    func wideColumnIsUntouched() throws {
        let columnWidth = Self.fontSize + 20
        let ink = try paintedInk(columnWidth: columnWidth)

        // Right-to-left columns start at the box's right edge; nothing is widened here.
        #expect(abs(CGFloat(ink.maxX) - (Self.boxOriginX + columnWidth)) <= 2)
    }

    @Test("a horizontal plan is unaffected")
    func horizontalStillPaints() throws {
        let ink = try paintedInk(columnWidth: Self.fontSize - 3, writingMode: .horizontal)

        #expect(ink.pixels > 0)
    }

    // MARK: - Helpers

    private struct Ink {
        var pixels: Int
        var minX: Int
        var maxX: Int
        var minY: Int
    }

    private func paintedInk(
        columnWidth: CGFloat,
        writingMode: ReaderWritingMode = .verticalRTL
    ) throws -> Ink {
        let canvas = Self.canvasSize
        let font = try #require(UIFont(name: "PingFangSC-Regular", size: Self.fontSize))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
        ]
        if writingMode.isVertical {
            attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
        }

        let layer = ChapterTitleRenderedLayer(
            id: UUID(),
            frame: CGRect(
                x: Self.boxOriginX,
                y: 16,
                width: columnWidth,
                height: canvas.height - 32
            ),
            rotationRadians: 0,
            attributedText: NSAttributedString(string: "第一章 初入江湖", attributes: attributes),
            image: nil,
            backgroundImage: nil,
            shape: nil,
            style: ChapterTitleLayerStyle(
                writingDirection: writingMode.isVertical ? .vertical : .horizontal
            ),
            text: "第一章 初入江湖"
        )
        let plan = ChapterTitleRenderPlan(
            accessibilityText: "第一章 初入江湖",
            canvasSize: canvas,
            layers: [layer]
        )

        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { rendererContext in
            ChapterTitleCanvasPainter.draw(
                plan,
                in: CGRect(origin: .zero, size: canvas),
                writingMode: writingMode,
                context: rendererContext.cgContext
            )
        }
        return try scanInk(of: image)
    }

    private func scanInk(of image: UIImage) throws -> Ink {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var ink = Ink(pixels: 0, minX: width, maxX: -1, minY: height)
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                ink.pixels += 1
                ink.minX = min(ink.minX, x)
                ink.maxX = max(ink.maxX, x)
                ink.minY = min(ink.minY, y)
            }
        }
        return ink
    }
}
