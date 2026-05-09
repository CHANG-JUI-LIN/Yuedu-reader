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

    @Test("vertical RTL frame attributes request right-to-left frame progression")
    func verticalFrameAttributesRequestRightToLeftProgression() {
        let attrs = CoreTextPaginator.frameAttributes(for: .verticalRTL)
        let progression = attrs[kCTFrameProgressionAttributeName as String] as? Int ?? -1
        #expect(progression == CTFrameProgression.rightToLeft.rawValue)
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
