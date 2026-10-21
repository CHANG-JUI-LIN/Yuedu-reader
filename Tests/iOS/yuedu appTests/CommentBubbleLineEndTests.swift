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

    private func build(html: String) async throws -> AttributedChapterBuildResult {
        let builder = OnlineProviderAttributedStringBuilder(
            provider: SingleChapterProvider(html: html),
            renderSize: CGSize(
                width: page.width - insets.left - insets.right,
                height: page.height - insets.top - insets.bottom
            )
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
