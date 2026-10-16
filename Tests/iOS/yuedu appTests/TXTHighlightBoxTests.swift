import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// TXT and online text in a vertical column drew its highlight box across the whole column
/// pitch — the line height, 29.7pt at 18pt × 1.65 — where a horizontal line's box is its
/// text's glyph box: 89px against 76px on the phone (2026-10-15).
@Suite("TXT 高亮框", .serialized)
struct TXTHighlightBoxTests {
    private static let pageSize = CGSize(width: 390, height: 844)
    private static let scale: CGFloat = 3
    private static let fontSize: CGFloat = 18
    /// The first column ends above the quote, so the quote's rows hold its own column alone.
    private static let text = "前。\n他說：“多謝你明天再來”後文。"

    @Test("a vertical box is as thick as a horizontal one is tall, and both sit on their text")
    func verticalBoxMatchesHorizontal() async throws {
        let horizontal = try await Self.render(.horizontal)
        let vertical = try await Self.render(.verticalRTL)
        let line = try #require(horizontal.greenBounds())
        let column = try #require(vertical.greenBounds())

        let thickness = column.width, height = line.height
        #expect(abs(thickness - height) <= 2, "vertical box \(thickness)px thick, horizontal box \(height)px tall")

        // Measured on the ideographs between the quotes: the quotes lie on their side.
        let em = Int(Self.fontSize * Self.scale)
        let half = em / 2, quote = em * 3 / 2, quarter = em / 4
        let columnInk = try #require(vertical.inkBounds(
            x: (column.minX - half)...(column.maxX + half),
            y: (column.minY + quote)...(column.maxY - quote)
        ))
        let columnBoxCentre = column.midX, columnInkCentre = columnInk.midX
        #expect(abs(columnBoxCentre - columnInkCentre) <= Self.scale,
                "vertical box centred at \(columnBoxCentre)px, its text at \(columnInkCentre)px")
        let lineInk = try #require(horizontal.inkBounds(
            x: (line.minX + quote)...(line.maxX - quote),
            y: (line.minY - quarter)...(line.maxY + quarter)
        ))
        let lineBoxCentre = line.midY, lineInkCentre = lineInk.midY
        #expect(abs(lineBoxCentre - lineInkCentre) <= Self.scale,
                "horizontal box centred at \(lineBoxCentre)px, its text at \(lineInkCentre)px")
    }

    /// Scroll mode draws a vertical chunk in the window between the reader's insets. A quote
    /// that runs on into the next column starts that column with its box, and a box's art can
    /// stand above the column — where paged mode paints it in the page margin.
    @Test("a vertical scroll chunk paints a box that stands above its column")
    @MainActor
    func verticalScrollChunkPaintsAboveTheColumn() async throws {
        let text = "他說：「" + String(repeating: "山路を登りながら考えた", count: 3) + "」"
        let builder = TXTLazyAttributedStringBuilder(text: text, chapterIndexes: [
            TXTChapterIndex(index: 0, title: "", contentRange: NSRange(location: 0, length: (text as NSString).length))
        ])
        var settings = EPUBTestFixtures.renderSettings(
            fontSize: Self.fontSize, lineHeightMultiple: 1.65, writingMode: .verticalRTL
        )
        let art = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(
            backgroundColorHex: 0x00FF00, padding: ReaderStyleEdges(leading: 20)))
        settings.regexHighlightConfiguration = RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [
            RegexHighlightRule(id: "art", name: "art", pattern: "「[^」]*」", isEnabled: true, isBuiltIn: false,
                               options: [], lightStyle: art, darkStyle: art)
        ])
        let built = try await builder.buildChapter(
            at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
        )
        // Columns of about 11 characters: the quote runs on through three more.
        let output = CoreTextChunkSlicer.slice(attributedString: built.attributedString, chapterIndex: 0,
                                               contentWidth: 200, heightCap: 400, writingMode: .verticalRTL)
        let chunk = try #require(output.chunks.first)
        let top: CGFloat = 24, bottom: CGFloat = 30
        let cell = CoreTextChunkCollectionCell(frame: CGRect(x: 0, y: 0, width: chunk.width,
                                                             height: top + chunk.height + bottom))
        cell.bind(chunk: chunk, axis: .horizontalRTL, horizontalInset: 0, verticalInset: top,
                  leadingSpacing: 0, viewportSize: cell.bounds.size, bottomInset: bottom)
        cell.layoutIfNeeded()
        cell.drawView.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let shown = PagePixels(try #require(UIGraphicsImageRenderer(bounds: cell.bounds, format: format).image { context in
            cell.layer.render(in: context.cgContext)
        }.cgImage))
        // What the painter paints, with room for it above and below the chunk.
        let painted = PagePixels(try #require(UIGraphicsImageRenderer(bounds: cell.bounds, format: format).image { context in
            context.cgContext.translateBy(x: 0, y: top)
            CoreTextChunkDrawView.draw(chunk, bounds: CGRect(x: 0, y: 0, width: chunk.width, height: chunk.height))
        }.cgImage))

        let fill = try #require(shown.greenBounds())
        #expect(fill.minY < Int(top), "the box starts \(fill.minY)pt down the cell, the column \(Int(top))pt")
        let paintedFill = try #require(painted.greenBounds())
        #expect(abs(fill.minY - paintedFill.minY) <= 1 && abs(fill.maxY - paintedFill.maxY) <= 1,
                "the cell shows the box at \(fill.minY)–\(fill.maxY)pt, the painter puts it at \(paintedFill.minY)–\(paintedFill.maxY)pt")
        // The text stays where it was: only the canvas grew.
        let all = (x: 0...(shown.width - 1), y: 0...(shown.height - 1))
        let ink = try #require(shown.inkBounds(x: all.x, y: all.y))
        let paintedInk = try #require(painted.inkBounds(x: all.x, y: all.y))
        #expect(abs(ink.minY - paintedInk.minY) <= 1 && abs(ink.minX - paintedInk.minX) <= 1,
                "the text starts at (\(ink.minX), \(ink.minY))pt in the cell, (\(paintedInk.minX), \(paintedInk.minY))pt in the chunk")

        // Everything else still works in chunk coordinates.
        #expect(Self.same(cell.drawView.frame, cell.contentView.bounds), "draw view at \(cell.drawView.frame)")
        #expect(cell.drawView.bounds.origin.y == -top)
        #expect(cell.drawView.convert(CGPoint(x: 5, y: top + 10), from: cell.contentView) == CGPoint(x: 5, y: 10))
        cell.applyAnnotations([CoreTextTextAnnotation(spineIndex: 0, range: NSRange(location: 4, length: 6),
                                                      style: .highlight)])
        cell.layoutIfNeeded()
        let overlays = cell.contentView.subviews.filter { $0 is InteractionOverlayView || $0 is NoteMarkerOverlayView }
        #expect(overlays.count >= 4, "selection, playback, note markers and the highlight")
        for overlay in overlays {
            #expect(Self.same(overlay.frame, CGRect(x: 0, y: top, width: chunk.width, height: chunk.height)),
                    "\(type(of: overlay)) at \(overlay.frame)")
        }

        // Reused for a horizontal chunk, the view is the chunk again.
        cell.prepareForReuse()
        cell.bind(chunk: chunk, axis: .vertical, horizontalInset: 0, verticalInset: 0,
                  leadingSpacing: 0, viewportSize: cell.bounds.size)
        cell.layoutIfNeeded()
        #expect(cell.drawView.bounds.origin == .zero)
        #expect(Self.same(cell.drawView.frame, CGRect(x: 0, y: 0, width: chunk.width, height: chunk.height)),
                "draw view at \(cell.drawView.frame)")
    }

    /// Equal once Auto Layout has rounded to the screen's pixels.
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private static func render(_ mode: ReaderWritingMode) async throws -> PagePixels {
        let builder = TXTLazyAttributedStringBuilder(text: text, chapterIndexes: [
            TXTChapterIndex(index: 0, title: "", contentRange: NSRange(location: 0, length: (text as NSString).length))
        ])
        var settings = EPUBTestFixtures.renderSettings(
            fontSize: fontSize, lineHeightMultiple: 1.65, writingMode: mode
        )
        let style = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(backgroundColorHex: 0x00FF00))
        settings.regexHighlightConfiguration = RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [
            RegexHighlightRule(
                id: "txt-box", name: "test", pattern: "“[^”\\n]*”", isEnabled: true, isBuiltIn: false,
                options: [], lightStyle: style, darkStyle: style
            )
        ])
        let built = try await builder.buildChapter(
            at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: built.attributedString, renderSize: pageSize, fontSize: fontSize,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), writingMode: mode
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))
            CoreTextPageView.renderPage(
                layout: layout, pageIndex: 0, in: context.cgContext, bounds: CGRect(origin: .zero, size: pageSize)
            )
        }
        return PagePixels(try #require(image.cgImage))
    }
}

