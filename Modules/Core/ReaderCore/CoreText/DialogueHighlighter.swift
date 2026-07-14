import Foundation
import UIKit

/// Decorates quoted dialogue in a chapter's attributed string — the "對話文字高亮"
/// (text tint) and "對話底色框" (background box) reading decorations.
///
/// Runs as the final step of `NodeAttributedStringRenderer.render`, after all
/// typography processing, so ranges are stable against the string it marks.
/// The text tint (`.foregroundColor`) is painted natively by CoreText — justified
/// glyphs and both writing modes for free. The box marker (`boxColorAttribute`) is
/// custom-drawn behind the glyphs by `CoreTextHorizontalLineDrawer` (horizontal
/// modes). Copy/selection are unaffected — neither attribute carries text content.
enum DialogueHighlighter {

    /// Opening → closing quote characters treated as dialogue delimiters. Only
    /// directional CJK / full-width curly quotes; straight `"`/`'` are excluded
    /// because they double as inch marks and apostrophes.
    private static let openers: Set<unichar> = [
        0x300C, // 「  corner bracket
        0x300E, // 『  white corner bracket
        0x201C, // "  left double quotation mark
        0x2018, // '  left single quotation mark
    ]
    private static let closers: Set<unichar> = [
        0x300D, // 」
        0x300F, // 』
        0x201D, // "
        0x2019, // '
    ]

    /// Attribute marking dialogue spans that get a background box (the "對話底色框").
    /// A dedicated key — NOT `.backgroundColor`, which `CTLineDraw` does not paint in this
    /// CoreText pipeline (inline backgrounds here are all custom-drawn). Consumed by
    /// `CoreTextHorizontalLineDrawer`, which fills a rounded rect behind the dialogue glyphs.
    /// Value is a `UIColor`.
    static let boxColorAttribute = NSAttributedString.Key("YDDialogueBoxColor")

    /// Applies the dialogue decoration across every quoted span:
    /// - `textColor` → `.foregroundColor` (the "對話文字高亮" tint), painted natively by CoreText.
    /// - `boxColor` → `boxColorAttribute` (the "對話底色框"), custom-drawn behind the glyphs.
    /// Either color may be nil to skip that layer.
    static func apply(textColor: UIColor?, boxColor: UIColor?, to attr: NSMutableAttributedString) {
        guard textColor != nil || boxColor != nil else { return }
        for range in dialogueRanges(in: attr.string as NSString) {
            if let textColor {
                attr.addAttribute(.foregroundColor, value: textColor, range: range)
            }
            if let boxColor {
                attr.addAttribute(boxColorAttribute, value: boxColor, range: range)
            }
        }
    }

    /// Scans for quoted dialogue spans: opener → matching closer, with nesting.
    /// Paragraph breaks close any open span and reset nesting, so a stray unclosed
    /// quote never bleeds across the rest of the chapter. An opener with no closer
    /// before the end still spans to the tail.
    static func dialogueRanges(in ns: NSString) -> [NSRange] {
        let length = ns.length
        guard length > 0 else { return [] }

        var ranges: [NSRange] = []
        var depth = 0
        var spanStart = 0

        for i in 0..<length {
            let c = ns.character(at: i)

            if c == 0x000A || c == 0x2028 || c == 0x2029 {
                if depth > 0 {
                    ranges.append(NSRange(location: spanStart, length: i - spanStart))
                    depth = 0
                }
                continue
            }

            if openers.contains(c) {
                if depth == 0 { spanStart = i }
                depth += 1
            } else if closers.contains(c), depth > 0 {
                depth -= 1
                if depth == 0 {
                    ranges.append(NSRange(location: spanStart, length: i - spanStart + 1))
                }
            }
        }

        if depth > 0, spanStart < length {
            ranges.append(NSRange(location: spanStart, length: length - spanStart))
        }
        return ranges
    }
}
