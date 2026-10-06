import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// Authored 縦中横 in the legacy engine: the characters stay in the string, a run
/// delegate gives them one em of the column, and the page view and the scroll chunks
/// draw them horizontally in that cell.
@Suite("Legacy 縦中横", .serialized)
struct LegacyTateChuYokoTests {
    private static let fontSize: CGFloat = 18

    private func prepared(_ body: String) async -> NSAttributedString {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: Self.fontSize, lineHeightMultiple: 1.0, lineSpacing: 0, paragraphSpacing: 0,
            firstLineIndent: 0, textColor: .black, backgroundColor: .white, fontFamilyName: nil,
            renderWidth: 240, writingMode: .verticalRTL
        )
        let result = await builder.build(html: "<html><body><p>\(body)</p></body></html>", config: config)
        return CoreTextPaginator.preparedAttributedString(result.attributedString, writingMode: .verticalRTL,
                                                          fontSize: Self.fontSize, maxInlineAnnotationAdvance: nil)
    }

    @Test("The cell keeps its characters and covers them")
    func characters() async throws {
        let text = await prepared("第<span style=\"text-combine-upright:all\">12</span>回")
        let digits = (text.string as NSString).range(of: "12")
        #expect(text.string.contains("第12回"))
        let cell = try #require(text.attribute(HTMLAttributedStringBuilder.combinedUprightCellAttribute,
                                               at: digits.location, effectiveRange: nil) as? CoreTextPaginator.CombinedUprightCell)
        #expect(cell.range == digits)
        #expect(text.attribute(HTMLAttributedStringBuilder.combinedUprightCellAttribute,
                               at: digits.location - 1, effectiveRange: nil) == nil)
    }

    @Test("`digits 2` makes cells of two-digit runs only")
    func digits() async {
        let text = await prepared("<span style=\"text-combine-upright:digits 2\">第12回と2014年</span>")
        var cells: [String] = []
        text.enumerateAttribute(HTMLAttributedStringBuilder.combinedUprightCellAttribute,
                                in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { cells.append((text.string as NSString).substring(with: range)) }
        }
        #expect(cells == ["12"])
    }

    @Test("A scroll chunk draws the cell's text horizontally inside it")
    func scrollChunk() async throws {
        let text = await prepared("第<span style=\"color:#FF0000;text-combine-upright:all\">12</span>回")
        let output = CoreTextChunkSlicer.slice(attributedString: text, chapterIndex: 0, contentWidth: 240,
                                               writingMode: .verticalRTL)
        let chunk = try #require(output.chunks.first { !$0.combinedUprightCells.isEmpty })
        let cell = try #require(chunk.combinedUprightCells.first)
        #expect(abs(cell.uiRect.height - Self.fontSize) < 0.01)
        let image = await MainActor.run {
            let view = CoreTextChunkDrawView(frame: CGRect(origin: .zero, size: CGSize(width: chunk.width, height: chunk.height)))
            view.backgroundColor = .white
            view.chunk = chunk
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.cgContext.fill(view.bounds)
                view.draw(view.bounds)
            }
        }
        let cgImage = try #require(image.cgImage)
        let red = try #require(redInk(in: cgImage, scale: 2))
        // Inside the cell, and side by side: wider across the column than along it.
        #expect(cell.uiRect.insetBy(dx: -1, dy: -1).contains(red), "red \(red) cell \(cell.uiRect)")
        #expect(red.width > red.height, "red \(red)")
    }

    /// The bounding box of red pixels, in points.
    private func redInk(in image: CGImage, scale: CGFloat) -> CGRect? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var box = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard bytes[i] > 180, bytes[i + 1] < 120, bytes[i + 2] < 120 else { continue }
                box = box.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
            }
        }
        return box.isNull ? nil : box
    }
}
