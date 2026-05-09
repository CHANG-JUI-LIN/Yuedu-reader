import UIKit

/// CJK typography post-processor.
/// Called after HTMLAttributedStringBuilder.build() produces the NSAttributedString,
/// applies negative kern between adjacent full-width punctuation marks for Punctuation Compression.
///
/// ## W3C JLREQ compression rules
/// - Closing mark (」。， etc.) followed by another closing mark: compress the trailing space of the closing mark (-0.5em kern)
/// - Closing mark followed by opening mark (「（ etc.): compress both trailing space of closing and leading space of opening (-1.0em kern)
/// - Opening mark followed by opening mark: compress the leading space of the following opening mark (-0.5em kern on preceding opening mark)
///
/// ## Does not modify string length
/// Only modifies `.kern` attributes without inserting characters, so charOffset progress tracking is unaffected.
enum CJKTypographyProcessor {

    // MARK: - Punctuation Classification

    /// Closing marks / sentence-ending punctuation: glyph on left, right half is empty space
    public static let closingMarks: Set<Unicode.Scalar> = [
        "」", "』", "）", "】", "〕", "｝", "〉", "》",
        "。", "．", "，", "、", "；", "：", "！", "？",
        "\u{2026}", // …
    ]

    /// Opening marks: glyph on right, left half is empty space
    public static let openingMarks: Set<Unicode.Scalar> = [
        "「", "『", "（", "【", "〔", "｛", "〈", "《",
    ]

    /// Line-start prohibition: punctuation that should not appear at the beginning of a line (typically closing marks)
    public static let lineStartForbidden: Set<Unicode.Scalar> = closingMarks

    /// Line-end prohibition: punctuation that should not appear at the end of a line (typically opening marks)
    public static let lineEndForbidden: Set<Unicode.Scalar> = openingMarks

    // MARK: - Public API

    /// Checks whether the first character is an opening mark, used for line-start compression
    static func isOpening(_ char: Character) -> Bool {
        guard let first = char.unicodeScalars.first else { return false }
        return openingMarks.contains(first)
    }

    /// Checks whether the last character is a closing mark, used for line-end compression
    static func isClosing(_ char: Character) -> Bool {
        guard let first = char.unicodeScalars.first else { return false }
        return closingMarks.contains(first)
    }

    static func protectedLineBreakOffset(
        _ proposedOffset: Int,
        in string: String,
        lowerBound: Int
    ) -> Int {
        let nsString = string as NSString
        let length = nsString.length
        guard length > 0 else { return proposedOffset }

        var adjusted = min(max(proposedOffset, lowerBound), length)
        adjusted = avoidSurrogateSplit(at: adjusted, in: nsString, lowerBound: lowerBound)

        if adjusted < length,
           let next = unicodeScalar(atUTF16Offset: adjusted, in: string),
           lineStartForbidden.contains(next),
           adjusted > lowerBound {
            adjusted = avoidSurrogateSplit(at: adjusted - 1, in: nsString, lowerBound: lowerBound)
        }

        if adjusted > lowerBound,
           let previous = unicodeScalar(beforeUTF16Offset: adjusted, in: string),
           lineEndForbidden.contains(previous) {
            adjusted = avoidSurrogateSplit(at: adjusted - previous.utf16.count, in: nsString, lowerBound: lowerBound)
        }

        return max(lowerBound, adjusted)
    }

