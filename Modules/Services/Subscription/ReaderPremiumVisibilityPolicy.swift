import Foundation

/// Visibility rules for reader customization surfaces that should not be
/// discoverable until the single Yuedu Pro entitlement is active.
struct ReaderPremiumVisibilityPolicy {
    let isProActive: Bool

    var showsReaderDecoration: Bool { isProActive }
    var showsBottomTabCustomization: Bool { isProActive }
    var showsBackgroundImageImport: Bool { isProActive }
    var showsLayoutPresetImport: Bool { isProActive }
    var showsTouchZoneEditor: Bool { isProActive }

    func showsCommentBubbleSettings(hasParagraphReviews: Bool) -> Bool {
        isProActive && hasParagraphReviews
    }
}
