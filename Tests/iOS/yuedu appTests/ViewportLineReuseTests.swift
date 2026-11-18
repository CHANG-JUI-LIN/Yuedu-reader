import CoreText
import Testing
import UIKit
@testable import YueduCoreText
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ViewportLineReuseTests {
    @Test func cursorDoesNotRetainItsOwnerThroughTheInstallationCallback() {
        weak var observed: CursorOwner?
        autoreleasepool {
            let owner = CursorOwner()
            observed = owner
            let (runs, context) = fixture(indent: 0)
            _ = InlineLayout.layoutLines(runs: runs, context: context) { owner.cursor = $0 }
            #expect(owner.cursor != nil)
        }
        #expect(observed == nil, "discarding a viewport entry must release its cursor and CoreText resources")
    }

    @Test func resolvedPublicationFallbackFontsPreserveJustifiedPixels() throws {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let registration = try #require(CoreTextFontRegistrationService().registerFont(
            data: Data(contentsOf: fontURL), alias: "viewport-justification", existingTempURL: nil))
        for name in [registration.postScriptName, "TimesNewRomanPSMT"] {
            for spacing in ["normal", "1.25px"] {
                let text = String(repeating: "ABC <b>春眠不覺曉</b> 👩🏽‍💻 é <i>中文標點，。！？</i> ", count: 12)
                let html = "<p style='letter-spacing:\(spacing)'>\(text)</p>"
                var config = BrowserLayoutConfig(renderWidth: 213, renderHeight: 600, rootFontSize: 20)
                config.defaultTextAlignment = .justified
                config.fontResolver = { _, _, _, size in UIFont(name: name, size: size) }
                let reference = try HTMLLayoutDocument(html: html, configuration: config).prepareContinuous().makeDocument()
                let session = try HTMLLayoutDocument(html: html, configuration: config).makeViewportSession()
                let rect = CGRect(x: 0, y: 0, width: 213, height: reference.contentHeight + 1)
                let actual = try session.layout(in: rect)
                #expect(actual.sourceText == reference.sourceText)
                #expect(actual.contentHeight == reference.contentHeight)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                func pixels(_ document: BrowserScrollDocument) -> Data? {
                    UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
                        UIColor.white.setFill(); ctx.fill(rect)
                        document.items(in: rect).draw(in: ctx.cgContext)
                    }.pngData()
                }
                let expected = try #require(pixels(reference))
                let drawn = try #require(pixels(actual))
                #expect(drawn == expected,
                        "publication font, fallback CJK, emoji and kern must keep the same pixels: \(name) \(spacing)")
            }
        }
    }
    @Test func stableWidthShapesEachLineOnceIncludingCheckpointReplay() throws {
        for indent: CGFloat in [0, 32, 240] {
            let (runs, context) = fixture(indent: indent)
            var cursor: InlineLayoutCursor?
            _ = InlineLayout.layoutLines(runs: runs, context: context) { cursor = $0 }
            let actual = try #require(cursor)
            var checkpoints: [InlineLayoutCheckpoint] = []
            var lines: [LayoutLine] = []
            while true {
                let checkpoint = actual.checkpoint
                guard let line = actual.next() else { break }
                checkpoints.append(checkpoint)
                lines.append(line)
            }
            #expect(lines.count > 4)
            #expect(actual.lineBreakAttempts == lines.count,
                    "rechecking the true line height must not shape unchanged width twice")
            let reference = InlineLayout.layoutLines(runs: runs, context: context)
            try compare(lines, reference)
            // Replaying an evicted line from a measured checkpoint has the same
            // source, metrics and caret geometry as its original materialization.
            let middle = lines.count / 2
            actual.checkpoint = checkpoints[middle]
            let replayed = try #require(actual.next())
            #expect(actual.lineBreakAttempts == lines.count + 1)
            try compare([replayed], [lines[middle]])
        }
    }

    @Test func fullHeightFloatBandStillRebreaksWhenWidthChanges() throws {
        for side: CSSFloat in [.left, .right] {
            let floats = FloatContext(containerWidth: 220)
            floats.placeFloat(side: side, marginBoxSize: CGSize(width: 90, height: 70),
                              margins: .zero, startY: 8)
            let (runs, context) = fixture(indent: 24, floats: floats)
            var cursor: InlineLayoutCursor?
            _ = InlineLayout.layoutLines(runs: runs, context: context) { cursor = $0 }
            let actual = try #require(cursor)
            var lines: [LayoutLine] = []
            while let line = actual.next() { lines.append(line) }
            #expect(actual.lineBreakAttempts > lines.count,
                    "a float starting inside the true line band must force a new break")
            try compare(lines, InlineLayout.layoutLines(runs: runs, context: context))
        }
    }

    private func fixture(indent: CGFloat, floats: FloatContext? = nil) -> ([InlineRun], InlineFormattingContext) {
        let text = String(repeating: "中文排版測試 office é 👩🏽‍💻 字元。 ", count: 10)
        var style = ComputedStyle()
        style.fontSize = 20
        style.lineHeight = 30
        let runs = [InlineRun(text: text, style: style,
                              sourceRange: NSRange(location: 0, length: (text as NSString).length))]
        return (runs, InlineFormattingContext(containingInlineSize: 220, rootFontSize: 20,
            lineHeight: 30, writingMode: .horizontal, sourceText: text,
            fontResolver: { _, _, _, size in UIFont.systemFont(ofSize: size) },
            floatContext: floats, blockOffsetY: 0,
            firstLineConstraint: InlineFirstLineConstraint(textIndent: indent),
            paragraphStyle: style, fontCache: InlineFontCache()))
    }

    private func compare(_ actual: [LayoutLine], _ expected: [LayoutLine]) throws {
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(a.top == b.top && a.height == b.height && a.baseline == b.baseline)
            #expect(a.runs.map(\.sourceRange) == b.runs.map(\.sourceRange))
            #expect(a.runs.map(\.x) == b.runs.map(\.x))
            #expect(a.runs.map(\.width) == b.runs.map(\.width))
            let ca = try #require(a.ctLine), cb = try #require(b.ctLine)
            let range = CTLineGetStringRange(cb)
            #expect(CTLineGetStringRange(ca).location == range.location)
            #expect(CTLineGetStringRange(ca).length == range.length)
            for offset in range.location...(range.location + range.length) {
                #expect(CTLineGetOffsetForStringIndex(ca, offset, nil)
                        == CTLineGetOffsetForStringIndex(cb, offset, nil))
            }
        }
    }
}

@MainActor private final class CursorOwner {
    var cursor: InlineLayoutCursor?
}
