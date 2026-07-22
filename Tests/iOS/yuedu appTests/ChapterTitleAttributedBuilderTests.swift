import Testing
import UIKit
@testable import yuedu_app

@Suite("Chapter title attributed builder", .serialized)
struct ChapterTitleAttributedBuilderTests {

    @Test("advanced CSS bottom spacing is attached to the last visible title paragraph")
    func advancedCSSBottomSpacingUsesLastVisibleParagraph() throws {
        let firstStyle = NSMutableParagraphStyle()
        firstStyle.paragraphSpacing = 3
        let lastStyle = NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = 5
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: "第1章\n",
            attributes: [.paragraphStyle: firstStyle]
        ))
        title.append(NSAttributedString(
            string: "擇徒\n",
            attributes: [.paragraphStyle: lastStyle]
        ))

        ChapterTitleAttributedBuilder.applyBottomSpacing(42, to: title)

        let firstResult = try #require(
            title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let lastResult = try #require(
            title.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(firstResult.paragraphSpacing == 3)
        #expect(lastResult.paragraphSpacing == 47)
        #expect(title.string == "第1章\n擇徒\n")
    }
}
