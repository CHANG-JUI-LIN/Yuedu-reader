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

    static func descriptors() -> [UIFontDescriptor] {
        fallbackFontNames.compactMap { UIFontDescriptor(name: $0, size: 0) }
    }

    static func attributes() -> [UIFontDescriptor.AttributeName: Any] {
        let fallbacks = descriptors()
        guard !fallbacks.isEmpty else { return [:] }
        return [.cascadeList: fallbacks]
    }

    static func preservingPrimary(_ font: UIFont, size: CGFloat) -> UIFont {
        UIFont(
            descriptor: font.fontDescriptor.addingAttributes(attributes()),
            size: size
        )
    }
}
