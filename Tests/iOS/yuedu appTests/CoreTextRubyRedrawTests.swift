@testable import yuedu_app
import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit

/// A paged layout's frames are drawn more than once on the main thread: a bars refresh, a
/// theme change, rotation, `display` before the prerendered bitmap lands, and the curl back
/// page (`renderSnapshot`) all draw the page's artifact frame again. Every draw must put
/// every glyph where the first one did.
///
/// Core Text breaks that for one combination: a horizontal `CTLine` that carries a
/// `CTRubyAnnotation` and an underline anywhere on the same line. The first `CTLineDraw`
/// centres the annotation over its base; every later one draws it shifted right by the base
/// run's x position in the line (measured: +18pt for a base at 18pt, +36pt at 36pt). The
/// state sits in the line's runs, so a `CTLineCreateJustifiedLine` copy inherits it; a line
/// built afresh from the attributed string does not. Justified paragraphs were never
/// affected because the horizontal drawer rebuilds each of their lines from the substring
/// on every draw; centred, left- and right-aligned lines went straight to `CTLineDraw`.
@Suite("CoreText ruby redraw", .serialized)
@MainActor
struct CoreTextRubyRedrawTests {
    private nonisolated static let renderSize = CGSize(width: 360, height: 640)

    enum Alignment: String, CaseIterable, Sendable {
        case natural, center, right, justified

        var textAlignment: NSTextAlignment {
            switch self {
            case .natural: return .natural
            case .center: return .center
            case .right: return .right
            case .justified: return .justified
            }
        }
    }

    @Test(
        "a horizontal ruby page draws the same pixels every time",
        arguments: Alignment.allCases, [false, true]
    )
    func horizontalRubyPageRedrawsIdentically(alignment: Alignment, underline: Bool) async throws {
        let layout = await Self.paginate(
            Self.chapterText(alignment: alignment, underline: underline),
            writingMode: .horizontal
        )
        #expect(!layout.pageRanges.isEmpty)
        for page in layout.pageRanges.indices {
            let first = Self.render(layout, page: page)
            let second = Self.render(layout, page: page)
            let third = Self.render(layout, page: page)
            #expect(first == second, "page \(page): second draw differs from the first")
            #expect(second == third, "page \(page): third draw differs from the second")
        }
    }

    @Test("a mixed-script ruby chapter draws the same pixels every time")
    func stressRubyChapterRedrawsIdentically() async throws {
        let layout = await Self.paginate(Self.stressChapterText(), writingMode: .horizontal)
        #expect(layout.pageRanges.count > 1)
        for page in layout.pageRanges.indices {
            let first = Self.render(layout, page: page)
            let second = Self.render(layout, page: page)
            #expect(first == second, "page \(page): second draw differs from the first")
        }
    }

