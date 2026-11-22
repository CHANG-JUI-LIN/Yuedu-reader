import Testing
@testable import yuedu_app

/// A face limited by `unicode-range` to marks is not the primary font (CSS Fonts 4 §5.2
/// excludes any face without the space; a subset of a text face still has to draw its text,
/// which a cascade behind another family would not let it). 草枕 embeds seven dash glyphs as
/// the first `font-family` name.
@Suite("@font-face unicode-range")
struct FontFaceUnicodeRangeTests {
    @Test(arguments: [
        ("u+2013-2016", false), ("u+2000-206f, u+3000-303f", false), ("u+ff01-ff5e", false),
        ("u+0-7f", true), ("u+20", true), ("u+4??", false), ("u+??", true),
        ("u+2013-2016, u+0020-007e", true),
        // Subsets of a text face keep drawing their text.
        ("u+4e00-9fff", true), ("u+3041-3096", true), ("u+61", true), ("u+ac00-d7af", true),
        ("nonsense", true),
    ])
    func whetherARangeHoldsText(_ value: String, _ expected: Bool) {
        #expect(EPUBStyleResolver.unicodeRangeCoversText(value) == expected)
    }
}
