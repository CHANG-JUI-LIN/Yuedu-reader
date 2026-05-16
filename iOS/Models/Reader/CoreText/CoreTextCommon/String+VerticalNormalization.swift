import Foundation

extension String {

    /// Normalizes punctuation for vertical-right-to-left CoreText layout.
    ///
    /// Phase 1: half-width ASCII brackets → full-width CJK equivalents (always).
    ///   These have no vertical alternates in any CJK font, so unconditional
    ///   1:1 UTF-16 replacement is safe and preserves attribute ranges.
    ///
    /// Phase 2: full-width → vertical presentation forms, using a per-font
    ///   substitution map built by `VerticalLayoutConfig`.  Characters the
    ///   font already handles via `kCTVerticalFormsAttributeName` are skipped;
    ///   only truly missing ones get a presentation-form fallback.  This keeps
    ///   searchability and copy-paste working for natively-supported punctuation.
    func normalizedForVerticalLayout(using verticalMap: [String: String]? = nil) -> String {
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

        // ── Phase 2: full-width → vertical presentation forms (per-font) ──
        let map = verticalMap ?? Self.staticVerticalMap
        for (horizontal, vertical) in map {
            processed = processed.replacingOccurrences(of: horizontal, with: vertical)
        }

        // Dashes and ellipsis are multi-char and font-agnostic.
        processed = processed.replacingOccurrences(of: "——", with: "︱︱")
        processed = processed.replacingOccurrences(of: "……", with: "︙︙")

        return processed
    }

    /// Fallback used when no per-font map is available.
    private static let staticVerticalMap: [String: String] = [
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
    ]
}
