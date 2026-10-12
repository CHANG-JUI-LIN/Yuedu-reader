import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@Suite
@MainActor
struct NineSliceGuideEditorTests {
    /// A line stops before it would cross its partner, so the middle always has width.
    @Test func linesNeverCrossTheirPartner() {
        let slices = ReaderStyleImageSlices(top: 0.4, right: 0.3, bottom: 0.5, left: 0.2)
        #expect(NineSliceGuide.top.clamped(0.9, partner: slices.bottom) == 1 - 0.5 - NineSliceGuide.minimumCenter)
        #expect(NineSliceGuide.left.clamped(-0.3, partner: slices.right) == 0)
        #expect(NineSliceGuide.right.clamped(.nan, partner: slices.left) == 0)
        // A partner that already fills the image leaves nothing, not a negative inset.
        #expect(NineSliceGuide.bottom.clamped(0.2, partner: 1) == 0)
    }

    /// Dragging maps the finger back to the fraction it shows, on a letterboxed image.
    @Test func positionsRoundTripThroughTheFittedImage() {
        let frame = NineSliceGuideEditor.fittedRect(for: CGSize(width: 200, height: 50), in: CGSize(width: 300, height: 200))
        #expect(frame == CGRect(x: 0, y: 62.5, width: 300, height: 75))
        let slices = ReaderStyleImageSlices(top: 0.2, right: 0.15, bottom: 0.35, left: 0.1)
        for guide in NineSliceGuide.allCases {
            let position = guide.position(slices, in: frame)
            #expect(abs(guide.value(at: position, in: frame) - slices[keyPath: guide.keyPath]) < 1e-9)
        }
        #expect(abs(NineSliceGuide.top.position(slices, in: frame) - 77.5) < 1e-9)
        #expect(abs(NineSliceGuide.right.position(slices, in: frame) - 255) < 1e-9)
    }

    /// 九宮格's sample text has a short quote and a long one in every language, and the
    /// preview's pattern finds both.
    @Test func framePreviewPatternFindsBothQuotes() throws {
        let expression = try NSRegularExpression(pattern: RegexHighlightRuleEditorModel.framePreviewPattern)
        for sample in [
            "他說：「好。」\n她回答：「我知道你一定會回來，所以一直在這裡等著，從天亮等到天黑。」",
            "他说：“好。”\n她回答：“我知道你一定会回来，所以一直在这里等着，从天亮等到天黑。”",
            "He said, “Fine.”\nShe answered, “I knew you would come back, so I waited here all day, from dawn until dark.”",
        ] {
            let range = NSRange(location: 0, length: (sample as NSString).length)
            #expect(expression.numberOfMatches(in: sample, range: range) == 2, "\(sample)")
        }
    }
}
