@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreTextTypography
@testable import yuedu_app

/// Selection, the TTS highlight, highlights and notes, taps and inline images are placed
/// against the line the drawer paints (`CoreTextHorizontalLineDrawer.PaintedLine`), not the
/// frame's own line, which CoreText justified its own way.
@Suite("Geometry follows the painted line", .serialized)
@MainActor
struct PaintedLineGeometryTests {
    private let page = CGSize(width: 393, height: 852)
    private let insets = UIEdgeInsets(top: 70, left: 22, bottom: 50, right: 22)
    private var width: CGFloat { page.width - insets.left - insets.right }

    private var marker: String {
        ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="2" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
    }

    enum Paragraph: String, CaseIterable, Sendable {
        /// Feedback #30: the line a 段評 bubble's tail leaves short is drawn at its natural
        /// width; the frame's line is stretched across the column.
        case bubble
        /// The drawer never spreads a line around its punctuation; CoreText does.
        case punctuation
    }

    @Test("each character's rect holds its glyph where it is drawn", arguments: Paragraph.allCases)
    func rectsCoverDrawnGlyphs(_ paragraph: Paragraph) async throws {
        let html: String
        let anchor: String
        switch paragraph {
        case .bubble:
            html = "<p>“爸你能不能有点公德心字啊……”\(marker)</p>"
            anchor = "啊……”"
        case .punctuation:
            let sentence = "他停了一下，說：「好，我們走吧。」然後，她笑了笑，輕聲說：「嗯，走吧！」兩人一前一後，沿著河堤，慢慢走遠了。"
            html = "<p>\(sentence)\(sentence)</p>"
            anchor = "沿著河堤"
        }
        let attributed = try await build(html: html).attributedString
        let miss = try worstMiss(inParagraphOf: anchor, in: attributed)
        #expect(miss.painted <= 0.5, "\(paragraph): \(miss.worst) missed its glyph by \(miss.painted)pt")
        // The frame's own line is what geometry used to measure; it must really be off here,
        // or this test proves nothing.
        #expect(miss.frame > 2, "\(paragraph): the frame's line is only \(miss.frame)pt off")
        print("⏱ PaintedLineGeometry \(paragraph): frame line missed by \(miss.frame)pt, painted line by \(miss.painted)pt")
    }

