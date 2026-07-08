import Foundation

/// A capability unlocked by an active `Yuedu Pro` subscription.
///
/// Gating is intentionally coarse in v1: every feature maps to the single
/// `isProActive` entitlement. The enum still enumerates each capability so the
/// UI can render per-feature rows, and so a future tiered plan can map features
/// to different entitlements without touching call sites.
enum PremiumFeature: String, CaseIterable, Identifiable, Hashable {
    case customFonts
    case touchZoneEditor
    case dialogueHighlight
    case layoutPresetImport
    case readerBackgroundImport
    case bottomBarCustomization
    case readerThemePacks
    case alternateAppIcons

    var id: String { rawValue }

    /// SF Symbol used in the Pro settings feature list and paywall.
    var iconName: String {
        switch self {
        case .customFonts: return "textformat"
        case .touchZoneEditor: return "hand.tap"
        case .dialogueHighlight: return "text.bubble"
        case .layoutPresetImport: return "slider.horizontal.3"
        case .readerBackgroundImport: return "photo.on.rectangle.angled"
        case .bottomBarCustomization: return "square.grid.2x2"
        case .readerThemePacks: return "paintpalette"
        case .alternateAppIcons: return "app.badge"
        }
    }

    /// Localization key for the short feature title.
    var titleKey: String {
        switch self {
        case .customFonts: return "字體導入"
        case .touchZoneEditor: return "翻頁區塊編輯"
        case .dialogueHighlight: return "對話高亮"
        case .layoutPresetImport: return "排版參數導入"
        case .readerBackgroundImport: return "閱讀背景導入"
        case .bottomBarCustomization: return "底部導覽列自訂"
        case .readerThemePacks: return "外觀主題包"
        case .alternateAppIcons: return "桌面圖標切換"
        }
    }

    /// Localization key for the one-line feature description.
    var subtitleKey: String {
        switch self {
        case .customFonts: return "匯入並切換自訂字體"
        case .touchZoneEditor: return "自訂 3×3 翻頁點擊區塊"
        case .dialogueHighlight: return "自動高亮引號對話與角色台詞"
        case .layoutPresetImport: return "匯入排版參數 preset 一鍵套用"
        case .readerBackgroundImport: return "匯入圖片作為閱讀背景"
        case .bottomBarCustomization: return "自訂底部 Tab 頁面、大小與圖標"
        case .readerThemePacks: return "套用整組外觀主題與閱讀主題配色"
        case .alternateAppIcons: return "切換預置的桌面圖標"
        }
    }

    var localizedTitle: String { localized(titleKey) }
    var localizedSubtitle: String { localized(subtitleKey) }
}
