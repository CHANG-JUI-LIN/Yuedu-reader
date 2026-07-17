import Foundation
import CoreText

/// Hyphenation support for justified text.
///
/// Justified Latin text goes gappy when long words cannot break: the residual width has nowhere to
/// go but the word spaces, so a line holding few words sprays them apart. Hyphenation lets CoreText
/// split a word at a syllable and add a trailing hyphen — exactly how browsers (and therefore
/// Readest / Apple Books, which render EPUB in a web view) keep justified English tight.
///
/// CJK needs none of this: it wraps per character, so every line already fills the column.
enum ReaderHyphenation {

    /// Attribute carrying the language CoreText uses to pick hyphenation rules.
    static let languageAttributeKey = NSAttributedString.Key(kCTLanguageAttributeName as String)

    /// Paragraph hyphenation strength (0…1). 1.0 = always prefer breaking a word over leaving a gap.
    static let factor: Float = 1.0

    /// Language tag to attach to `text` so CoreText will hyphenate it, or nil to leave it untagged.
    ///
    /// An explicit tag is required, not a nicety: without one CoreText falls back to the system
    /// locale, so an English book silently fails to hyphenate for a reader whose phone is set to
    /// Chinese — which describes most of this app's readers.
    ///
    /// Text containing ANY CJK is never tagged. The language attribute also drives Han glyph variant
    /// selection (a `zh` vs `ja` tag picks visibly different shapes for the same codepoint), so a
    /// wrong tag would swap glyphs — a far worse regression than a missing hyphen. Such text does
    /// not hyphenate anyway.
    ///
    /// The tag is `en`: Latin text here is overwhelmingly English, and EPUB's own `lang` attribute
    /// is not carried through the render pipeline. A German/French book therefore hyphenates by
    /// English rules — imperfect, but better than not breaking at all. Reading the publication
    /// language from EPUB metadata is the upgrade path if that ever matters.
    static func language(for text: String) -> String? {
        var latinLetters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A,   // A-Z
                 0x0061...0x007A:   // a-z
                latinLetters += 1
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul Syllables
                return nil          // any CJK present — never tag
            default:
                continue
            }
        }
        return latinLetters > 0 ? "en" : nil
    }

    /// Adds the language tag to `attributes` when `text` is hyphenatable Latin script.
    static func tagging(
        _ attributes: [NSAttributedString.Key: Any],
        forText text: String
    ) -> [NSAttributedString.Key: Any] {
        guard let language = language(for: text) else { return attributes }
        var tagged = attributes
        tagged[languageAttributeKey] = language
        return tagged
    }
}
