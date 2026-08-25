import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// End-to-end proof that a marked paragraph actually gets a bubble painted
/// behind it: renders through the reader's own line drawer and inspects pixels,
/// so the marker, the painter and the drawer's hook are all exercised together.
@Suite("Dialogue bubble painting")
struct ReaderDialogueBubblePaintingTests {
    private static let width: CGFloat = 300
    private static let fontSize: CGFloat = 18

    @Test("paints the bubble against the side it was assigned")
    func paintsOnAssignedSide() throws {
        var style = ReaderDialogueBubbleStyle(isEnabled: true)
        style.alternatesSides = false

        style.startSide = .right
        let right = try render(style: style)
        let rightFill = try #require(right.centroidX(of: style.right.fillHex))
        #expect(right.count(of: style.right.fillHex) > 200)
        #expect(rightFill > Self.width / 2)

        style.startSide = .left
        let left = try render(style: style)
        let leftFill = try #require(left.centroidX(of: style.left.fillHex))
        #expect(leftFill < Self.width / 2)
    }

    /// The bubble hugs its text: it must not reach either column edge, or it is
    /// a full-width background rather than a chat bubble.
    @Test("keeps the bubble inside the column")
    func keepsBubbleInsideColumn() throws {
        var style = ReaderDialogueBubbleStyle(isEnabled: true)
        style.alternatesSides = false
        style.startSide = .right

        let canvas = try render(style: style)
        let bounds = try #require(canvas.horizontalBounds(of: style.right.fillHex))

        #expect(bounds.min > 0)
        #expect(bounds.max < Int(Self.width * canvas.scale) - 1)
    }

    @Test("paints nothing when the style is off")
    func paintsNothingWhenDisabled() throws {
        var style = ReaderDialogueBubbleStyle(isEnabled: true)
        style.alternatesSides = false
        style.startSide = .right
        let enabledCount = try render(style: style).count(of: style.right.fillHex)

        style.isEnabled = false
        let disabledCount = try render(style: style).count(of: style.right.fillHex)

        #expect(enabledCount > 200)
        #expect(disabledCount == 0)
    }

    // MARK: - Rendering

    private func render(style: ReaderDialogueBubbleStyle) throws -> Canvas {
        let attr = NSMutableAttributedString(
            string: "「你今天怎麼這麼早？」",
            attributes: [
                .font: UIFont.systemFont(ofSize: Self.fontSize),
                .foregroundColor: UIColor.black,
            ]
        )
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: Self.width,
            bodyFontSize: Self.fontSize,
            to: attr
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let range = CFRange(location: 0, length: attr.length)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            range,
            nil,
            CGSize(width: Self.width, height: .greatestFiniteMagnitude),
            nil
        )
        let height = ceil(suggested.height) + Self.fontSize * 4
        let frame = CTFramesetterCreateFrame(
            framesetter,
            range,
            CGPath(
                rect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                transform: nil
            ),
            nil
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: Self.width, height: height),
            format: format
        ).image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: height))
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame,
                contentWidth: Self.width,
                contentMinX: 0,
                contentMinY: 0,
                isLastPage: true,
                attrStr: attr,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                in: ctx
            )
            ctx.restoreGState()
        }
        return try Canvas(image: image)
    }

    // MARK: - Pixels

    private struct Canvas {
        let width: Int
        let height: Int
        let scale: CGFloat
        private let pixels: [UInt8]
        private let bytesPerRow: Int

        init(image: UIImage) throws {
            let cgImage = try #require(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            scale = image.scale
            bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
            let context = try #require(
                CGContext(
                    data: &buffer,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            pixels = buffer
        }

        /// Tolerant match: the fill goes through a colour-space round trip on the
        /// way into the bitmap.
        private func matches(x: Int, y: Int, hex: UInt32) -> Bool {
            let offset = y * bytesPerRow + x * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return abs(red - Int((hex >> 16) & 0xFF)) <= 8
                && abs(green - Int((hex >> 8) & 0xFF)) <= 8
                && abs(blue - Int(hex & 0xFF)) <= 8
        }

        func count(of hex: UInt32) -> Int {
            var total = 0
            for y in 0..<height where y % 2 == 0 {
                for x in 0..<width where matches(x: x, y: y, hex: hex) {
                    total += 1
                }
            }
            return total
        }

        func centroidX(of hex: UInt32) -> CGFloat? {
            var sum = 0
            var total = 0
            for y in 0..<height where y % 2 == 0 {
                for x in 0..<width where matches(x: x, y: y, hex: hex) {
                    sum += x
                    total += 1
                }
            }
            guard total > 0 else { return nil }
            return CGFloat(sum) / CGFloat(total) / scale
        }

        func horizontalBounds(of hex: UInt32) -> (min: Int, max: Int)? {
            var minimum = Int.max
            var maximum = Int.min
            for y in 0..<height {
                for x in 0..<width where matches(x: x, y: y, hex: hex) {
                    minimum = min(minimum, x)
                    maximum = max(maximum, x)
                }
            }
            guard minimum <= maximum else { return nil }
            return (minimum, maximum)
        }
    }
}