/// A rendered page's pixels, row 0 at the top.
private struct PagePixels {
    struct Bounds {
        let minX: Int, maxX: Int, minY: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midX: CGFloat { CGFloat(minX + maxX) / 2 }
        var midY: CGFloat { CGFloat(minY + maxY) / 2 }
    }

    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 255, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        bytes = buffer
    }

    /// The highlight's fill, where the text does not cover it.
    func greenBounds() -> Bounds? {
        bounds(x: 0...(width - 1), y: 0...(height - 1)) { r, g, b in r < 30 && g > 220 && b < 30 }
    }

    /// The text: dark on white or on the fill.
    func inkBounds(x: ClosedRange<Int>, y: ClosedRange<Int>) -> Bounds? {
        bounds(x: x, y: y) { r, g, b in max(r, g, b) < 128 }
    }

    private func bounds(
        x: ClosedRange<Int>, y: ClosedRange<Int>, where matches: (UInt8, UInt8, UInt8) -> Bool
    ) -> Bounds? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for row in max(0, y.lowerBound)...min(height - 1, y.upperBound) {
            for col in max(0, x.lowerBound)...min(width - 1, x.upperBound) {
                let i = (row * width + col) * 4
                guard matches(bytes[i], bytes[i + 1], bytes[i + 2]) else { continue }
                minX = min(minX, col); maxX = max(maxX, col)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        return minX <= maxX ? Bounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY) : nil
    }
}
