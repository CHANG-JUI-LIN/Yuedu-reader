import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Horizontal placement of an inline image attachment that flows with text on a
/// non-left-aligned line — in production, the 章名段评 bubble that sits beside the
/// chapter title once the reader's title alignment is 置中 or 靠右.
///
/// `CTFrameGetLineOrigins` already reports line origins with the paragraph's flush
/// applied (that is why `CTFrameDraw` renders centred text correctly). Adding
/// `CTLineGetPenOffsetForFlush` on top of that origin double-counted the alignment:
/// a centred title's bubble was pinned to the right margin, and a right-aligned
/// title's bubble was pushed past the content box entirely and vanished.
@Suite("Inline attachment alignment")
struct InlineAttachmentAlignmentTests {

    private let renderSize = CGSize(width: 390, height: 844)
    private let insets = UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)
    private let bubbleSide: CGFloat = 22

    private var contentLeft: CGFloat { insets.left }
    private var contentWidth: CGFloat { renderSize.width - insets.left - insets.right }
    private var contentRight: CGFloat { contentLeft + contentWidth }

    @Test("a centred title keeps its bubble beside the text, not at the margin")
    func centeredTitleBubbleStaysBesideTheTitle() async throws {
        let left = try #require(await bubbleRect(alignment: .left))
        let center = try #require(await bubbleRect(alignment: .center))

        // The left-aligned line starts at the content edge, so its bubble's right
        // edge measures the whole line's width.
        let lineWidth = left.maxX - contentLeft
        let expectedCenterMaxX = contentLeft + (contentWidth + lineWidth) / 2

        #expect(abs(center.maxX - expectedCenterMaxX) <= 1)
        // Symmetry: the gap left of the title equals the gap right of the bubble.
        #expect(abs((contentRight - center.maxX) - (center.minX - left.minX)) <= 1)
        #expect(center.maxX < contentRight - 1)
    }

    @Test("a right-aligned title lands its bubble on the content edge, not off-page")
    func rightAlignedTitleBubbleStaysOnPage() async throws {
        let right = try #require(await bubbleRect(alignment: .right))

        #expect(abs(right.maxX - contentRight) <= 1)
        #expect(right.minX >= contentLeft)
    }

    @Test("left alignment is unchanged")
    func leftAlignedTitleBubbleFollowsTheText() async throws {
        let left = try #require(await bubbleRect(alignment: .left))

        #expect(left.minX > contentLeft)
        #expect(left.maxX < contentRight)
    }

    // MARK: - Helpers

    private func bubbleRect(alignment: NSTextAlignment) async -> CGRect? {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: titleWithBubble(alignment: alignment),
            renderSize: renderSize,
            fontSize: 17,
            contentInsets: insets
        )
        return (layout.inlineAttachments[0] ?? []).first?.rect
    }

    /// One chapter-title line: title text, a thin space, and a text-sized review
    /// bubble — the shape `OnlineProviderAttributedStringBuilder.mergeTitleAccessories`
    /// produces.
    private func titleWithBubble(alignment: NSTextAlignment) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: 28, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph,
        ]

        let result = NSMutableAttributedString(string: "第一章 初入江湖\u{2009}", attributes: attributes)

        let bubble = NSMutableAttributedString(
            attributedString: RunDelegateProvider.makeImagePlaceholder(
                image: solidImage(side: bubbleSide),
                font: font,
                textColor: .black,
                totalWidth: bubbleSide,
                drawWidth: bubbleSide,
                drawHeight: bubbleSide,
                ascent: bubbleSide,
                descent: 0,
                paddingLeft: 0,
                paddingRight: 0,
                imageSource: "ydreview-bubble",
                displayMode: .inline,
                opacity: 1,
                isTextSized: true
            )
        )
        bubble.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: bubble.length)
        )
        result.append(bubble)
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        result.append(NSAttributedString(string: "正文第一段。\n", attributes: [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.black,
        ]))
        return result
    }

    private func solidImage(side: CGFloat) -> UIImage {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
