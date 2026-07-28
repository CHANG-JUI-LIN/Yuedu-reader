import CoreText
import Foundation
import Testing
import UIKit
@testable import YueduCoreTextTypography

@Suite("Yuedu CoreText typography public API")
struct TypographyPublicAPITests {
    @Test("Vertical normalization preserves UTF-16 length while converting brackets")
    func verticalNormalization() {
        let source = "(中文)"
        let normalized = source.normalizedForVerticalLayout(using: [:])

        #expect(normalized == "（中文）")
        #expect((normalized as NSString).length == (source as NSString).length)
    }

    @Test("Vertical glyph classification distinguishes CJK and Latin orientation")
    func verticalGlyphClassification() {
        guard case .rotatedLatin("A") = VerticalGlyphClassifier.classify("A") else {
            Issue.record("Expected ASCII letters to rotate in vertical layout")
            return
        }
        guard case .cjk("中") = VerticalGlyphClassifier.classify("中") else {
            Issue.record("Expected Han characters to remain upright")
            return
        }
    }

    @Test("Hyphenation tags Latin but never mixed CJK text")
    func hyphenationLanguage() {
        #expect(ReaderHyphenation.language(for: "reader typography") == "en")
        #expect(ReaderHyphenation.language(for: "reader 閱讀") == nil)
    }

    @Test("Framesetter factory produces a visible CoreText frame")
    func framesetterFactory() {
        let text = NSAttributedString(
            string: "CoreText package",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let framesetter = CoreTextFramesetterFactory.make(for: text)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRangeMake(0, 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: 240, height: 120), transform: nil),
            nil
        )

        #expect(CTFrameGetVisibleStringRange(frame).length == text.length)
    }

    @Test("CJK smart punctuation remains length stable")
    func cjkSmartPunctuation() {
        let input = NSAttributedString(
            string: "\"你好。\"",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let output = CJKTypographyProcessor.apply(to: input)

        #expect(output.string == "“你好。”")
        #expect(output.length == input.length)
    }

    @Test("Vertical layout config exposes a deterministic substitution map")
    func verticalLayoutConfig() {
        let font = CTFontCreateWithName("PingFangTC-Regular" as CFString, 17, nil)
        let first = VerticalLayoutConfig(font: font).substitutionMap
        let second = VerticalLayoutConfig(font: font).substitutionMap

        #expect(first == second)
    }
}
