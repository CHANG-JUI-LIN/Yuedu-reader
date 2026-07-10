import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Dialogue highlighter")
struct DialogueHighlighterTests {
    private let tint = UIColor.systemBlue

    /// Foreground color at a UTF-16 index, or nil if none is set there.
    private func color(_ attr: NSAttributedString, at index: Int) -> UIColor? {
        attr.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
    }

    private func highlighted(_ string: String) -> NSMutableAttributedString {
        let attr = NSMutableAttributedString(string: string)
        DialogueHighlighter.apply(color: tint, to: attr)
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
