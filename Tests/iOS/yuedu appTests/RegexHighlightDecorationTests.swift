@testable import YueduCoreText
import CoreGraphics
import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("Regex highlight decoration")
struct RegexHighlightDecorationTests {
    @Test("horizontal padding expands glyph rect in every direction")
    func horizontalPadding() {
        let rect = RegexHighlightDecorationGeometry.expandedRect(
            glyphRect: CGRect(x: 10, y: 20, width: 30, height: 12),
            padding: .init(top: 2, leading: 3, bottom: 4, trailing: 5),
            writingMode: .horizontal
        )

        #expect(rect == CGRect(x: 7, y: 18, width: 38, height: 18))
    }

    @Test("vertical leading and trailing map to the inline column direction")
    func verticalPadding() {
        let rect = RegexHighlightDecorationGeometry.expandedRect(
            glyphRect: CGRect(x: 100, y: 40, width: 18, height: 30),
            padding: .init(top: 2, leading: 3, bottom: 4, trailing: 5),
            writingMode: .verticalRTL
        )

        #expect(rect == CGRect(x: 96, y: 37, width: 24, height: 38))
    }

    @Test("image destination honors fit fill and stretch")
    func imageModes() {
        let source = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .fit
            ) == CGRect(x: 0, y: 25, width: 100, height: 50)
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .fill
            ) == CGRect(x: -50, y: 0, width: 200, height: 100)
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .stretch
            ) == bounds
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: CGSize(width: 20, height: 10),
                bounds: bounds,
                mode: .tile,
                focalX: 0.5,
                focalY: 0.5
            ) == CGRect(x: 40, y: 45, width: 20, height: 10)
        )
    }

    @Test("image focal point positions aspect fill overflow")
    func imageFocalPoint() {
        let destination = RegexHighlightImageGeometry.destination(
            source: CGSize(width: 200, height: 100),
            bounds: CGRect(x: 20, y: 30, width: 100, height: 100),
            mode: .fill,
            focalX: 1,
            focalY: 0
        )

        #expect(destination == CGRect(x: -80, y: 30, width: 200, height: 100))
    }

    @Test("visual gap shrinks only touching inline edges")
    func visualGap() {
        let rect = RegexHighlightDecorationGeometry.applyingInlineGap(
            to: CGRect(x: 10, y: 20, width: 40, height: 12),
            gap: 6,
            hasPreviousFragment: true,
            hasNextFragment: true,
            writingMode: .horizontal
        )

        #expect(rect == CGRect(x: 13, y: 20, width: 34, height: 12))
    }

    // MARK: - Line index space

    /// `CoreTextHorizontalLineDrawer` draws justified lines through a CTLine it rebuilt from the
    /// line's own attributed substring, so that line indexes characters from 0 while decoration
    /// runs carry absolute indices. Passing the absolute indices through unshifted clamped them to
    /// the line's end: every highlight past the first line lost its background entirely.
    @Test("a line rebuilt from its own substring anchors decorations to the right glyphs")
    func rebuiltLineRebasesDecorationIndices() {
        let sample = DecorationLineSample()
        let line = CTLineCreateWithAttributedString(
            sample.attributed.attributedSubstring(from: sample.lineRange)
        )

        let fragments = RegexHighlightDecorationRenderer.horizontalFragments(
            line: line,
            origin: .zero,
            attributedString: sample.attributed,
            range: sample.lineRange
        )

        let expected = sample.expectedSpan(in: line, lineIndexOrigin: 0)
        #expect(fragments.count == 1)
        #expect(abs((fragments.first?.rect.minX ?? .nan) - expected.minX) < 0.5)
        #expect(abs((fragments.first?.rect.width ?? .nan) - expected.width) < 0.5)
        // The old behaviour ran the box from a wrong start all the way to the line's end.
        #expect((fragments.first?.rect.maxX ?? .nan) < sample.lineWidth(of: line) - 0.5)
    }

    @Test("a line keeping absolute string indices is unaffected by the rebasing")
    func absoluteLineKeepsDecorationIndices() {
        let sample = DecorationLineSample()
        let typesetter = CTTypesetterCreateWithAttributedString(sample.attributed)
        let line = CTTypesetterCreateLine(
            typesetter,
            CFRange(location: sample.lineRange.location, length: sample.lineRange.length)
        )

        let fragments = RegexHighlightDecorationRenderer.horizontalFragments(
            line: line,
            origin: .zero,
            attributedString: sample.attributed,
            range: sample.lineRange
        )

        let expected = sample.expectedSpan(in: line, lineIndexOrigin: sample.lineRange.location)
        #expect(fragments.count == 1)
        #expect(abs((fragments.first?.rect.minX ?? .nan) - expected.minX) < 0.5)
        #expect(abs((fragments.first?.rect.width ?? .nan) - expected.width) < 0.5)
    }

    @Test("a highlight running past the line end stops at the line's last glyph")
    func decorationClampsToLineEnd() {
        let sample = DecorationLineSample(highlightRunsPastLineEnd: true)
        let line = CTLineCreateWithAttributedString(
            sample.attributed.attributedSubstring(from: sample.lineRange)
        )

        let fragments = RegexHighlightDecorationRenderer.horizontalFragments(
            line: line,
            origin: .zero,
            attributedString: sample.attributed,
            range: sample.lineRange
        )

        let expectedStart = CGFloat(
            CTLineGetOffsetForStringIndex(
                line,
                sample.highlightRange.location - sample.lineRange.location,
                nil
            )
        )
        #expect(fragments.count == 1)
        #expect(abs((fragments.first?.rect.minX ?? .nan) - expectedStart) < 0.5)
        #expect(abs((fragments.first?.rect.maxX ?? .nan) - sample.lineWidth(of: line)) < 0.5)
    }

    // MARK: - Baseline offset

    /// Online and TXT body text centres itself in its line with `.baselineOffset`, which
    /// CoreText draws as a raise of every glyph. The box was built on the unraised baseline,
    /// so every highlight in those books sat low: the gap below the text was the gap above
    /// it plus twice the raise (online book, 2026-10-15).
    @Test("a raised baseline raises the highlight box with its glyphs")
    func baselineOffsetRaisesTheBox() throws {
        let flat = try RaisedLineSample(raise: 0).measure()
        let raised = try RaisedLineSample(raise: 8).measure()

        // The glyphs really are drawn higher — the premise of the fix.
        #expect(abs((flat.inkTop - raised.inkTop) - 8) <= 1)
        // The box keeps the same place around them.
        #expect(abs((raised.inkTop - raised.boxTop) - (flat.inkTop - flat.boxTop)) <= 1)
        #expect(abs((raised.boxBottom - raised.inkBottom) - (flat.boxBottom - flat.inkBottom)) <= 1)
    }
}

