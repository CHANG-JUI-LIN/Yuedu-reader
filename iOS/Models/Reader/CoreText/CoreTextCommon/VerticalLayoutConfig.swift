import CoreText
import Foundation

// MARK: - CTFont Vertical Alternate Detection

extension CTFont {

    /// Checks whether CoreText, with `kCTVerticalFormsAttributeName = true`,
    /// resolves a different glyph for `character` — meaning the font has a
    /// vertical alternate.  Returns false if the glyph is unchanged (upright
    /// fallback) or the font lacks the character entirely.
    func hasVerticalAlternate(for character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }

        let str = String(character)
        let attr = NSMutableAttributedString(string: str)
        attr.addAttribute(
            kCTFontAttributeName as NSAttributedString.Key,
            value: self,
            range: NSRange(location: 0, length: 1)
        )
        attr.addAttribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            value: true,
            range: NSRange(location: 0, length: 1)
        )

        let line = CTLineCreateWithAttributedString(attr)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return false }

        // Glyph index from the vertical-forms run
        var vertGlyphs = [CGGlyph](repeating: 0, count: 1)
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &vertGlyphs)
        guard vertGlyphs[0] != 0 else { return false }

        // Baseline glyph index (no vertical forms)
        var utf16 = UInt16(scalar.value)
        var normalGlyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(self, &utf16, &normalGlyph, 1), normalGlyph != 0 else {
            return false
        }

        return vertGlyphs[0] != normalGlyph
    }
}

// MARK: - Vertical Layout Configuration

/// Builds and caches a per-font substitution map for vertical CJK punctuation.
///
/// Instead of hardcoding every full-width → vertical-presentation-form mapping,
/// we ask CoreText at runtime whether the current font actually provides a
/// vertical alternate glyph.  Characters that DO have a vert alternate are
/// left alone; only missing ones get a presentation-form fallback.  This
/// preserves searchability and copy-paste for characters the font handles
/// natively.
final class VerticalLayoutConfig {

    /// Horizontal → vertical presentation form.  Applied only when the font
    /// is confirmed to lack a vertical alternate for the horizontal codepoint.
    let substitutionMap: [String: String]

    init(font: CTFont) {
        substitutionMap = Self.buildMap(for: font)
    }

    // MARK: - Candidates

    /// Pairs of (horizontal, vertical-presentation-form).
    /// Phase 2 of normalization consults this list per font.
    private static let candidates: [(String, String)] = [
        ("〔", "︹"), ("〕", "︺"),
        ("（", "︵"), ("）", "︶"),
        ("【", "︻"), ("】", "︼"),
        ("《", "︽"), ("》", "︾"),
        ("〈", "︿"), ("〉", "﹀"),
        ("「", "﹁"), ("」", "﹂"),
        ("『", "﹃"), ("』", "﹄"),
        ("｛", "︷"), ("｝", "︸"),
        ("、", "︑"), ("。", "︒"),
        ("，", "︐"), ("：", "︓"), ("；", "︔"),
        ("？", "︖"), ("！", "︕"),
    ]

    // MARK: - Cache

    private static var cache: [FontKey: [String: String]] = [:]

    private struct FontKey: Hashable {
        let name: String
        let size: CGFloat
    }

    private static func buildMap(for font: CTFont) -> [String: String] {
        let key = FontKey(
            name: CTFontCopyFullName(font) as String,
            size: CTFontGetSize(font)
        )
        if let cached = cache[key] { return cached }

        var map: [String: String] = [:]
        for (horizontal, vertical) in candidates {
            guard let char = horizontal.first else { continue }
            if !font.hasVerticalAlternate(for: char) {
                map[horizontal] = vertical
            }
        }
        cache[key] = map
        return map
    }
}
