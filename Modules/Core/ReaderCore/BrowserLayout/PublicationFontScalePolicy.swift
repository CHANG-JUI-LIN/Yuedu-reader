import Foundation

/// Chapter font-scale policy — how the user's reader font-size setting applies
/// to a chapter's layout.
///
/// - `readerAdjustable`: the user's font-size setting drives the root font size
///   (the default; matches the legacy reader behavior).
/// - `fixed`: the chapter pins its typography to the publication/UA base font
///   size (17pt — the CSS standard root, NOT book-specific). The user's
///   font-size setting is ignored; author-relative `em`/`%` sizes still resolve
///   against that fixed base, so the author's proportions are preserved while
///   the whole chapter renders at publication scale.
///
/// Detection is property-based, never book-specific: a body inline style
/// declaring `zy-fontsize-adjust: fixed` opts the chapter in. Anything else
/// stays `readerAdjustable`.
enum PublicationFontScalePolicy: Equatable {
    case readerAdjustable
    case fixed

    /// The font size that becomes the layout root (`BrowserLayoutConfig.rootFontSize`).
    /// `readerAdjustable` → the user's setting; `fixed` → the UA base (17pt).
    func rootFontSize(userSetting: CGFloat) -> CGFloat {
        switch self {
        case .readerAdjustable: return userSetting
        case .fixed: return 17
        }
    }

    /// Resolves the policy from a chapter's body element inline style.
    /// Parsed via the shared CSS declaration parser (one data path).
    static func resolve(bodyInlineStyle: String) -> PublicationFontScalePolicy {
        let decl = CSSParser.parseDeclarationBlock(bodyInlineStyle)
        let value = (decl.normal["zy-fontsize-adjust"] ?? decl.important["zy-fontsize-adjust"])
            ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fixed"
            ? .fixed
            : .readerAdjustable
    }
}
