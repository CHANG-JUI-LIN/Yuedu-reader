import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Regex highlight engine")
struct RegexHighlightEngineTests {
    @Test("overlaps accumulate and later rules replace the same property")
    func cascade() throws {
        let first = RegexHighlightRule.fixture(
            id: "first",
            pattern: "abc",
            textColor: 0xFF0000,
            underline: true,
            shadows: [.fixture(x: 1)]
        )
        let second = RegexHighlightRule.fixture(
            id: "second",
            pattern: "bc",
            textColor: 0x0000FF,
            strikethrough: true,
            shadows: [.fixture(x: 2)]
        )

        let result = try RegexHighlightEngine.evaluate(
            text: "abc",
            rules: [first, second],
            appearance: .light
        )

        #expect(result.segments.map(\.range) == [
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 2),
        ])
        #expect(result.segments[0].style.text.colorHex == 0xFF0000)
        #expect(result.segments[1].style.text.colorHex == 0x0000FF)
        #expect(result.segments[1].style.text.underline == true)
        #expect(result.segments[1].style.text.strikethrough == true)
        #expect(result.segments[1].style.decoration.shadows.map(\.x) == [1, 2])
        #expect(result.segments[1].contributingRuleIDs == ["first", "second"])
    }

    @Test("emoji ranges remain valid UTF16 ranges")
    func utf16Ranges() throws {
        let result = try RegexHighlightEngine.evaluate(
            text: "a😀b",
            rules: [.fixture(pattern: "😀")],
            appearance: .light
        )

        #expect(result.segments.map(\.range) == [NSRange(location: 1, length: 2)])
    }

    @Test("does not cross paragraph executes each paragraph independently")
    func paragraphBoundary() throws {
        let rule = RegexHighlightRule.fixture(
            pattern: "start[\\s\\S]*end",
            options: [.doesNotCrossParagraph]
        )

        let result = try RegexHighlightEngine.evaluate(
            text: "start\nend",
            rules: [rule],
            appearance: .light
        )

        #expect(result.segments.isEmpty)
    }

    @Test("paragraph-local ranges map back to the chapter UTF16 coordinates")
    func paragraphRangeMapping() throws {
        let result = try RegexHighlightEngine.evaluate(
            text: "first\na😀b\nlast",
            rules: [.fixture(pattern: "😀", options: [.doesNotCrossParagraph])],
            appearance: .light
        )

        #expect(result.segments.map(\.range) == [NSRange(location: 7, length: 2)])
    }

    @Test("overlong patterns and excessive matches report deterministic diagnostics")
    func limits() throws {
        #expect(throws: RegexHighlightError.patternTooLong(ruleID: "long", maximum: 2_048)) {
            try RegexHighlightEngine.compile(
                .fixture(id: "long", pattern: String(repeating: "x", count: 2_049))
            )
        }

        let result = try RegexHighlightEngine.evaluate(
            text: String(repeating: "x", count: 10_001),
            rules: [.fixture(id: "many", pattern: "x")],
            appearance: .light
        )

        #expect(result.segments.isEmpty)
        #expect(result.diagnostics == [
            .matchLimitExceeded(ruleID: "many", maximum: 10_000),
        ])
    }

    @Test("compiled expressions are reused until pattern or options change")
    func compiledExpressionCache() throws {
        let rule = RegexHighlightRule.fixture(id: "cache", pattern: "abc")
        let first = try RegexHighlightEngine.compile(rule)
        let second = try RegexHighlightEngine.compile(rule)
        #expect(first === second)

        var changed = rule
        changed.options.insert(.caseInsensitive)
        let third = try RegexHighlightEngine.compile(changed)
        #expect(first !== third)
    }

    @Test("refresh restores publisher attributes before applying the next rules")
    func publisherAttributesAreReversible() throws {
        let originalColor = UIColor.systemGreen
        let originalFont = UIFont.italicSystemFont(ofSize: 19)
        let attr = NSMutableAttributedString(
            string: "abc outside",
            attributes: [
                .foregroundColor: originalColor,
                .font: originalFont,
            ]
        )
        let first = RegexHighlightRule.fixture(
            id: "first",
            pattern: "abc",
            textColor: 0xFF0000,
            fontSize: 31,
            underline: true
        )
        let firstConfiguration = RegexHighlightConfiguration(
            isEnabled: true,
            rules: [],
            customRules: [first]
        )

        _ = try RegexHighlightEngine.apply(
            configuration: firstConfiguration,
            appearance: .light,
            to: attr
        )
        #expect((attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.rgbHex == 0xFF0000)
        #expect((attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == 31)
        #expect(attr.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attr.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == originalColor)

        _ = try RegexHighlightEngine.apply(
            configuration: .disabled,
            appearance: .dark,
            to: attr
        )
        #expect(attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == originalColor)
        #expect(attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == originalFont)
        #expect(attr.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect(attr.attribute(RegexHighlightEngine.originalAttributesKey, at: 0, effectiveRange: nil) == nil)
    }

    @Test("decoration attributes carry the asset revision and clear on refresh")
    func decorationLifecycle() throws {
        let rule = RegexHighlightRule.fixture(
            pattern: "abc",
            backgroundColor: 0x112233
        )
        let attr = NSMutableAttributedString(string: "abc")
        let configuration = RegexHighlightConfiguration(
            isEnabled: true,
            rules: [],
            customRules: [rule]
        )

        _ = try RegexHighlightEngine.apply(
            configuration: configuration,
            appearance: .light,
            assetRevision: 42,
            to: attr
        )
        let decoration = attr.attribute(
            RegexHighlightEngine.decorationAttributeKey,
            at: 0,
            effectiveRange: nil
        ) as? RegexHighlightDecoration
        #expect(decoration?.style.backgroundColorHex == 0x112233)
        #expect(decoration?.assetRevision == 42)

        _ = try RegexHighlightEngine.apply(
            configuration: .disabled,
            appearance: .light,
            to: attr
        )
        #expect(attr.attribute(RegexHighlightEngine.decorationAttributeKey, at: 0, effectiveRange: nil) == nil)
    }
}