    /// The drawer draws a ruby line it did not justify from a line rebuilt from the line's
    /// substring. That line must draw exactly what Core Text's own first draw of the frame
    /// line does — indent, kern, bold, underline, emoji, Hangul and Arabic fallback included.
    @Test(
        "a ruby line rebuilt from its substring draws the frame line's first-draw pixels",
        arguments: [Alignment.natural, .center, .right]
    )
    func rebuiltRubyLineMatchesFrameLineFirstDraw(alignment: Alignment) async throws {
        let text = alignment == .natural
            ? Self.stressChapterText()
            : Self.chapterText(alignment: alignment, underline: true)
        let layout = await Self.paginate(text, writingMode: .horizontal)
        var compared = 0
        for artifact in layout.pageArtifacts {
            for line in CTFrameGetLines(artifact.frame) as! [CTLine] {
                let range = CTLineGetStringRange(line)
                let nsRange = NSRange(location: range.location, length: range.length)
                var hasRuby = false
                text.enumerateAttribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, in: nsRange) { value, _, _ in
                    if value != nil { hasRuby = true }
                }
                guard hasRuby else { continue }
                let frameLine = Self.draw(line)
                let rebuilt = Self.draw(CTLineCreateWithAttributedString(text.attributedSubstring(from: nsRange)))
                #expect(frameLine == rebuilt, "line at \(range.location) draws differently once rebuilt")
                compared += 1
            }
        }
        #expect(compared > 0)
    }

    @Test("a vertical ruby page draws the same pixels every time")
    func verticalRubyPageRedrawsIdentically() async throws {
        let layout = await Self.paginate(
            Self.chapterText(alignment: .natural, underline: true),
            writingMode: .verticalRTL
        )
        for page in layout.pageRanges.indices {
            let first = Self.render(layout, page: page)
            let second = Self.render(layout, page: page)
            #expect(first == second, "page \(page): second draw differs from the first")
        }
    }

    // MARK: - Helpers

    private static func paginate(
        _ text: NSAttributedString,
        writingMode: ReaderWritingMode
    ) async -> CoreTextPaginator.ChapterLayout {
        // A new paginator per call, so the layout's frames have never been drawn.
        await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: text,
            renderSize: renderSize,
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20),
            writingMode: writingMode
        )
    }

    /// The main thread's page-to-bitmap path, drawing the layout's own frame.
    private static func render(_ layout: CoreTextPaginator.ChapterLayout, page: Int) -> Data {
        let image = CoreTextPageEngine.renderImage(
            layout: layout, pageIndex: page, size: renderSize,
            bgColor: UIColor.white.cgColor, bars: nil, frameSource: .layoutArtifact
        )
        return image.cgImage!.dataProvider!.data! as Data
    }

    /// One line, drawn once, in a bitmap tall enough for the annotation above it.
    private static func draw(_ line: CTLine) -> Data {
        let size = CGSize(width: 400, height: 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: 20, y: 24)
            CTLineDraw(line, ctx)
        }
        return image.cgImage!.dataProvider!.data! as Data
    }

    /// Mixed-script chapter text in the shape `HTMLAttributedStringBuilder` produces, the
    /// text the defect was first seen in (`CoreTextSharedLayoutConcurrencyTests`): first-line
    /// indents, kerning, bold, underlined paragraphs, font fallback (emoji, Hangul, Arabic).
    private static func stressChapterText() -> NSAttributedString {
        let paragraph = """
        第3章　山雨欲來風滿樓。他說：「這是 CoreText 的測試，English words mixed in, 123,456.78!」\
        一段很長的中文段落，包含標點符號、引號『』與破折號——還有省略號……以及 emoji 😀👍🏽 和日文かなカナ。\
        한국어 문장도 있습니다. Ligatures: office final waffle. Arabic: مرحبا بالعالم.\n
        """
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 36
        style.lineSpacing = 6
        let text = NSMutableAttributedString()
        for index in 0..<14 {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: index % 5 == 3 ? UIFont.boldSystemFont(ofSize: 18) : UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1 + CGFloat(index % 3) * 0.2, alpha: 1),
                .backgroundColor: UIColor.white,
                .paragraphStyle: style,
                .kern: index % 4 == 0 ? 0.6 : 0,
            ]
            if index % 6 == 2 {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let piece = NSMutableAttributedString(string: paragraph, attributes: attributes)
            piece.addAttribute(
                HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                value: HTMLAttributedStringBuilder.makeRubyAnnotation(text: "ルビ"),
                range: NSRange(location: 1, length: 2)
            )
            text.append(piece)
        }
        return text
    }

    /// Paragraphs of mixed CJK and Latin with `<ruby>` over the chapter number, as
    /// `HTMLAttributedStringBuilder` emits it. Each paragraph wraps, so a justified chapter
    /// has stretched lines as well as natural-width last lines.
    private static func chapterText(alignment: Alignment, underline: Bool) -> NSAttributedString {
        let paragraph = """
        第3章　山雨欲來風滿樓。他說：「這是 CoreText 的測試，English words mixed in。」\
        一段很長的中文段落，包含標點符號、引號『』與破折號——還有省略號……以及日文かなカナ。\n
        """
        let style = NSMutableParagraphStyle()
        style.alignment = alignment.textAlignment
        style.lineSpacing = 6
        let text = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18),
            .foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1),
            .paragraphStyle: style,
        ]
        for _ in 0..<6 {
            let piece = NSMutableAttributedString(string: paragraph, attributes: attributes)
            // Over "3章", after "第": the shift equals the base's x position in the line,
            // so a base at x = 0 would hide it.
            piece.addAttribute(
                HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                value: HTMLAttributedStringBuilder.makeRubyAnnotation(text: "ルビ"),
                range: NSRange(location: 1, length: 2)
            )
            if underline {
                // Away from the ruby on the same first line: an underline anywhere on the
                // ruby's line is enough.
                piece.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 8, length: 6)
                )
            }
            text.append(piece)
        }
        return text
    }
}