    /// Applies CJK punctuation compression and CJK-Latin spacing to `attrStr`, returning a modified copy.
    static func apply(to attrStr: NSAttributedString) -> NSAttributedString {
        guard attrStr.length > 1 else { return attrStr }

        let mutable = NSMutableAttributedString(attributedString: attrStr)
        let string = attrStr.string

        // Use Unicode scalar view to correctly handle multi-code-unit characters
        let scalars = Array(string.unicodeScalars)
        // Pre-build scalar → UTF-16 offset mapping
        let utf16Offsets = buildUTF16OffsetMap(for: string)

        guard scalars.count == utf16Offsets.count else { return attrStr }

        for i in 0 ..< scalars.count - 1 {
            let curr = scalars[i]
            let next = scalars[i + 1]
            let utf16Idx = utf16Offsets[i]

            let currIsClosing = closingMarks.contains(curr)
            let currIsOpening = openingMarks.contains(curr)
            let nextIsClosing = closingMarks.contains(next)
            let nextIsOpening = openingMarks.contains(next)

            // Get the current character's font size to calculate em units
            let fontSize = fontSizeAt(utf16Idx, in: attrStr)
            let halfEm = fontSize * 0.5

            if currIsClosing && nextIsOpening {
                // Closing + Opening: compress two half-width spaces (1em total)
                addKern(-halfEm * 2, at: utf16Idx, in: mutable)
            } else if currIsClosing && nextIsClosing {
                // Closing + Closing: compress the trailing space of the first closing mark (0.5em)
                addKern(-halfEm, at: utf16Idx, in: mutable)
            } else if currIsOpening && nextIsOpening {
                // Opening + Opening: push the following opening mark left by compressing its leading space (0.5em)
                addKern(-halfEm, at: utf16Idx, in: mutable)
            }

            if shouldApplyCJKLatinSpacing(between: curr, and: next) {
                let spacing = fontSize * 0.125
                addKern(spacing, at: utf16Idx, in: mutable)
            }
        }

        return mutable
    }

    // MARK: - Private helpers

    private static func fontSizeAt(_ utf16Offset: Int, in attrStr: NSAttributedString) -> CGFloat {
        guard attrStr.length > 0, utf16Offset < attrStr.length else { return 17 }
        let font = attrStr.attribute(.font, at: utf16Offset, effectiveRange: nil) as? UIFont
        return font?.pointSize ?? 17
    }

    /// Accumulates kern at utf16Offset (adds to existing kern to avoid overwriting existing typography)
    private static func addKern(_ delta: CGFloat, at utf16Offset: Int, in mutable: NSMutableAttributedString) {
        let range = NSRange(location: utf16Offset, length: 1)
        let existing = mutable.attribute(.kern, at: utf16Offset, effectiveRange: nil) as? CGFloat ?? 0
        mutable.addAttribute(.kern, value: existing + delta, range: range)
    }

    private static func avoidSurrogateSplit(
        at offset: Int,
        in nsString: NSString,
        lowerBound: Int
    ) -> Int {
        guard offset > lowerBound, offset < nsString.length else { return offset }
        let previous = nsString.character(at: offset - 1)
        let current = nsString.character(at: offset)
        if CFStringIsSurrogateHighCharacter(previous) && CFStringIsSurrogateLowCharacter(current) {
            return offset - 1
        }
        return offset
    }

    private static func unicodeScalar(atUTF16Offset offset: Int, in string: String) -> Unicode.Scalar? {
        let index = String.Index(utf16Offset: offset, in: string)
        guard index < string.endIndex else { return nil }
        return string[index].unicodeScalars.first
    }

    private static func unicodeScalar(beforeUTF16Offset offset: Int, in string: String) -> Unicode.Scalar? {
        guard offset > 0 else { return nil }
        let index = String.Index(utf16Offset: offset, in: string)
        guard index > string.startIndex else { return nil }
        return string[string.index(before: index)].unicodeScalars.first
    }

    private static func shouldApplyCJKLatinSpacing(
        between lhs: Unicode.Scalar,
        and rhs: Unicode.Scalar
    ) -> Bool {
        (isCJKTextScalar(lhs) && isLatinOrNumberScalar(rhs))
            || (isLatinOrNumberScalar(lhs) && isCJKTextScalar(rhs))
    }

    private static func isLatinOrNumberScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0030...0x0039, 0x0041...0x005A, 0x0061...0x007A:
            return true
        default:
            return false
        }
    }

    private static func isCJKTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    /// Builds a mapping array from Unicode scalar index → UTF-16 code unit offset
    private static func buildUTF16OffsetMap(for string: String) -> [Int] {
        var map: [Int] = []
        map.reserveCapacity(string.unicodeScalars.count)
        var utf16Offset = 0
        for scalar in string.unicodeScalars {
            map.append(utf16Offset)
            utf16Offset += scalar.utf16.count
        }
        return map
    }
}