/// One line of quoted CJK on a red highlight, drawn the way `CoreTextHorizontalLineDrawer`
/// draws it: the decoration and then the glyphs, from one origin.
private struct RaisedLineSample {
    let raise: CGFloat

    /// Rows counted down from the top of the bitmap.
    struct Rows { let boxTop: Int, boxBottom: Int, inkTop: Int, inkBottom: Int }

    func measure() throws -> Rows {
        let text = NSMutableAttributedString(string: "“多謝。”", attributes: [
            .font: UIFont(name: "PingFangSC-Regular", size: 40) ?? UIFont.systemFont(ofSize: 40),
            .foregroundColor: UIColor.black,
            .baselineOffset: raise,
        ])
        let range = NSRange(location: 0, length: text.length)
        text.addAttribute(
            RegexHighlightDecoration.attributeKey,
            value: RegexHighlightDecoration(
                style: ReaderStyleDecorationStyle(backgroundColorHex: 0xFF0000),
                assetRevision: 0
            ),
            range: range
        )
        let width = 260, height = 140
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(text)
        let origin = CGPoint(x: 10, y: 50)
        RegexHighlightDecorationRenderer.drawHorizontal(
            line: line, origin: origin, attributedString: text, range: range, context: context
        )
        context.textPosition = origin
        CTLineDraw(line, context)

        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var box: [Int] = [], ink: [Int] = []
        for row in 0..<height {
            var hasBox = false, hasInk = false
            for column in 0..<width {
                let p = pixels + (row * width + column) * 4
                let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
                if r > 200, g < 80, b < 80 { hasBox = true }
                if r < 90, g < 90, b < 90 { hasInk = true }
            }
            if hasBox { box.append(row) }
            if hasInk { ink.append(row) }
        }
        return Rows(
            boxTop: try #require(box.first), boxBottom: try #require(box.last),
            inkTop: try #require(ink.first), inkBottom: try #require(ink.last)
        )
    }
}

/// Two paragraphs where the highlighted quote sits in the SECOND one, so an unshifted absolute
/// index cannot accidentally land on the right glyph.
private struct DecorationLineSample {
    let attributed: NSAttributedString
    let lineRange: NSRange
    let highlightRange: NSRange

    init(highlightRunsPastLineEnd: Bool = false) {
        let firstParagraph = "前段文字。\n"
        let secondParagraph = "他說“對話文字”然後離開。"
        let text = firstParagraph + secondParagraph
        let mutable = NSMutableAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        )
        let nsText = text as NSString
        let quoted = nsText.range(of: "“對話文字”")
        let highlight = highlightRunsPastLineEnd
            ? NSRange(
                location: quoted.location,
                length: nsText.length - quoted.location
            )
            : quoted
        mutable.addAttribute(
            RegexHighlightDecoration.attributeKey,
            value: RegexHighlightDecoration(
                style: ReaderStyleDecorationStyle(backgroundColorHex: 0x8E1B3A),
                assetRevision: 0
            ),
            range: highlight
        )

        attributed = mutable
        let lineStart = (firstParagraph as NSString).length
        // The drawn line covers the second paragraph only; on the "runs past" variant the
        // highlight deliberately extends beyond it.
        let lineLength = highlightRunsPastLineEnd
            ? (secondParagraph as NSString).length - 3
            : (secondParagraph as NSString).length
        lineRange = NSRange(location: lineStart, length: lineLength)
        highlightRange = highlight
    }

    func expectedSpan(in line: CTLine, lineIndexOrigin: Int) -> (minX: CGFloat, width: CGFloat) {
        let shift = lineIndexOrigin - lineRange.location
        let start = CGFloat(
            CTLineGetOffsetForStringIndex(line, highlightRange.location + shift, nil)
        )
        let end = CGFloat(
            CTLineGetOffsetForStringIndex(line, NSMaxRange(highlightRange) + shift, nil)
        )
        return (min(start, end), abs(end - start))
    }

    func lineWidth(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
