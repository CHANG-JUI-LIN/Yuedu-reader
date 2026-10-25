@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A 段評 bubble belongs to its paragraph's last character. CoreText may break a line right
/// before an attachment, so a paragraph whose last line was full put its bubble alone at the
/// start of the next line (起点 qimo 第2章, paragraph 68).
@Suite("段評 bubble stays on its paragraph's last line", .serialized)
@MainActor
struct CommentBubbleLineEndTests {
    private let page = CGSize(width: 393, height: 852)
    private let insets = UIEdgeInsets(top: 70, left: 22, bottom: 50, right: 22)

    private var marker: String {
        ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="2" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
    }

    @Test("the bubble never opens a line, whatever the paragraph's length")
    func bubbleNeverOpensALine() async throws {
        for length in 8...40 {
            let text = String(repeating: "字", count: length - 2) + "。”"
            let layout = try await layout(html: "<p>\(text)\(marker)</p>")
            let bubble = try #require(
                layout.inlineAttachments.values.flatMap { $0 }
                    .first { $0.linkHref?.hasPrefix("ydreview://") == true }
            )
            #expect(bubble.rect.minX > insets.left + 1, "\(length) characters: the bubble opened a line")
        }
    }

    @Test("a word joiner holds the bubble to the text, outside its review link")
    func bubbleIsGluedOutsideItsLink() async throws {
        let attributed = try await build(html: "<p>正文。”\(marker)</p>").attributedString
        let glue = try #require(attributed.string.range(of: "。”\u{2060}\u{FFFC}"))
        let joiner = NSRange(glue, in: attributed.string).location + 2
        #expect(attributed.attribute(HTMLAttributedStringBuilder.internalLinkAttribute, at: joiner, effectiveRange: nil) == nil)
        #expect(attributed.attribute(HTMLAttributedStringBuilder.internalLinkAttribute, at: joiner + 1, effectiveRange: nil) != nil)
    }

    /// Feedback #30 (2026-10-20, iOS 17.0): 「“爸你能不能有点公德心」 was stretched across the
    /// whole line with 「啊……”(10)」 alone below it. The glue brings the last character down
    /// together with every mark that cannot start a line, and the line that leaves short was
    /// justified like any other.
    ///
    /// The same paragraph without a bubble is the reference: where 「啊……”」 does not fit
    /// even on its own, the marks that cannot start a line push it down and that line is
    /// justified as before. The bubble must not add spacing of its own — also when a page
    /// ends right after that line and the tail opens the next page.
    @Test("the line a bubble's tail leaves short is not stretched apart")
    func lineBeforeBubbleKeepsItsSpacing() async throws {
        var worst: (length: Int, pageEnds: Bool, added: CGFloat) = (0, false, 0)
        for length in 4...40 {
            let text = "“" + String(repeating: "字", count: length) + "啊……”"
            let plain = try await build(html: "<p>\(text)</p>").attributedString
            let withBubble = try await build(html: "<p>\(text)\(marker)</p>").attributedString
            let reference = try stretchPerGap(beforeLastLineOf: "啊……”", in: plain).max() ?? 0
            for pageEnds in [false, true] {
                let drawn = try stretchPerGap(beforeLastLineOf: "啊……”", in: withBubble,
                                              pageEndsBeforeLastLine: pageEnds).max() ?? 0
                if drawn - reference > worst.added {
                    worst = (length, pageEnds, drawn - reference)
                }
            }
        }
        #expect(worst.added <= 0.5, """
            \(worst.length) characters\(worst.pageEnds ? ", page ending before the tail" : ""): \
            the bubble added \(worst.added)pt between characters
            """)
    }

    /// Feedback #62 and #67 (2026-10-23): 「“你这和尚，是给你师兄送人」 over 「罢。”(9)」, and
    /// 「迅速解决，稳定Z市的局」 over 「势。(2)」 — the text fit its line, the bubble did not, and
    /// the glue took the tail down with it. The line's full-width marks give up part of their
    /// blank instead (`ReviewBubbleLineFit`), so the bubble costs the paragraph no line where
    /// they have the room, and the squeezed line still ends inside the column.
    @Test("a bubble's tail stays on its line when the line's marks make room")
    func squeezedMarksKeepTheTailUp() async throws {
        let width = page.width - insets.left - insets.right
        var squeezed = 0
        for length in 4...40 {
            let text = "“" + String(repeating: "字", count: length) + "，字，送人罢。”"
            let plain = try await build(html: "<p>\(text)</p>").attributedString
            let withBubble = try await build(html: "<p>\(text)\(marker)</p>").attributedString
            let plainLines = try lines(ofParagraphHolding: "送人罢", in: plain, width: width)
            let bubbleLines = try lines(ofParagraphHolding: "送人罢", in: withBubble, width: width)
            #expect(bubbleLines.count == plainLines.count, "\(length) characters: the bubble took the tail to a line of its own")
            let fullStop = (withBubble.string as NSString).range(of: "罢。”").location + 1
            if ((withBubble.attribute(.kern, at: fullStop, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0) < 0 {
                squeezed += 1
            }

            let layout = await CoreTextPaginator().paginate(
                spineIndex: 0, attrStr: LayoutShared(withBubble).wrappedValue,
                renderSize: page, fontSize: 20, contentInsets: insets
            )
            let bubble = try #require(
                layout.inlineAttachments.values.flatMap { $0 }.first { $0.linkHref?.hasPrefix("ydreview://") == true }
            )
            #expect(bubble.rect.maxX <= page.width - insets.right + 0.5, "\(length) characters: the bubble ends at \(bubble.rect.maxX)")
        }
        #expect(squeezed > 0, "no length needed the squeeze: the test no longer reaches it")
    }

    /// Feedback #63 (iOS 17.0): every line holding a bubble stood 5.7pt further from the line
    /// above than the rest. The bubble's run claimed more ascent than the font's own. At
    /// 整體大小 ×2 (2026-10-25, iOS 27 simulator) a bubble taller than the ascender but shorter
    /// than its 33pt line still moved that line 4pt down the page's baseline grid, and one
    /// taller than its 25pt line at 20pt × 1.2 opened every line of its paragraph to 28pt. A
    /// bubble that fits its line leaves the line where the text's lines are; one taller than
    /// its line grows that line alone, evenly above and below, rather than spilling onto the
    /// lines around it.
    @Test("a bubble keeps its line on the baseline grid")
    func bubbleLineKeepsTheLineHeight() async throws {
        let settings = GlobalSettings.shared
        let saved = (settings.commentBubbleFollowsSourceSVG, settings.commentBubbleScale)
        defer {
            settings.commentBubbleFollowsSourceSVG = saved.0
            settings.commentBubbleScale = saved.1
        }
        let width = page.width - insets.left - insets.right
        let text = String(repeating: "字", count: 50) + "。"
        var failures: [String] = []
        var grown = 0
        var paged = 0
        // ×1.8: at 20pt × 1.2 taller than its 25pt line, shorter than the 28pt PingFang takes.
        for (followsSource, scale) in [(true, 1.0), (false, 1.5), (false, 1.8), (false, 2.0)] {
            settings.commentBubbleFollowsSourceSVG = followsSource
            settings.commentBubbleScale = scale
            for fontSize: CGFloat in [16, 18, 20, 26] {
                for lineHeightMultiple: CGFloat in [1.2, 1.65, 2.2] {
                    let attributed = try await build(
                        html: "<p>\(text)\(marker)</p><p>\(text)</p><p>\(text)</p>",
                        fontSize: fontSize, lineHeightMultiple: lineHeightMultiple
                    ).attributedString
                    let string = attributed.string as NSString
                    let bubble = string.range(of: "\u{2060}\u{FFFC}").location + 1
                    let lastParagraph = string.paragraphRange(for: NSRange(location: string.length - 1, length: 0)).location
                    let delegate = attributed.attribute(
                        NSAttributedString.Key(kCTRunDelegateAttributeName as String), at: bubble, effectiveRange: nil
                    ) as! CTRunDelegate
                    let height = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(delegate)).takeUnretainedValue().drawHeight
                    let bubbleSize = followsSource ? "source size" : "×\(scale)"
                    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                    let tall = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)

                    // The steps around the bubble's line, less the text's own steps in the
                    // paragraphs without a bubble: between two lines of one, and between two.
                    func steps(lines: [CTLine], origins: [CGPoint]) -> (above: CGFloat, below: CGFloat, before: CGFloat, lineStep: CGFloat)? {
                        func line(holding index: Int) -> Int? {
                            lines.firstIndex {
                                let range = CTLineGetStringRange($0)
                                return index >= range.location && index < range.location + range.length
                            }
                        }
                        guard let bubbleLine = line(holding: bubble), let last = line(holding: lastParagraph),
                              bubbleLine > 1, last > bubbleLine + 2, last + 1 < lines.count
                        else { return nil }
                        let lineStep = origins[last].y - origins[last + 1].y
                        let paragraphStep = origins[last - 1].y - origins[last].y
                        return (
                            origins[bubbleLine - 1].y - origins[bubbleLine].y - lineStep,
                            origins[bubbleLine].y - origins[bubbleLine + 1].y - paragraphStep,
                            origins[bubbleLine - 2].y - origins[bubbleLine - 1].y - lineStep,
                            lineStep
                        )
                    }
                    func check(_ route: String, lines: [CTLine], origins: [CGPoint]) -> (above: CGFloat, lineStep: CGFloat)? {
                        guard let measured = steps(lines: lines, origins: origins) else { return nil }
                        let (above, below, before, lineStep) = measured
                        let setup = "\(route), \(fontSize)pt × \(lineHeightMultiple), bubble \(bubbleSize) \(height)pt in a \(lineStep)pt line"
                        if abs(before) > 0.5 {
                            failures.append("\(setup): the paragraph's other lines moved \(before)pt apart")
                        }
                        if height <= lineStep {
                            if abs(above) > 0.5 || abs(below) > 0.5 {
                                failures.append("\(setup): the line moved \(above)pt from the line above, \(-below)pt from the one below")
                            }
                        } else if abs(above - below) > 1 || above + below < height - lineStep - 1 {
                            failures.append("\(setup): the line grew \(above)pt above and \(below)pt below")
                        }
                        return (above, lineStep)
                    }

                    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), tall, nil)
                    let lines = CTFrameGetLines(frame) as! [CTLine]
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                    let measured = try #require(check("a frame", lines: lines, origins: origins))
                    if height > measured.lineStep { grown += 1 }

                    // As the reader pages it: the page's own frame and line origins.
                    let layout = await CoreTextPaginator().paginate(
                        spineIndex: 0, attrStr: LayoutShared(attributed).wrappedValue,
                        renderSize: page, fontSize: fontSize, contentInsets: insets
                    )
                    if let artifact = layout.pageArtifacts.first(where: { artifact in
                        let range = CTFrameGetStringRange(artifact.frame)
                        return range.location <= bubble && lastParagraph < range.location + range.length
                    }), check("a page", lines: CTFrameGetLines(artifact.frame) as! [CTLine], origins: artifact.lineOrigins) != nil {
                        paged += 1
                    }

                    // A page or a scroll chunk that opens with the bubble's line: its top
                    // grows as it does under the line before it.
                    let bubbleLine = try #require(lines.firstIndex {
                        let range = CTLineGetStringRange($0)
                        return bubble >= range.location && bubble < range.location + range.length
                    })
                    func firstAscent(from line: Int) -> CGFloat {
                        let opened = CTFramesetterCreateFrame(
                            framesetter, CFRange(location: CTLineGetStringRange(lines[line]).location, length: 0), tall, nil
                        )
                        var origin = CGPoint.zero
                        CTFrameGetLineOrigins(opened, CFRange(location: 0, length: 1), &origin)
                        return 100_000 - origin.y
                    }
                    let openingGrowth = firstAscent(from: bubbleLine) - firstAscent(from: bubbleLine - 1)
                    if abs(openingGrowth - measured.above) > 0.5 {
                        failures.append("""
                            opening a page, \(fontSize)pt × \(lineHeightMultiple), bubble \(bubbleSize): \
                            the line grew \(openingGrowth)pt above, \(measured.above)pt under the line before it
                            """)
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(grown > 0, "no bubble was taller than its line: the test no longer reaches that case")
        #expect(paged > 0, "no page held the bubble's paragraph and the next two: the test no longer checks pages")
    }

    /// Feedback #87 (TestFlight 3.0.0 (140), iOS 27.0.1): the bubble stood about 7pt above
    /// the characters it follows. Centred on the line's typographic box, it stood 3–5pt above
    /// them at 整體大小 ×2 and 1.25pt below them at 20pt × 2.2 on the iOS 27 simulator.
    /// Measured as drawn — the page's text through the line drawer, the bubble at its rect —
    /// paged and in a scroll chunk, across the reader's font sizes, line heights and bubble
    /// sizes, after a 字 and after the 。 and 。” most paragraphs end with: the bubble's ink
    /// against the ink of the 字 on its line.
    @Test("a bubble sits level with its line's characters")
    func bubbleSitsLevelWithItsLine() async throws {
        let settings = GlobalSettings.shared
        let saved = (settings.commentBubbleFollowsSourceSVG, settings.commentBubbleScale)
        defer {
            settings.commentBubbleFollowsSourceSVG = saved.0
            settings.commentBubbleScale = saved.1
        }
        var worst: (setup: String, offset: CGFloat) = ("", 0)
        for (followsSource, scale) in [(true, 1.0), (false, 1.5), (false, 2.0)] {
            settings.commentBubbleFollowsSourceSVG = followsSource
            settings.commentBubbleScale = scale
            for fontSize: CGFloat in [16, 18, 20, 26] {
                for lineHeightMultiple: CGFloat in [1.2, 1.65, 2.2] {
                    for ending in ["", "。", "。”"] {
                        let built = try await build(
                            html: "<p>\(String(repeating: "字", count: 6))\(ending)\(marker)</p>",
                            fontSize: fontSize, lineHeightMultiple: lineHeightMultiple
                        ).attributedString
                        for (mode, offset) in [
                            ("paged", try await pagedBubbleOffset(in: built, fontSize: fontSize)),
                            ("scroll", try scrollBubbleOffset(in: built, fontSize: fontSize)),
                        ] where abs(offset) > abs(worst.offset) {
                            let bubble = followsSource ? "source size" : "×\(scale)"
                            worst = ("\(mode) \(fontSize)pt × \(lineHeightMultiple) after 「\(ending)」, bubble \(bubble)", offset)
                        }
                    }
                }
            }
        }
        print("⟐ bubbleLevel worst: \(worst.setup), \(worst.offset)pt above")
        #expect(abs(worst.offset) <= 1, "\(worst.setup): the bubble's centre stands \(worst.offset)pt above its characters' centre")
    }

    /// How far the review bubble's ink stands above the ink of the characters before it, on a
    /// page laid out and drawn as the reader does.
    private func pagedBubbleOffset(in attributed: NSAttributedString, fontSize: CGFloat) async throws -> CGFloat {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: LayoutShared(attributed).wrappedValue,
            renderSize: page, fontSize: fontSize, contentInsets: insets
        )
        let pageIndex = try #require(layout.inlineAttachments.keys.sorted().first {
            layout.inlineAttachments[$0]?.contains { $0.linkHref?.hasPrefix("ydreview://") == true } == true
        })
        let bubble = try #require(layout.inlineAttachments[pageIndex]?.first { $0.linkHref?.hasPrefix("ydreview://") == true })
        let path = CoreTextPaginator.coreTextContentPathRect(
            renderSize: page, contentInsets: insets, fontSize: fontSize, writingMode: .horizontal
        )
        let artifact = layout.pageArtifacts[pageIndex]
        return try Self.bubbleOffset(bubble, in: page, textFrom: path.minX, em: fontSize) { context in
            CoreTextHorizontalLineDrawer.drawLines(
                of: artifact.frame, contentWidth: path.width, contentMinX: path.minX, contentMinY: path.minY,
                lineOrigins: artifact.lineOrigins, attrStr: attributed,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute, underline: nil, in: context
            )
        }
    }

    /// The same, in a scroll chunk: the frame a chunk lays out, the attachments it extracts.
    private func scrollBubbleOffset(in attributed: NSAttributedString, fontSize: CGFloat) throws -> CGFloat {
        let width = CoreTextPaginator.coreTextContentPathRect(
            renderSize: page, contentInsets: insets, fontSize: fontSize, writingMode: .horizontal
        ).width
        let chunk = CGSize(width: width, height: 1_200)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: chunk), transform: nil), nil
        )
        let bubble = try #require(CoreTextChunkAttachmentExtractor.extract(
            frame: frame, chunkSize: chunk, attributedString: attributed,
            rangeInChapter: CFRange(location: 0, length: attributed.length)
        ).first { $0.linkHref?.hasPrefix("ydreview://") == true })
        return try Self.bubbleOffset(bubble, in: chunk, textFrom: 0, em: fontSize) { context in
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame, contentWidth: width, contentMinX: 0, contentMinY: 0, attrStr: attributed,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute, underline: nil, in: context
            )
        }
    }

    /// The bubble's ink centre against the centre of the ink `drawText` puts on the bubble's
    /// line between `textFrom` and three ems short of the bubble — the 字, clear of a 。 that
    /// sits low and a ” that sits high: positive when the bubble stands higher.
    private static func bubbleOffset(
        _ bubble: CoreTextPaginator.RenderedAttachment,
        in size: CGSize,
        textFrom: CGFloat,
        em: CGFloat,
        drawText: (CGContext) -> Void
    ) throws -> CGFloat {
        let bubbleInk = try #require(inkRows(in: size, columns: bubble.rect.minX..<bubble.rect.maxX) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            bubble.draw(glassCards: .baked)
        }.nearest(to: bubble.rect.midY))
        let textInk = try #require(inkRows(in: size, columns: textFrom..<(bubble.rect.minX - 3 * em), draw: drawText)
            .nearest(to: bubble.rect.midY))
        return textInk.midY - bubbleInk.midY
    }

    /// The lines of the paragraph holding `anchor`, as a frame `width` wide breaks it.
    private func lines(ofParagraphHolding anchor: String, in attributed: NSAttributedString, width: CGFloat) throws -> [NSRange] {
        let text = attributed.string as NSString
        let anchorRange = text.range(of: anchor)
        try #require(anchorRange.location != NSNotFound)
        let paragraph = text.paragraphRange(for: anchorRange)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as! [CTLine]).map {
            let range = CTLineGetStringRange($0)
            return NSRange(location: range.location, length: range.length)
        }.filter { NSIntersectionRange($0, paragraph).length > 0 }
    }

    /// Spacing the drawer adds between neighbouring characters of each line of the paragraph
    /// holding `anchor`, except its last line: how far the drawn ink ends beyond the ink of
    /// the line at its natural width, shared by the gaps between its characters.
    /// `pageEndsBeforeLastLine` lays out a frame that stops where the last line starts, as a
    /// page does when that line opens the next one.
    private func stretchPerGap(
        beforeLastLineOf anchor: String,
        in attributed: NSAttributedString,
        pageEndsBeforeLastLine: Bool = false
    ) throws -> [CGFloat] {
        let width = page.width - insets.left - insets.right
        let text = attributed.string as NSString
        let anchorRange = text.range(of: anchor)
        try #require(anchorRange.location != NSNotFound)
        let paragraph = text.paragraphRange(for: anchorRange)
        let style = try #require(attributed.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)
        try #require(style.alignment == .justified, "the reader's paragraphs are justified")

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        func paragraphLines(of frame: CTFrame) -> [Int] {
            let lines = CTFrameGetLines(frame) as! [CTLine]
            return lines.indices.filter { index in
                let range = CTLineGetStringRange(lines[index])
                return NSIntersectionRange(NSRange(location: range.location, length: range.length), paragraph).length > 0
            }
        }
        var frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        var measured = Array(paragraphLines(of: frame).dropLast())
        if pageEndsBeforeLastLine, let last = paragraphLines(of: frame).last {
            let lastStart = CTLineGetStringRange((CTFrameGetLines(frame) as! [CTLine])[last]).location
            frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: lastStart), path, nil)
            measured = paragraphLines(of: frame)
        }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        return measured.map { index in
            let cfRange = CTLineGetStringRange(lines[index])
            let range = NSRange(location: cfRange.location, length: cfRange.length)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
            let pad: CGFloat = 4
            let strip = CGSize(width: width + 16, height: ascent + descent + 2 * pad)
            let drawn = Self.inkRightEdge(in: strip) { context in
                CoreTextHorizontalLineDrawer.drawLines(
                    of: frame, contentWidth: width, contentMinX: 0,
                    contentMinY: -(origins[index].y - descent - pad), attrStr: attributed,
                    hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                    lineIndices: IndexSet(integer: index), underline: nil, in: context
                )
            }
            let natural = Self.inkRightEdge(in: strip) { context in
                context.textPosition = CGPoint(x: max(0, origins[index].x), y: descent + pad)
                CTLineDraw(CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range)), context)
            }
            var characters = 0
            text.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { character, _, _, _ in
                if let character, !character.allSatisfy(\.isWhitespace) { characters += 1 }
            }
            guard let drawn, let natural, characters > 1 else { return 0 }
            return max(0, drawn - natural) / CGFloat(characters - 1)
        }
    }

    /// The rows `draw` inks between `columns` — UIKit coordinates, a quarter point apart —
    /// grouped into the vertical extents they form.
    private static func inkRows(
        in size: CGSize,
        columns: Range<CGFloat>,
        draw: (CGContext) -> Void
    ) -> [InkExtent] {
        let scale: CGFloat = 4
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var extents: [InkExtent] = []
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            draw(context)
            let bytes = raw.bindMemory(to: UInt8.self)
            let xs = max(0, Int(columns.lowerBound * scale))..<min(width, Int(columns.upperBound * scale))
            var start: Int?
            for row in 0...height {
                let inked = row < height && xs.contains { bytes[(row * width + $0) * 4 + 3] > 40 }
                if inked, start == nil { start = row }
                if !inked, let first = start {
                    extents.append(InkExtent(minY: CGFloat(first) / scale, maxY: CGFloat(row) / scale))
                    start = nil
                }
            }
        }
        return extents
    }

    struct InkExtent {
        let minY: CGFloat
        let maxY: CGFloat
        var midY: CGFloat { (minY + maxY) / 2 }
    }

    private static func inkRightEdge(in size: CGSize, draw: (CGContext) -> Void) -> CGFloat? {
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var edge: CGFloat?
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.textMatrix = .identity
            UIGraphicsPushContext(context)
            draw(context)
            UIGraphicsPopContext()
            let bytes = raw.bindMemory(to: UInt8.self)
            for x in stride(from: width - 1, through: 0, by: -1) {
                if (0..<height).contains(where: { bytes[($0 * width + x) * 4 + 3] > 40 }) {
                    edge = CGFloat(x + 1)
                    return
                }
            }
        }
        return edge
    }

    private func build(
        html: String,
        fontSize: CGFloat = 20,
        lineHeightMultiple: CGFloat = 1.6
    ) async throws -> AttributedChapterBuildResult {
        // The page, as the reader passes its viewport: the builder takes the insets off itself.
        let builder = OnlineProviderAttributedStringBuilder(
            provider: SingleChapterProvider(html: html),
            renderSize: page
        )
        return try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, lineSpacing: 0, paragraphSpacing: 10,
                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
    }

    private func layout(html: String) async throws -> CoreTextPaginator.ChapterLayout {
        let built = try await build(html: html)
        return await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: LayoutShared(built.attributedString).wrappedValue,
            renderSize: page,
            fontSize: 20,
            contentInsets: insets
        )
    }
}

private extension Array where Element == CommentBubbleLineEndTests.InkExtent {
    /// The extent whose centre lies closest to `y`.
    func nearest(to y: CGFloat) -> Element? {
        self.min { abs($0.midY - y) < abs($1.midY - y) }
    }
}

private final class SingleChapterProvider: BookContentProvider {
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
