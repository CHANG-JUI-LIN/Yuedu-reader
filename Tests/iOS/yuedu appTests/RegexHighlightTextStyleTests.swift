import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Font resolution for regex-highlight rules, exercised through the public `apply` entry.
///
/// The cases here are all CJK: a Chinese family ships no italic face at all, and CoreText answers
/// an unsatisfiable italic request by silently returning the upright font instead of failing — so
/// a Latin-only test would pass while the reader showed nothing.
@Suite("Regex highlight text style")
struct RegexHighlightTextStyleTests {
    @Test("italic slants a CJK run that has no italic face")
    func italicOnCJKFont() throws {
        let font = try resolvedFont(italic: true, fontWeight: nil)

        #expect(isSlanted(font))
    }

    @Test("italic does not swallow the requested weight")
    func weightSurvivesItalic() throws {
        let bold = try resolvedFont(italic: nil, fontWeight: 700)
        let boldItalic = try resolvedFont(italic: true, fontWeight: 700)

        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(boldItalic.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(isSlanted(boldItalic))
    }

    @Test("turning italic off clears a synthesized slant")
    func italicOffRemovesSyntheticSlant() throws {
        let base = try #require(UIFont(name: "PingFangSC-Regular", size: 16))
        let oblique = HTMLAttributedStringBuilder.synthesizedObliqueFont(from: base)
        #expect(isSlanted(oblique))

        let font = try resolvedFont(italic: false, fontWeight: nil, base: oblique)

        #expect(!isSlanted(font))
    }

    @Test("a Latin family still resolves to its real italic face")
    func latinKeepsRealItalicFace() throws {
        let base = try #require(UIFont(name: "Helvetica", size: 16))
        let font = try resolvedFont(italic: true, fontWeight: nil, base: base)

        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    // MARK: - Helpers

    /// True for a real italic face as well as a synthesized one (the shear rides in the font
    /// matrix, where no symbolic trait is set).
    private func isSlanted(_ font: UIFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
            || abs(font.fontDescriptor.matrix.c) > 0.05
    }

    private func resolvedFont(
        italic: Bool?,
        fontWeight: Int?,
        base: UIFont? = nil
    ) throws -> UIFont {
        let baseFont: UIFont
        if let base {
            baseFont = base
        } else {
            baseFont = try #require(UIFont(name: "PingFangSC-Regular", size: 16))
        }
        let style = ReaderStyleRuleStyle(
            text: ReaderStyleTextStyle(fontWeight: fontWeight, italic: italic)
        )
        let rule = RegexHighlightRule(
            id: UUID().uuidString,
            name: "test",
            pattern: "測試",
            isEnabled: true,
            isBuiltIn: false,
            options: [],
            lightStyle: style,
            darkStyle: style
        )
        let attributed = NSMutableAttributedString(
            string: "前置測試後綴",
            attributes: [.font: baseFont]
        )

        _ = try RegexHighlightEngine.apply(
            configuration: RegexHighlightConfiguration(
                isEnabled: true,
                rules: [],
                customRules: [rule]
            ),
            appearance: .light,
            to: attributed
        )

        let matched = (attributed.string as NSString).range(of: "測試")
        return try #require(
            attributed.attribute(.font, at: matched.location, effectiveRange: nil) as? UIFont
        )
    }
}
