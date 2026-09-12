@testable import YueduCoreText
import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserLayoutJustificationTests {
    private let cjk = String(repeating: "春眠不覺曉處處聞啼鳥夜來風雨聲花落知多少", count: 4)
    private let english = String(repeating: "The quiet garden opens to the morning light and distant birds. ", count: 5)

    private func layout(_ html: String, css: String = "", width: CGFloat = 213,
                        alignment: NSTextAlignment = .justified) throws
        -> (BrowserLayoutDocument.BrowserLayoutPipelineResult, [PageFragments]) {
        var config = BrowserLayoutConfig(renderWidth: width, renderHeight: 800, rootFontSize: 20)
        config.defaultTextAlignment = alignment
        config.fontResolver = { _, _, _, size in UIFont.systemFont(ofSize: size) }
        let doc = BrowserLayoutDocument(html: html,
            cssTexts: ["body, p { margin: 0; font-size: 20px; line-height: 28px; } " + css], config: config)
        let result = try doc.makeLayout(containerSize: CGSize(width: width, height: 800))
        return (result, PageFragmentation.fragment(box: result.rootBox,
            pageSize: CGSize(width: width, height: 800)))
    }

    @Test func readerDefaultJustifiesCJKAndEnglishWithMatchingRasterAndSelection() throws {
        for text in [cjk, english] {
            let width: CGFloat = 213
            let (pipeline, pages) = try layout("<p>\(text)</p>", width: width)
            let list = DisplayListBuilder.build(for: try #require(pages.first), sourceText: pipeline.sourceText)
            let items = list.items.compactMap { item -> DisplayTextItem? in
                if case .text(let text) = item { return text }; return nil
            }
            #expect(items.count > 3)
            let image = DisplayListRenderer.render(list, size: CGSize(width: width, height: 800))
            for item in items.prefix(3) {
                let line = try #require(item.ctLine)
                let measured = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                #expect(abs(measured - width) < 0.1)
                #expect(abs(item.rect.maxX - width) < 0.1)
                // Drawing reconstructs attributes from this same retained line.
                let drawnLine = CTLineCreateWithAttributedString(item.attributedText)
                let drawn = CTLineGetTypographicBounds(drawnLine, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(drawnLine)
                #expect(abs(drawn - measured) < 0.1)
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
                let last = trimmed.rangeOfComposedCharacterSequence(at: trimmed.length - 1)
                let source = NSRange(location: item.sourceRange.location + last.location, length: last.length)
                let selection = try #require(BrowserTextGeometry.rects(in: list, range: source).first)
                #expect(abs(selection.maxX - width) < 0.1)
                #expect(try inkPixels(image, in: selection) > 5)
                let caret = try #require(BrowserTextGeometry.caret(at: NSMaxRange(source), isEnd: true, in: list))
                #expect(abs(caret.x - width) < 0.1)
            }
            let last = try #require(items.last)
            let tail = try #require(last.ctLine)
            #expect(CTLineGetTypographicBounds(tail, nil, nil, nil) < width - 1)
        }
    }

    @Test func explicitAlignmentAndInheritedAlignmentOverrideReaderDefault() throws {
        for (css, expected) in [("left", NSTextAlignment.left), ("center", .center), ("right", .right)] {
            let (pipeline, pages) = try layout("<section style='text-align:\(css)'><p>\(cjk)</p></section>")
            let fragment = try #require(BrowserLayoutTestSupport.allTextFragments(pages).first)
            let line = try #require(fragment.ctLine)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            #expect(width < 212)
            let expectedX = expected == .center ? (213 - width) / 2 : (expected == .right ? 213 - width : 0)
            #expect(abs(fragment.rect.minX - expectedX) < 0.1)
            #expect(pipeline.sourceText == cjk)
        }
    }

    @Test func authoredJustifyWorksWithNaturalReaderDefault() throws {
        let (_, pages) = try layout("<p style='text-align:justify'>\(cjk)</p>", alignment: .natural)
        let first = try #require(BrowserLayoutTestSupport.allTextFragments(pages).first)
        #expect(abs(first.rect.width - 213) < 0.1)
    }

    @Test func hardBreakAndParagraphTailNeverStretch() throws {
        let (_, pages) = try layout("<p>春眠不覺曉處處聞<br>夜來風雨聲</p><p>獨立短行</p>")
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(texts.count >= 3)
        for text in texts where text.sourceRange.length > 1 {
            let line = try #require(text.ctLine)
            #expect(CTLineGetTypographicBounds(line, nil, nil, nil) < 200)
        }
    }

    @Test func inlinePaintAndSourceMappingUseExpandedLineGeometryInBothModes() throws {
        let (pipeline, pages) = try layout("<p><span style='background:#800080'>\(cjk)</span></p>")
        let first = try #require(pages.first)
        let paged = DisplayListBuilder.build(for: first, sourceText: pipeline.sourceText)
        let continuous = BrowserScrollDocument.make(pipeline: pipeline, contentWidth: 213, contentInsets: .zero)
        for list in [paged, continuous.displayList] {
            let texts = list.items.compactMap { item -> DisplayTextItem? in
                if case .text(let text) = item { return text }; return nil
            }
            let fills = list.items.compactMap { item -> DisplayFillItem? in
                if case .fill(let fill) = item { return fill }; return nil
            }
            for text in texts.prefix(3) {
                let fill = try #require(fills.first { $0.rect.minY < text.baselineY && $0.rect.maxY > text.baselineY })
                #expect(abs(fill.rect.maxX - 213) < 0.1)
                #expect(abs(text.rect.maxX - fill.rect.maxX) < 0.1)
                let local = try #require(text.ctLine)
                if case .linear(let shaped) = text.sourceMapping {
                    #expect(shaped.location >= CTLineGetStringRange(local).location)
                    #expect(NSMaxRange(shaped) <= CTLineGetStringRange(local).location + CTLineGetStringRange(local).length)
                }
            }
        }
        #expect(continuous.sourceText == cjk)
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: pipeline.sourceText) == cjk)
    }

    private func inkPixels(_ image: UIImage, in rect: CGRect) throws -> Int {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var count = 0
        for y in max(0, Int(rect.minY))..<min(cg.height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(cg.width, Int(rect.maxX)) {
                let offset = (y * cg.width + x) * 4
                if bytes[offset] < 100 && bytes[offset + 1] < 100 && bytes[offset + 2] < 100 { count += 1 }
            }
        }
        return count
    }
}
