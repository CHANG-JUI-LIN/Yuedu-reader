import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("CoreText writing mode")
struct CoreTextWritingModeTests {

    @Test("vertical RTL pagination stores writing mode and vertical glyph attribute")
    func verticalPaginationStoresWritingModeAndVerticalGlyphAttribute() async {
        let font = UIFont.systemFont(ofSize: 18)
        let attr = NSAttributedString(string: "第一章\n這是一段直排測試文字。", attributes: [.font: font])
        let paginator = CoreTextPaginator()

        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attr,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        #expect(layout.writingMode == .verticalRTL)
        let verticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: 0,
            effectiveRange: nil
        ) as? Bool
        #expect(verticalForm == true)
    }

    @Test("vertical Latin ranges remove vertical forms and use ideographic centered baseline")
    func verticalLatinRangesUseIdeographicCenteredBaseline() async throws {
        let font = UIFont.systemFont(ofSize: 18)
        let text = "版DNA-BN N00004905校"
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let paginator = CoreTextPaginator()

        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attr,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )

        let latinLocation = try location(of: "DNA-BN", in: text)
        let hyphenLocation = try location(of: "-", in: text)
        let numericLocation = try location(of: "00004905", in: text)
        let cjkVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: 0,
            effectiveRange: nil
        ) as? Bool
        let latinVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: latinLocation,
            effectiveRange: nil
        ) as? Bool
        let hyphenVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: hyphenLocation,
            effectiveRange: nil
        ) as? Bool
        let numericVerticalForm = layout.attributedString.attribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            at: numericLocation,
            effectiveRange: nil
        ) as? Bool
        let latinBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: latinLocation,
            effectiveRange: nil
        ) as? String
        let hyphenBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: hyphenLocation,
            effectiveRange: nil
        ) as? String
        let numericBaselineClass = layout.attributedString.attribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            at: numericLocation,
            effectiveRange: nil
        ) as? String
        let latinBaselineOffset = layout.attributedString.attribute(
            .baselineOffset,
            at: latinLocation,
            effectiveRange: nil
        )

        #expect(cjkVerticalForm == true)
        #expect(latinVerticalForm != true)
        #expect(hyphenVerticalForm != true)
        #expect(numericVerticalForm != true)
        #expect(latinBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(hyphenBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(numericBaselineClass == (kCTBaselineClassIdeographicCentered as String))
        #expect(latinBaselineOffset == nil)
    }

    @Test("vertical image placeholders use vertical run delegate metrics")
    func verticalImagePlaceholdersUseVerticalRunDelegateMetrics() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )

        let result = await builder.build(
            html: "<html><body><p><img src='patch.png'/></p></body></html>",
            config: config
        )
        let info = try #require(firstImageRunInfo(in: result.attributedString))

        #expect(info.drawWidth == 20)
        #expect(info.drawHeight == 40)
        #expect(info.width == 40)
        #expect(info.ascent == 10)
        #expect(info.descent == 10)
    }

    @Test("vertical inline image padding-left does not shift column center")
    func verticalInlineImagePaddingLeftDoesNotShiftColumnCenter() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 14)).image { _ in }
        }

        let unpaddedMidX = try await verticalInlineAttachmentMidX(image: image, paddingLeft: 0)
        let paddedMidX = try await verticalInlineAttachmentMidX(image: image, paddingLeft: 8)

        #expect(abs(unpaddedMidX - paddedMidX) < 0.5)
    }

    @Test("vertical inline image centers on typographic center")
    func verticalInlineImageCentersOnTypographicCenter() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 14)).image { _ in }
        }

        let alignment = try await verticalInlineAttachmentAlignment(
            image: image,
            imageAscent: 18,
            imageDescent: 2
        )

        #expect(abs(alignment.typographicCenterX - alignment.baselineX) > 2)
        #expect(abs(alignment.midX - alignment.typographicCenterX) < 0.5)
    }

    @Test("horizontal image placeholders keep horizontal run delegate metrics")
    func horizontalImagePlaceholdersKeepHorizontalRunDelegateMetrics() async throws {
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240
        )

        let result = await builder.build(
            html: "<html><body><p><img src='patch.png'/></p></body></html>",
            config: config
        )
        let info = try #require(firstImageRunInfo(in: result.attributedString))

        #expect(info.drawWidth == 20)
        #expect(info.drawHeight == 40)
        #expect(info.width == 20)
        #expect(info.ascent == 40)
        #expect(info.descent == 0)
    }

    @Test("vertical RTL frame attributes request right-to-left frame progression")
    func verticalFrameAttributesRequestRightToLeftProgression() {
        let attrs = CoreTextPaginator.frameAttributes(for: .verticalRTL)
        let progression = attrs[kCTFrameProgressionAttributeName as String] as? Int ?? -1
        #expect(progression == CTFrameProgression.rightToLeft.rawValue)
    }

    private func firstImageRunInfo(in attributedString: NSAttributedString) -> ImageRunInfo? {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var result: ImageRunInfo?
        attributedString.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(delegate)
            result = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            stop.pointee = true
        }
        return result
    }

    private func location(of substring: String, in text: String) throws -> Int {
        let range = (text as NSString).range(of: substring)
        try #require(range.location != NSNotFound)
        return range.location
    }

    private func verticalInlineAttachmentMidX(image: UIImage, paddingLeft: Int) async throws -> CGFloat {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 240,
            writingMode: .verticalRTL
        )
        let result = await builder.build(
            html: "<html><body><p>甲<img style='width:20px;height:14px;padding-left:\(paddingLeft)px' src='patch.png'/>乙</p></body></html>",
            config: config
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let attachment = try #require(layout.inlineAttachments.values.flatMap { $0 }.first)
        return attachment.rect.midX
    }

    private func verticalInlineAttachmentAlignment(
        image: UIImage,
        imageAscent: CGFloat,
        imageDescent: CGFloat
    ) async throws -> (midX: CGFloat, typographicCenterX: CGFloat, baselineX: CGFloat) {
        let font = UIFont.systemFont(ofSize: 18)
        let attributedString = NSMutableAttributedString(
            string: "甲",
            attributes: [.font: font, .foregroundColor: UIColor.black]
        )
        attributedString.append(RunDelegateProvider.makeImagePlaceholder(
            image: image,
            font: font,
            textColor: .black,
            totalWidth: 14,
            drawWidth: 20,
            drawHeight: 14,
            ascent: imageAscent,
            descent: imageDescent,
            paddingLeft: 0,
            paddingRight: 0,
            imageSource: "patch.png",
            displayMode: .inline,
            opacity: 1
        ))
        attributedString.append(NSAttributedString(
            string: "乙",
            attributes: [.font: font, .foregroundColor: UIColor.black]
        ))

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 240, height: 320),
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
            writingMode: .verticalRTL
        )
        let attachment = try #require(layout.inlineAttachments.values.flatMap { $0 }.first)

        let imageRangeLocation = 1
        let contentPathRect = CGRect(
            x: layout.contentInsets.left,
            y: layout.contentInsets.bottom,
            width: max(1, layout.renderSize.width - layout.contentInsets.left - layout.contentInsets.right),
            height: max(1, layout.renderSize.height - layout.contentInsets.top - layout.contentInsets.bottom)
        )
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter,
            range: layout.pageRanges[0],
            path: CGPath(rect: contentPathRect, transform: nil),
            writingMode: layout.writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            guard imageRangeLocation >= lineRange.location,
                  imageRangeLocation < lineRange.location + lineRange.length
            else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineX = contentPathRect.minX + origins[index].x
            return (
                midX: attachment.rect.midX,
                typographicCenterX: baselineX + (ascent - descent) / 2,
                baselineX: baselineX
            )
        }

        Issue.record("Unable to find line containing inline image placeholder")
        return (attachment.rect.midX, attachment.rect.midX, attachment.rect.midX)
    }
}

@Suite("CJK line break policy")
struct CJKLineBreakPolicyTests {

    @Test("line break backs up before line-start forbidden punctuation")
    func lineBreakBacksUpBeforeLineStartForbiddenPunctuation() {
        let text = "天地。玄黃"
        let proposed = (text as NSString).range(of: "。").location

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposed,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == proposed - 1)
    }

    @Test("line break backs up when opening punctuation would end a line")
    func lineBreakBacksUpWhenOpeningPunctuationWouldEndLine() {
        let text = "天地「玄黃"
        let proposed = (text as NSString).range(of: "「").location + 1

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposed,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == proposed - 1)
    }

    @Test("line break does not split surrogate pairs")
    func lineBreakDoesNotSplitSurrogatePairs() {
        let text = "天地😀玄黃"
        let emojiLocation = (text as NSString).range(of: "😀").location
        let proposedInsideEmoji = emojiLocation + 1

        let adjusted = CJKTypographyProcessor.protectedLineBreakOffset(
            proposedInsideEmoji,
            in: text,
            lowerBound: 0
        )

        #expect(adjusted == emojiLocation)
    }
}
