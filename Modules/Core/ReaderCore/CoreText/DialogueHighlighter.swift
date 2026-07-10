import Foundation
import UIKit

/// Recolors quoted dialogue in a chapter's attributed string — the "對話文字高亮"
/// reading decoration.
///
/// Runs as the final step of `NodeAttributedStringRenderer.render`, after all
/// typography processing, so ranges are stable against the string it colors.
/// Because it sets `.foregroundColor` on the built string (rather than drawing at
/// line time), CoreText colors justified glyphs natively and the tint applies in
/// both horizontal and vertical writing modes. Copy/selection are unaffected —
/// foreground color carries no text content.
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

    /// Overrides `.foregroundColor` with `color` across every dialogue span.
    static func apply(color: UIColor, to attr: NSMutableAttributedString) {
        let ns = attr.string as NSString
        let length = ns.length
        guard length > 0 else { return }

        var depth = 0
        var spanStart = 0

        for i in 0..<length {
            let c = ns.character(at: i)

            // Paragraph breaks close any open span and reset nesting, so a stray
            // unclosed quote never bleeds tint across the rest of the chapter.
            if c == 0x000A || c == 0x2028 || c == 0x2029 {
                if depth > 0 {
                    attr.addAttribute(.foregroundColor, value: color,
                                      range: NSRange(location: spanStart, length: i - spanStart))
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
                    attr.addAttribute(.foregroundColor, value: color,
                                      range: NSRange(location: spanStart, length: i - spanStart + 1))
                }
            }
        }

        // An opener with no closer before the end still gets tinted to the tail.
        if depth > 0, spanStart < length {
            attr.addAttribute(.foregroundColor, value: color,
                              range: NSRange(location: spanStart, length: length - spanStart))
        }
    }
}
