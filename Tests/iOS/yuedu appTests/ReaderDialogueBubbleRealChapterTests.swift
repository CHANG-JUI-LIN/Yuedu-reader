import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Runs the bubble pass over a real chapter of a real book. Synthetic
/// paragraphs never carry the shapes that actually break it — unbalanced
/// quotes, nested quotes inside speech, ideographic indents, blank lines.
@Suite("Dialogue bubbles over a real chapter", .serialized)
struct ReaderDialogueBubbleRealChapterTests {
    private static var chapter: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/txt-chapter-sample.txt"),
            encoding: .utf8
        )) ?? ""
    }

    private func attributed() -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 32
        paragraph.paragraphSpacing = 8
        return NSMutableAttributedString(
            string: Self.chapter,
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
        )
    }

    @Test("marks a whole chapter without going out of bounds")
    func survivesRealChapter() throws {
        #expect(!Self.chapter.isEmpty)
        let attr = attributed()
        let original = attr.string

        var style = ReaderDialogueBubbleStyle(isEnabled: true)
        style.showsSpeakerName = true
        style.sidesFollowSpeaker = true
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: 392,
            bodyFontSize: 18,
            to: attr
        )

        // Splitting only ever inserts line breaks; no character may be lost.
        #expect(
            attr.string.replacingOccurrences(of: "\n", with: "")
                == original.replacingOccurrences(of: "\n", with: "")
        )

        var bubbles = 0
        attr.enumerateAttribute(
            ReaderDialogueBubbleMarker.attributeKey,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, range, _ in
            guard value is ReaderDialogueBubbleMark else { return }
            bubbles += 1
            #expect(NSMaxRange(range) <= attr.length)
        }
        #expect(bubbles > 0)
    }

    @Test("paints the chapter without a bad range or a broken frame")
    func paintsRealChapter() throws {
        let attr = attributed()
        ReaderDialogueBubbleMarker.apply(
            style: ReaderDialogueBubbleStyle(isEnabled: true),
            columnWidth: 392,
            bodyFontSize: 18,
            to: attr
        )

        let width: CGFloat = 392
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let range = CFRange(location: 0, length: attr.length)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            range,
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        let height = max(1, ceil(size.height))
        let frame = CTFramesetterCreateFrame(
            framesetter,
            range,
            CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil),
            nil
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        _ = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            let ctx = context.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame,
                contentWidth: width,
                contentMinX: 0,
                contentMinY: 0,
                isLastPage: true,
                attrStr: attr,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                in: ctx
            )
            ctx.restoreGState()
        }
    }

    /// The pass has to be safe to run twice: an appearance change re-renders the
    /// same string, and a second round of insertions would corrupt it.
    @Test("stays stable when applied twice")
    func isIdempotentEnough() {
        let attr = attributed()
        let style = ReaderDialogueBubbleStyle(isEnabled: true)
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: 392,
            bodyFontSize: 18,
            to: attr
        )
        let once = attr.string
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: 392,
            bodyFontSize: 18,
            to: attr
        )

        #expect(attr.string == once)
    }
}
