import Testing
@testable import yuedu_app

/// A face limited by `unicode-range` to characters without the space is not the primary font
/// (CSS Fonts 4 §5.2). 草枕 embeds seven dash glyphs as the first `font-family` name.
@Suite("@font-face unicode-range")
struct FontFaceUnicodeRangeTests {
    @Test(arguments: [
        ("u+2013-2016", false), ("u+0-7f", true), ("u+20", true), ("u+4??", false), ("u+??", true),
        ("u+2013-2016, u+0020-007e", true), ("u+3000-30ff,u+4e00-9fff", false), ("nonsense", true),
    ])
    func whetherARangeHoldsTheSpace(_ value: String, _ expected: Bool) {
        #expect(EPUBStyleResolver.unicodeRangeCoversSpace(value) == expected)
    }
}
