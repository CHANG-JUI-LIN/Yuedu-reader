import UIKit
import YueduCoreTextTypography

extension NSAttributedString {
    /// The font the text at `location` asked for. A CJK character that font has no
    /// glyph for is drawn by its language's stand-in (`CJKTypography.applyFonts`), which
    /// records the font it stands in for; tests of font selection read that one.
    func askedFont(at location: Int) -> UIFont? {
        (attribute(CJKTypography.replacedFontAttribute, at: location, effectiveRange: nil)
            ?? attribute(.font, at: location, effectiveRange: nil)) as? UIFont
    }
}