    /// One step of a selection drag rebuilds the painted lines, finds the character under the
    /// finger and recomputes the selection's rects.
    @Test("a selection step measured on painted lines stays within a frame at 120 Hz")
    func selectionStepCost() async throws {
        let sentence = "他停了一下，說：「好，我們走吧。」然後，她笑了笑，輕聲說：「嗯，走吧！」兩人一前一後，沿著河堤，慢慢走遠了。"
        let built = try await build(html: String(repeating: "<p>\(sentence)\(sentence)</p>", count: 12))
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: LayoutShared(built.attributedString).wrappedValue,
            renderSize: page, fontSize: 20, contentInsets: insets
        )
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layout.renderSize, contentInsets: layout.contentInsets,
            fontSize: layout.fontSize, writingMode: layout.writingMode
        )
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter, range: layout.pageRanges[0],
            path: CGPath(rect: contentPathRect, transform: nil), writingMode: layout.writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        try #require(lines.count > 10)
        let pageRange = layout.pageRanges[0]
        let selection = NSRange(location: pageRange.location + pageRange.length / 4, length: pageRange.length / 2)
        let fingerLine = lines.count / 2
        let steps = 200

        let clock = ContinuousClock()
        var sink = 0
        let frameLines = clock.measure {
            for step in 0..<steps {
                sink &+= GlyphBoundary.index(lines[fingerLine], at: CGFloat(step % 300))
                for (index, line) in lines.enumerated() {
                    let range = CTLineGetStringRange(line)
                    let overlap = NSIntersectionRange(NSRange(location: range.location, length: range.length), selection)
                    guard overlap.length > 0 else { continue }
                    let start = GlyphBoundary.offset(line, at: overlap.location)
                    let end = GlyphBoundary.offset(line, at: NSMaxRange(overlap))
                    _ = CTLineGetTypographicBounds(line, nil, nil, nil)
                    sink &+= Int(origins[index].x + end - start)
                }
            }
        }
        let paintedLines = clock.measure {
            for step in 0..<steps {
                let painted = CoreTextHorizontalLineDrawer.PaintedLines(
                    lines: lines, origins: origins, contentWidth: contentPathRect.width,
                    attributedString: layout.attributedString
                )
                sink &+= painted[fingerLine].index(at: CGFloat(step % 300))
                sink &+= CoreTextAnnotationRenderer.rects(
                    forRange: selection, lines: lines, lineOrigins: origins, painted: painted,
                    layoutHeight: layout.renderSize.height, writingMode: .horizontal
                ).count
            }
        }
        func perStep(_ duration: Duration) -> Double {
            Double(duration.components.attoseconds) / 1e15 / Double(steps)
                + Double(duration.components.seconds) * 1000 / Double(steps)
        }
        print("⏱ PaintedLineGeometry selection step (\(lines.count) lines): frame lines \(perStep(frameLines)) ms, painted lines \(perStep(paintedLines)) ms (\(sink))")
        #expect(perStep(paintedLines) < 8.3)
    }

    // MARK: - Helpers

    /// How far the glyph of a character of the paragraph holding `anchor` reaches outside its
    /// rect, at worst: the rect measured on the painted line, and on the frame's own line.
    ///
    /// The glyph is its own advance, placed where it is drawn: its ink sits at a fixed distance
    /// from its origin, measured with the character drawn alone. Ink is no measure by itself —
    /// a squeezed mark's ink overhangs its advance. A rect may be wider than the glyph: spacing
    /// added between two characters is shared between their rects (`GlyphBoundary`).
    private func worstMiss(
        inParagraphOf anchor: String,
        in attributed: NSAttributedString
    ) throws -> (painted: CGFloat, frame: CGFloat, worst: String) {
        let text = attributed.string as NSString
        let anchorRange = text.range(of: anchor)
        try #require(anchorRange.location != NSNotFound)
        let paragraph = text.paragraphRange(for: anchorRange)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let painted = CoreTextHorizontalLineDrawer.PaintedLines(
            lines: lines, origins: origins, contentWidth: width, attributedString: attributed
        )

        var worst: (painted: CGFloat, frame: CGFloat, worst: String) = (0, 0, "")
        var measured = 0
        for index in lines.indices {
            let cfRange = CTLineGetStringRange(lines[index])
            let lineRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard NSIntersectionRange(lineRange, paragraph).length > 0 else { continue }
            text.enumerateSubstrings(in: lineRange, options: .byComposedCharacterSequences) { _, character, _, _ in
                // A space, the word joiner and the bubble paint no ink of their own.
                guard let ink = inkSpan(of: character, line: index, in: attributed, path: path),
                      let alone = glyph(alone: attributed.attributedSubstring(from: character))
                else { return }
                let drawnAt = ink.lowerBound - alone.ink.lowerBound
                let glyph = drawnAt...(drawnAt + alone.advance)
                func miss(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
                    max(0, start - glyph.lowerBound, glyph.upperBound - end)
                }
                let rect = CoreTextAnnotationRenderer.rects(
                    forRange: character, lines: lines, lineOrigins: origins, painted: painted,
                    layoutHeight: 0, writingMode: .horizontal
                ).first ?? .null
                if miss(rect.minX, rect.maxX) > worst.painted {
                    worst.painted = miss(rect.minX, rect.maxX)
                    worst.worst = "「\(text.substring(with: character))」 at \(character.location) line \(index), rect \(rect.minX)...\(rect.maxX), glyph \(glyph)"
                }
                worst.frame = max(worst.frame, miss(
                    origins[index].x + GlyphBoundary.offset(lines[index], at: character.location),
                    origins[index].x + GlyphBoundary.offset(lines[index], at: NSMaxRange(character))
                ))
                measured += 1
            }
        }
        try #require(measured > 10)
        return worst
    }

    /// Where the drawer paints the ink of `character`, from the content box's left edge: the
    /// line drawn with every other character transparent.
    private func inkSpan(
        of character: NSRange,
        line index: Int,
        in attributed: NSAttributedString,
        path: CGPath
    ) -> ClosedRange<CGFloat>? {
        let masked = NSMutableAttributedString(attributedString: attributed)
        masked.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: 0, length: masked.length))
        masked.addAttribute(.foregroundColor, value: UIColor.black, range: character)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(masked), CFRange(), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
        let pad: CGFloat = 4
        return Self.inkSpan(in: CGSize(width: width + 16, height: ascent + descent + 2 * pad)) { context in
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame, contentWidth: width, contentMinX: 0,
                contentMinY: -(origins[index].y - descent - pad), attrStr: masked,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                lineIndices: IndexSet(integer: index), underline: nil, in: context
            )
        }
    }

    /// Where `character` puts its ink when drawn alone from x = 0, and its advance.
    private func glyph(alone character: NSAttributedString) -> (ink: ClosedRange<CGFloat>, advance: CGFloat)? {
        let line = CTLineCreateWithAttributedString(character)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let pad: CGFloat = 4
        // Drawn `pad` in, so ink left of the origin still lands on the bitmap.
        let span = Self.inkSpan(in: CGSize(width: advance + 4 * pad, height: ascent + descent + 2 * pad)) { context in
            context.textPosition = CGPoint(x: pad, y: descent + pad)
            CTLineDraw(line, context)
        }
        return span.map { (($0.lowerBound - pad)...($0.upperBound - pad), advance) }
    }

    /// The horizontal extent of what `draw` inks on a bitmap of `size`, in points.
    private static func inkSpan(in size: CGSize, draw: (CGContext) -> Void) -> ClosedRange<CGFloat>? {
        let scale: CGFloat = 4
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        var span: ClosedRange<CGFloat>?
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            UIGraphicsPushContext(context)
            draw(context)
            UIGraphicsPopContext()
            let bytes = raw.bindMemory(to: UInt8.self)
            let inked = (0..<pixelWidth).filter { x in
                (0..<pixelHeight).contains { bytes[($0 * pixelWidth + x) * 4 + 3] > 40 }
            }
            if let first = inked.first, let last = inked.last {
                span = CGFloat(first) / scale...CGFloat(last + 1) / scale
            }
        }
        return span
    }

    private func build(html: String) async throws -> AttributedChapterBuildResult {
        let builder = OnlineProviderAttributedStringBuilder(
            provider: OneChapterProvider(html: html),
            renderSize: CGSize(width: width, height: page.height - insets.top - insets.bottom)
        )
        return try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: 20, lineHeightMultiple: 1.6, lineSpacing: 0, paragraphSpacing: 10,
                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
    }
}

private final class OneChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第1章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "第1章",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.com/1"
        )
    }
}