@Suite("Dialogue highlighter")
struct DialogueHighlighterTests {
    private let tint = UIColor.systemBlue

    /// Foreground color at a UTF-16 index, or nil if none is set there.
    private func color(_ attr: NSAttributedString, at index: Int) -> UIColor? {
        attr.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
    }

    private func highlighted(_ string: String) -> NSMutableAttributedString {
        let attr = NSMutableAttributedString(string: string)
        DialogueHighlighter.apply(textColor: tint, boxColor: nil, to: attr)
        return attr
    }

    @Test("tints corner-bracket dialogue including the brackets, leaves narration alone")
    func tintsCornerBracketDialogue() {
        let text = "他說「你好」然後離開"
        let ns = text as NSString
        let attr = highlighted(text)

        let open = ns.range(of: "「").location
        let close = ns.range(of: "」").location
        // Brackets and the enclosed characters are tinted…
        for i in open...close {
            #expect(color(attr, at: i) == tint)
        }
        // …but the narration on either side is not.
        #expect(color(attr, at: 0) == nil)
        #expect(color(attr, at: close + 1) == nil)
    }

    @Test("tints full-width curly double quotes")
    func tintsCurlyQuotes() {
        let text = "\u{201C}早安\u{201D}"  // “早安”
        let attr = highlighted(text)
        #expect(color(attr, at: 0) == tint)                 // “
        #expect(color(attr, at: attr.length - 1) == tint)   // ”
    }

    @Test("a paragraph break stops an unclosed quote from bleeding onward")
    func resetsAtParagraphBreak() {
        let text = "「未閉合\n下一段"
        let ns = text as NSString
        let attr = highlighted(text)

        let newline = ns.range(of: "\n").location
        // The unclosed span is tinted up to (not including) the newline.
        #expect(color(attr, at: 0) == tint)
        #expect(color(attr, at: newline - 1) == tint)
        // The following paragraph is untouched.
        #expect(color(attr, at: newline + 1) == nil)
    }

    @Test("leaves quote-free text untinted")
    func leavesPlainTextAlone() {
        let attr = highlighted("沒有任何對話的敘述文字")
        for i in 0..<attr.length {
            #expect(color(attr, at: i) == nil)
        }
    }
}

private extension RegexHighlightRule {
    static func fixture(
        id: String = "fixture",
        pattern: String,
        options: RegexHighlightOptions = [],
        textColor: UInt32? = nil,
        fontSize: Double? = nil,
        underline: Bool? = nil,
        strikethrough: Bool? = nil,
        backgroundColor: UInt32? = nil,
        shadows: [ReaderStyleShadow] = []
    ) -> RegexHighlightRule {
        let style = ReaderStyleRuleStyle(
            text: ReaderStyleTextStyle(
                colorHex: textColor,
                fontSize: fontSize,
                underline: underline,
                strikethrough: strikethrough
            ),
            decoration: ReaderStyleDecorationStyle(
                backgroundColorHex: backgroundColor,
                shadows: shadows
            )
        )
        return RegexHighlightRule(
            id: id,
            name: id,
            pattern: pattern,
            isEnabled: true,
            isBuiltIn: false,
            options: options,
            lightStyle: style,
            darkStyle: style
        )
    }
}

private extension ReaderStyleShadow {
    static func fixture(x: Double) -> ReaderStyleShadow {
        ReaderStyleShadow(colorHex: 0, radius: 1, x: x, y: 0)
    }
}
