import CoreText
import UIKit

enum UserReaderFontResolver {
    /// A negative stroke width fills the glyph and expands its outline. CoreText
    /// interprets the value as a percentage of the point size, so this scales
    /// with the reader font without changing line metrics.
    private static let syntheticBoldStrokeWidth = -2.5 as NSNumber

    static var selectedPostScriptName: String? {
        guard let postScriptName = GlobalSettings.shared.selectedReaderFontPostScript,
              !postScriptName.isEmpty
        else { return nil }
        return postScriptName
    }

    static func bodyFont(size: CGFloat, isBold: Bool = false) -> UIFont {
        let baseFont = selectedFont(size: size) ?? UIFont.systemFont(ofSize: size)
        if bodyBoldRequested(isBold: isBold) {
            return boldVersion(of: baseFont, size: size)
        }
        return baseFont
    }

    static func bodyBoldRequested(isBold: Bool) -> Bool {
        isBold || GlobalSettings.shared.readerFontBold
    }

    /// Returns the only extra attributed-string attributes required to render a
    /// requested bold face. The stroke is deliberately limited to fonts that
    /// have neither a native bold trait nor a variable-weight axis; regular-only
    /// custom fonts otherwise keep returning their unchanged Regular face from
    /// `UIFontDescriptor`, which is why the old "synthetic" bold was invisible.
    /// This compatibility path can be removed once CoreText exposes a real
    /// emboldening transform for static fonts.
    static func syntheticBoldAttributes(
        for font: UIFont,
        isBoldRequested: Bool
    ) -> [NSAttributedString.Key: Any] {
        guard isBoldRequested,
              !font.fontDescriptor.symbolicTraits.contains(.traitBold),
              !supportsVariableWeight(font)
        else { return [:] }
        return [.strokeWidth: syntheticBoldStrokeWidth]
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

    private static func supportsVariableWeight(_ font: UIFont) -> Bool {
        guard let axes = CTFontCopyVariationAxes(font as CTFont) as? [[CFString: Any]] else {
            return false
        }
        return axes.contains { axis in
            guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber else {
                return false
            }
            // OpenType `wght` is encoded as the four-character tag 0x77676874.
            return identifier.uint32Value == 0x7767_6874
        }
    }
}
