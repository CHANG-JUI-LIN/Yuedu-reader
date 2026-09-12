@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct BrowserLayoutInlineRunGeometryTests {
    @Test(arguments: ["AV", "To", "office", "fi", "字，字"])
    func adjacentDOMRunsUseTheShapedLineGeometry(_ text: String) throws {
        var style = ComputedStyle()
        style.fontFamilies = ["TimesNewRomanPSMT"]
        style.fontSize = 40
        let ns = text as NSString
        let runs = [
            InlineRun(text: ns.substring(to: 1), style: style, sourceRange: NSRange(location: 0, length: 1), nodeID: 1),
            InlineRun(text: ns.substring(from: 1), style: style, sourceRange: NSRange(location: 1, length: ns.length - 1), nodeID: 2)
        ]
        let lines = InlineLayout.layoutLines(runs: runs, context: InlineFormattingContext(
            containingInlineSize: 500, rootFontSize: 40, lineHeight: nil,
            writingMode: .horizontal, sourceText: text, fontResolver: nil,
            floatContext: nil, blockOffsetY: 0
        ))
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let shaped = try #require(line.ctLine)
        #expect(line.runs.count == 2)
        for run in line.runs {
            let range = try #require(run.shapedRange)
            let start = CTLineGetOffsetForStringIndex(shaped, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(shaped, NSMaxRange(range), nil)
            #expect(abs(run.x - min(start, end)) < 0.0001)
            #expect(abs(run.width - abs(end - start)) < 0.0001)
        }
    }
    @Test func laterLinesKeepParagraphStringIndices() throws {
        let text = "AVAVAVAV"
        var style = ComputedStyle()
        style.fontFamilies = ["TimesNewRomanPSMT"]
        style.fontSize = 40
        let runs = text.enumerated().map { index, character in
            InlineRun(text: String(character), style: style,
                      sourceRange: NSRange(location: index, length: 1), nodeID: index)
        }
        let lines = InlineLayout.layoutLines(runs: runs, context: InlineFormattingContext(
            containingInlineSize: 90, rootFontSize: 40, lineHeight: nil,
            writingMode: .horizontal, sourceText: text, fontResolver: nil,
            floatContext: nil, blockOffsetY: 0
        ))
        #expect(lines.count > 1)
        #expect(lines.flatMap(\.runs).map(\.sourceRange) == runs.map(\.sourceRange))
        for line in lines {
            let shaped = try #require(line.ctLine)
            let lineRange = CTLineGetStringRange(shaped)
            var glyphEnd: CGFloat = 0
            for native in CTLineGetGlyphRuns(shaped) as! [CTRun] {
                let count = CTRunGetGlyphCount(native)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetPositions(native, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(native, CFRange(location: 0, length: 0), &advances)
                for (position, advance) in zip(positions, advances) {
                    glyphEnd = max(glyphEnd, position.x + advance.width)
                }
            }
            for run in line.runs {
                let range = try #require(run.shapedRange)
                let start = CTLineGetOffsetForStringIndex(shaped, range.location, nil)
                // At a soft break, CoreText's end caret can extend beyond
                // the final glyph advance (e.g. a trailing kerned A in AVA).
                // The fragment owns the typographic advance, not that caret.
                let end = NSMaxRange(range) == lineRange.location + lineRange.length
                    ? glyphEnd
                    : CTLineGetOffsetForStringIndex(shaped, NSMaxRange(range), nil)
                #expect(abs(run.x - start) < 0.0001)
                #expect(abs(run.width - (end - start)) < 0.0001)
            }
        }
    }

    @Test(arguments: ["אבגד", "سلام"])
    func rtlDOMSlicesUseTheGlyphRunsOwnBoundaryAffinity(_ text: String) throws {
        var style = ComputedStyle()
        style.fontFamilies = ["TimesNewRomanPSMT"]
        style.fontSize = 40
        let ns = text as NSString
        let runs = [
            InlineRun(text: ns.substring(to: 1), style: style, sourceRange: NSRange(location: 0, length: 1), nodeID: 1),
            InlineRun(text: ns.substring(from: 1), style: style, sourceRange: NSRange(location: 1, length: ns.length - 1), nodeID: 2)
        ]
        let lines = InlineLayout.layoutLines(runs: runs, context: InlineFormattingContext(
            containingInlineSize: 500, rootFontSize: 40, lineHeight: nil,
            writingMode: .horizontal, sourceText: text, fontResolver: nil,
            floatContext: nil, blockOffsetY: 0
        ))
        let line = try #require(lines.first)
        let shaped = try #require(line.ctLine)
        #expect((CTLineGetGlyphRuns(shaped) as! [CTRun]).contains { CTRunGetStatus($0).contains(.rightToLeft) })
        for run in line.runs {
            let range = try #require(run.shapedRange)
            let start = CTLineGetOffsetForStringIndex(shaped, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(shaped, NSMaxRange(range), nil)
            #expect(abs(run.width - abs(end - start)) < 0.0001)
        }
    }

    @Test func spanFragmentsStayAlignedWithTheDrawnGlyphs() async throws {
        let css = ["body, p { margin: 0; font-family: TimesNewRomanPSMT; font-size: 40px; }"]
        let result = try await BrowserLayoutTestSupport.layout("<p>A<span>V</span></p>", cssTexts: css)
        let fragments = BrowserLayoutTestSupport.allTextFragments(result.pages)
        #expect(fragments.count == 2)
        #expect(BrowserLayoutTestSupport.visibleText(result.pages, sourceText: result.doc.lastSourceText) == "AV")
        let first = try #require(fragments.first)
        let second = try #require(fragments.last)
        let line = try #require(first.ctLine)
        let boundary = CTLineGetOffsetForStringIndex(line, 1, nil)
        #expect(abs(first.rect.width - boundary) < 0.0001)
        #expect(abs(second.rect.minX - first.rect.minX - boundary) < 0.0001)
    }

}
