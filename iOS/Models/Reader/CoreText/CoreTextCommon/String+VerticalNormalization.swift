import Foundation

extension String {
    /// Normalizes punctuation for vertical-right-to-left CoreText layout.
    ///
    /// Phase 1: half-width ASCII brackets → full-width CJK equivalents.
    ///   These replacements are 1:1 at the UTF-16 level so attribute ranges are preserved
    ///   when applied to an NSMutableAttributedString.
    ///
    /// Phase 2: full-width horizontal punctuation → vertical presentation forms.
    ///   These codepoints (U+FE10–U+FE1F block and neighbors) are dedicated vertical
    ///   glyphs that render correctly even in fonts without OpenType vertical alternates.
    ///
    /// Phase 2 note: CoreText with kCTVerticalFormsAttributeName already handles many
    ///   CJK punctuation marks via internal glyph substitution. This mapping covers
    ///   the remaining cases where fonts lack vertical form tables.
    func normalizedForVerticalLayout() -> String {
        var processed = self

        // ── Phase 1: half-width → full-width brackets ──
        let halfToFullMap: [String: String] = [
            "(": "（", ")": "）",
            "[": "〔", "]": "〕",
            "{": "｛", "}": "｝",
            "<": "〈", ">": "〉",
        ]
        for (half, full) in halfToFullMap {
            processed = processed.replacingOccurrences(of: half, with: full)
        }

        // ── Phase 2: full-width → vertical presentation forms ──
        let verticalPunctuationMap: [String: String] = [
            "《": "︽", "》": "︾",
            "〈": "︿", "〉": "﹀",
            "「": "﹁", "」": "﹂",
            "『": "﹃", "』": "﹄",
            "（": "︵", "）": "︶",
            "〔": "︹", "〕": "︺",
            "【": "︻", "】": "︼",
            "｛": "︷", "｝": "︸",
            "、": "︑", "。": "︒",
            "，": "︐", "：": "︓", "；": "︔",
            "？": "︖", "！": "︕",
            "——": "︱︱", "……": "︙︙",
        ]
        for (horizontal, vertical) in verticalPunctuationMap {
            processed = processed.replacingOccurrences(of: horizontal, with: vertical)
        }

        return processed
    }
}
