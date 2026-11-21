import CoreText
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// A font with no bold face is emboldened by drawing its glyphs a second time, moved
/// along the line. The CoreText engine draws with `CTLineDraw`/`CTFrameDraw`, which
/// ignore the attribute that asks for it: for five weeks (YueduCoreText 394c16f) a
/// Regular-only font showed no bold in TXT, online chapters or legacy EPUB chapters.
struct SyntheticBoldPassTests {
    /// Chalkduster ships one face.
    private static func text(_ string: String, bold: Bool) throws -> NSAttributedString {
        let font = try #require(UIFont(name: "Chalkduster", size: 40))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        attributes.merge(UserReaderFontResolver.syntheticBoldAttributes(for: font, isBoldRequested: bold)) { _, new in new }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// Ink (pixels that are not transparent) and the right-most inked column.
    private static func ink(size: CGSize, _ draw: (CGContext) -> Void) throws -> (count: Int, maxX: Int, maxYFromTop: Int) {
        let width = Int(size.width), height = Int(size.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                count += 1
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return (count, maxX, maxY)
    }

    @Test func theAttributeIsThereForARegularOnlyFont() throws {
        let bold = try Self.text("Bold", bold: true)
        #expect(bold.attribute(BrowserTextAttributes.syntheticBoldOffset, at: 0, effectiveRange: nil) != nil)
        let regular = try Self.text("Bold", bold: false)
        #expect(regular.attribute(BrowserTextAttributes.syntheticBoldOffset, at: 0, effectiveRange: nil) == nil)
    }

    @Test func aLineIsDrawnHeavierAndWiderAlongItself() throws {
        let size = CGSize(width: 400, height: 100)
        let origin = CGPoint(x: 20, y: 30)
        let line = CTLineCreateWithAttributedString(try Self.text("Bold face", bold: true))
        let plain = try Self.ink(size: size) { context in
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        let emboldened = try Self.ink(size: size) { context in
            context.textPosition = origin
            CTLineDraw(line, context)
            SyntheticBoldPass.draw(line, at: origin, in: context)
        }
        #expect(emboldened.count > plain.count + plain.count / 20, "the second pass adds ink")
        // 40 / 36 of a point to the right, and no lower or higher.
        #expect(emboldened.maxX == plain.maxX + 1)
        #expect(emboldened.maxYFromTop == plain.maxYFromTop)
    }

    @Test func textWithoutTheAttributeIsLeftAlone() throws {
        let size = CGSize(width: 400, height: 100)
        let origin = CGPoint(x: 20, y: 30)
        let line = CTLineCreateWithAttributedString(try Self.text("Regular", bold: false))
        let plain = try Self.ink(size: size) { context in
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        let again = try Self.ink(size: size) { context in
            context.textPosition = origin
            CTLineDraw(line, context)
            SyntheticBoldPass.draw(line, at: origin, in: context)
        }
        #expect(again.count == plain.count && again.maxX == plain.maxX)
    }

    @Test func onlyTheMarkedRunsOfAFrameAreDrawnAgain() throws {
        let size = CGSize(width: 400, height: 200)
        let mixed = NSMutableAttributedString(attributedString: try Self.text("plain ", bold: false))
        mixed.append(try Self.text("bold", bold: true))
        let framesetter = CTFramesetterCreateWithAttributedString(mixed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 10, y: 10, width: 380, height: 180), transform: nil), nil)
        let plain = try Self.ink(size: size) { CTFrameDraw(frame, $0) }
        let emboldened = try Self.ink(size: size) { context in
            CTFrameDraw(frame, context)
            SyntheticBoldPass.draw(frame, in: context)
        }
        #expect(emboldened.count > plain.count)
        // All of "plain " drawn twice as well would add far more than "bold" alone can.
        let all = try Self.ink(size: size) { context in
            CTFrameDraw(frame, context)
            context.translateBy(x: 40.0 / 36, y: 0)
            CTFrameDraw(frame, context)
        }
        #expect(emboldened.count < all.count)
    }
}
