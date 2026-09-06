import UIKit

/// Keeps the authored or reader-selected font as the primary face while supplying fallbacks for
/// characters it cannot draw. Replacing a CJK primary font with Georgia makes every ASCII digit
/// and Latin letter use Georgia even when the selected font contains those glyphs.
enum ReaderFontCascade {
    private static let fallbackFontNames = [
        "Georgia",
        "PingFangSC-Regular",
        "STHeitiSC-Light",
        "AppleColorEmoji",
    ]

    /// Fallback descriptors carry the real point size, never `0`.
    ///
    /// `size: 0` is the usual "inherit the primary font's size" idiom, and it does
    /// inherit — but only while CoreText can use the descriptor as written. When the
    /// primary font carries a bold trait, CoreText re-matches every fallback against
    /// that trait (PingFangSC-Regular → PingFangSC-Semibold), and the re-matched
    /// descriptor keeps the literal `size 0`, which resolves to CoreText's 12pt
    /// default. That is why switching 粗體 on shrank every CJK glyph to 12pt while
    /// Latin text — drawn by the primary font itself — stayed at the reader size.
    static func descriptors(size: CGFloat) -> [UIFontDescriptor] {
        fallbackFontNames.map { UIFontDescriptor(name: $0, size: size) }
    }

    static func attributes(size: CGFloat) -> [UIFontDescriptor.AttributeName: Any] {
        [.cascadeList: descriptors(size: size)]
    }

    static func preservingPrimary(_ font: UIFont, size: CGFloat) -> UIFont {
        UIFont(
            descriptor: font.fontDescriptor.addingAttributes(attributes(size: size)),
            size: size
        )
    }
}
