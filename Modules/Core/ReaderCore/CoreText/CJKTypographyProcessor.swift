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
/// ## Preserves UTF-16 length
/// Smart punctuation replaces ASCII quotes with BMP curly quotes one-for-one, and spacing only modifies `.kern`.
/// UTF-16 offsets used by reading progress therefore remain stable.
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

    /// Applies smart punctuation normalization + CJK punctuation compression.
    static func apply(to attrStr: NSAttributedString) -> NSAttributedString {
        let smart = applySmartPunctuation(to: attrStr)
        guard smart.length > 1 else { return smart }

        let mutable = NSMutableAttributedString(attributedString: smart)
        let string = smart.string

        // Use Unicode scalar view to correctly handle multi-code-unit characters
        let scalars = Array(string.unicodeScalars)
        // Pre-build scalar → UTF-16 offset mapping
        let utf16Offsets = buildUTF16OffsetMap(for: string)

        guard scalars.count == utf16Offsets.count else { return smart }

        for i in 0 ..< scalars.count - 1 {
            let curr = scalars[i]
            let next = scalars[i + 1]
            let utf16Idx = utf16Offsets[i]

            let currIsClosing = closingMarks.contains(curr)
            let currIsOpening = openingMarks.contains(curr)
            let nextIsClosing = closingMarks.contains(next)
            let nextIsOpening = openingMarks.contains(next)

            // Get the current character's font size to calculate em units
            let fontSize = fontSizeAt(utf16Idx, in: smart)
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

            // NOTE: No automatic CJK↔Latin/number spacing ("pangu" spacing) is inserted.
            // The source text controls spacing; injecting 1/8em between Han and digits/letters
            // produced unwanted gaps (e.g. "2017 年 3 月第 1 版") that don't exist in the source.
        }

        return mutable
    }

    // MARK: - Smart Punctuation

    /// Converts ASCII straight quotes to Unicode curly quotes.
    /// " -> “ / ” (U+201C / U+201D)
    /// ' -> ‘ / ’ (U+2018 / U+2019) with apostrophe detection for English contractions and possessives.
    static func normalizeEnglishPunctuation(_ text: String) -> String {
        var result = ""
        var isOpeningDouble = true
        var isOpeningSingle = true
        let chars = Array(text)

        for i in chars.indices {
            let ch = chars[i]
            if ch == "\"" {
                let isOpening = openingQuoteDecision(at: i, in: chars) ?? isOpeningDouble
                result.append(isOpening ? "\u{201C}" : "\u{201D}")
                isOpeningDouble = !isOpening
            } else if ch == "'" {
                if isEnglishApostrophe(at: i, in: chars, isInsideSingleQuote: !isOpeningSingle) {
                    result.append("\u{2019}")
                } else {
                    let isOpening = openingQuoteDecision(at: i, in: chars) ?? isOpeningSingle
                    result.append(isOpening ? "\u{2018}" : "\u{2019}")
                    isOpeningSingle = !isOpening
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func openingQuoteDecision(at index: Array<Character>.Index, in chars: [Character]) -> Bool? {
        let previous = index > chars.startIndex ? chars[chars.index(before: index)] : nil
        let nextIndex = chars.index(after: index)
        let next = nextIndex < chars.endIndex ? chars[nextIndex] : nil

        if let next, next.isWhitespace {
            return false
        }
        if next == nil {
            return false
        }
        if previous == nil || previous?.isWhitespace == true {
            return true
        }
        if let previous, isOpeningQuoteBoundary(previous) {
            return true
        }
        if let previous, let next, isQuoteLeadInBoundary(previous), !isClosingQuoteBoundary(next) {
            return true
        }
        if let previous, isClosingQuoteBoundary(previous) {
            return false
        }
        if let next, isClosingQuoteBoundary(next) {
            return false
        }
        return nil
    }

    private static func isEnglishApostrophe(
        at index: Array<Character>.Index,
        in chars: [Character],
        isInsideSingleQuote: Bool
    ) -> Bool {
        let previous = index > chars.startIndex ? chars[chars.index(before: index)] : nil
        let nextIndex = chars.index(after: index)
        let next = nextIndex < chars.endIndex ? chars[nextIndex] : nil

        if isASCIIAlphaNumeric(previous), isASCIIAlphaNumeric(next) {
            return true
        }

        if isInsideSingleQuote {
            return false
        }

        return isASCIIAlphaNumeric(previous) && (next == nil || isApostropheTrailingBoundary(next))
    }

    private static func isASCIIAlphaNumeric(_ character: Character?) -> Bool {
        guard let character,
              let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x0030...0x0039, 0x0041...0x005A, 0x0061...0x007A:
            return true
        default:
            return false
        }
    }

    private static func isQuoteLeadInBoundary(_ character: Character) -> Bool {
        switch character {
        case ",", ":", ";", "，", "：", "；":
            return true
        default:
            return false
        }
    }

    private static func isOpeningQuoteBoundary(_ character: Character) -> Bool {
        switch character {
        case "(", "[", "{", "<", "「", "『", "（", "【", "《", "〈", "\u{2014}", "\u{2013}":
            return true
        default:
            return false
        }
    }

    private static func isClosingQuoteBoundary(_ character: Character) -> Bool {
        if character.isWhitespace {
            return true
        }
        switch character {
        case ".", ",", "!", "?", ":", ";", ")", "]", "}", ">", "。", "，", "！", "？", "：", "；",
             "）", "】", "》", "〉":
            return true
        default:
            return false
        }
    }

    private static func isApostropheTrailingBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        if character.isWhitespace {
            return true
        }
        return isClosingQuoteBoundary(character)
    }

    /// Applies smart punctuation to an NSAttributedString in-place.
    /// All replacements are 1 UTF-16 code unit → 1 UTF-16 code unit (all BMP),
    /// so attribute ranges are preserved without adjustment.
    private static func applySmartPunctuation(to attrStr: NSAttributedString) -> NSAttributedString {
        let original = attrStr.string
        let normalized = normalizeEnglishPunctuation(original)
        guard normalized != original || containsSmartQuote(original) else { return attrStr }

        let result = NSMutableAttributedString(string: normalized)
        attrStr.enumerateAttributes(
            in: NSRange(location: 0, length: attrStr.length),
            options: []
        ) { attrs, range, _ in
            result.setAttributes(attrs, range: range)
        }
        applyLatinQuoteFont(in: result)
        return result
    }

    private static func containsSmartQuote(_ text: String) -> Bool {
        text.unicodeScalars.contains { isSmartQuoteScalar($0) }
    }

    private static func applyLatinQuoteFont(in result: NSMutableAttributedString) {
        let scalars = Array(result.string.unicodeScalars)
        let utf16Offsets = buildUTF16OffsetMap(for: result.string)
        guard scalars.count == utf16Offsets.count else { return }

        for (scalar, utf16Offset) in zip(scalars, utf16Offsets) {
            guard isSmartQuoteScalar(scalar) else { continue }

            let currentFont = result.attribute(.font, at: utf16Offset, effectiveRange: nil) as? UIFont
            let size = currentFont?.pointSize ?? 17
            guard let quoteFont = latinQuoteFont(matching: currentFont, size: size) else { continue }

            result.addAttribute(.font, value: quoteFont, range: NSRange(location: utf16Offset, length: scalar.utf16.count))
        }
    }

    private static func isSmartQuoteScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2018, 0x2019, 0x201C, 0x201D:
            return true
        default:
            return false
        }
    }

    private static func latinQuoteFont(matching font: UIFont?, size: CGFloat) -> UIFont? {
        let base = UIFont(name: "Georgia", size: size)
        guard let base else { return nil }
        guard let font else { return base }

        var traits: UIFontDescriptor.SymbolicTraits = []
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
            traits.insert(.traitBold)
        }
        if font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            traits.insert(.traitItalic)
        }
        guard !traits.isEmpty else { return base }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
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
