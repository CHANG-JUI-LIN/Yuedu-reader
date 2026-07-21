import UIKit

enum UserReaderFontResolver {
    static var selectedPostScriptName: String? {
        guard let postScriptName = GlobalSettings.shared.selectedReaderFontPostScript,
              !postScriptName.isEmpty
        else { return nil }
        return postScriptName
    }

    static func bodyFont(size: CGFloat, isBold: Bool = false) -> UIFont {
        let baseFont = selectedFont(size: size) ?? UIFont.systemFont(ofSize: size)
        if isBold || GlobalSettings.shared.readerFontBold {
            return boldVersion(of: baseFont, size: size)
        }
        return baseFont
    }

    /// Font for the in-content chapter title.
    /// - Parameters:
    ///   - weight: explicit title weight (no longer always bold).
    ///   - postScriptName: per-segment font override; `nil` follows the reader
    ///     font (or system font when none is selected).
    static func titleFont(size: CGFloat, weight: ChapterTitleWeight, postScriptName: String?) -> UIFont {
        let resolvedName = postScriptName ?? selectedPostScriptName
        let baseFont: UIFont
        if let resolvedName, let named = UIFont(name: resolvedName, size: size) {
            baseFont = named
        } else {
            baseFont = UIFont.systemFont(ofSize: size, weight: weight.uiFontWeight)
        }
        return weightedFont(baseFont, size: size, weight: weight.uiFontWeight)
    }

    private static func selectedFont(size: CGFloat) -> UIFont? {
        guard let postScriptName = selectedPostScriptName else { return nil }
        return UIFont(name: postScriptName, size: size)
    }

    /// Coerce `font` to `weight`. Uses the weight trait so system and most named
    /// fonts pick their matching face; for bold-ish weights also requests the
    /// bold symbolic trait so families that only expose bold via `traitBold`
    /// (not a weight axis) still resolve, and synthesises otherwise.
    private static func weightedFont(_ font: UIFont, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        var descriptor = font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        if weight.rawValue >= UIFont.Weight.semibold.rawValue,
           let boldDescriptor = descriptor.withSymbolicTraits(.traitBold) {
            descriptor = boldDescriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func boldVersion(of font: UIFont, size: CGFloat) -> UIFont {
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
            return font
        }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        // Synthetic bold for fonts without native bold face
        let attrs: [UIFontDescriptor.AttributeName: Any] = [
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
        ]
        return UIFont(descriptor: font.fontDescriptor.addingAttributes(attrs), size: size)
    }
}
