import Foundation

/// A capability unlocked by an active `Yuedu Pro` subscription.
///
/// Gating is intentionally coarse in v1: every feature maps to the single
/// `isProActive` entitlement. The enum still enumerates each capability so the
/// UI can render per-feature rows, and so a future tiered plan can map features
/// to different entitlements without touching call sites.
enum PremiumFeature: String, CaseIterable, Identifiable, Hashable {
    /// Every AI feature: 助手, 整章翻譯, 選字的問 AI／解釋／查詞／翻譯, AI 整理書架.
    case aiReading
    case paragraphNote
    case customFonts
    case touchZoneEditor
    case dialogueHighlight
    case layoutPresetImport
    case readerBackgroundImport
    case bottomBarCustomization
    case readerThemePacks
    case alternateAppIcons
    case launchScreen
    /// 新增模組: adding a module that is not the app's own — from an address, a file, the
    /// clipboard, a `yuedu://module` link or a repository (maintainer, 2026-11-15). The official
    /// modules, the modules already installed and their updates stay free: only the way in is Pro.
    case moduleImport
    /// 閱讀樣式: applying a built-in style, saving one's own, and 只套用到這本書
    /// (maintainer, 2026-11-21). Every setting a style sets stays free to change by hand.
    case readingStyles

    var id: String { rawValue }

    /// Features that are implemented and may be advertised in Pro surfaces.
    /// Alternate app icons remain an internal capability key that does not ship and must
    /// not appear as marketing. `readerThemePacks` does ship — it gates 外觀主題's custom
    /// palettes and page backgrounds — and was missing from the paywall until 2026-09-27.
    static func marketedFeatures(highlighting highlightedFeature: PremiumFeature? = nil) -> [PremiumFeature] {
        let unavailable: Set<PremiumFeature> = [.alternateAppIcons]
        let available = allCases.filter { !unavailable.contains($0) }
        guard let highlightedFeature, available.contains(highlightedFeature) else {
            return available
        }
        return [highlightedFeature] + available.filter { $0 != highlightedFeature }
    }

    /// SF Symbol used in the Pro settings feature list and paywall.
    var iconName: String {
        switch self {
        case .aiReading: return "sparkles"
        case .paragraphNote: return "note.text"
        case .customFonts: return "f.cursive"
        case .touchZoneEditor: return "hand.tap"
        case .dialogueHighlight: return "text.bubble"
        case .layoutPresetImport: return "slider.horizontal.3"
        case .readerBackgroundImport: return "photo.on.rectangle.angled"
        case .bottomBarCustomization: return "square.grid.2x2"
        case .readerThemePacks: return "paintpalette"
        case .alternateAppIcons: return "app.badge"
        case .launchScreen: return "app.dashed"
        case .moduleImport: return "puzzlepiece.extension"
        case .readingStyles: return "rectangle.stack"
        }
    }

    /// Localization key for the short feature title. Same words as the paywall's benefit
    /// rows (`PremiumPillar`), so a feature is called one thing everywhere Pro is sold.
    var titleKey: String {
        switch self {
        case .aiReading: return "AI 閱讀助手"
        case .paragraphNote: return "段落筆記"
        case .customFonts: return "字體匯入"
        case .touchZoneEditor: return "翻頁區塊"
        case .dialogueHighlight: return "對話氣泡與高亮"
        case .layoutPresetImport: return "排版備份"
        case .readerBackgroundImport: return "自訂閱讀背景"
        case .bottomBarCustomization: return "底部分頁"
        case .readerThemePacks: return "外觀主題"
        case .alternateAppIcons: return "桌面圖標切換"
        case .launchScreen: return "啟動圖"
        case .moduleImport: return "新增模組"
        case .readingStyles: return "閱讀樣式"
        }
    }

    /// Localization key for the one-line feature description: what the reader gets.
    var subtitleKey: String {
        switch self {
        case .aiReading: return "問書、整章翻譯、查詞與整理書架"
        case .paragraphNote: return "在劃線旁寫下想法，筆記跟著原文走"
        case .customFonts: return "匯入喜歡的字體，閱讀和介面都能用"
        case .touchZoneEditor: return "畫面分成 3×3，每一格點了做什麼由你決定"
        case .dialogueHighlight: return "對白排成聊天氣泡，重點按規則自動上色"
        case .layoutPresetImport: return "整套排版匯出匯入，也能讀 Legado 的設定檔"
        case .readerBackgroundImport: return "用自己的圖片當書頁背景"
        case .bottomBarCustomization: return "自訂底部 Tab 的頁面、大小與圖示"
        case .readerThemePacks: return "App 與閱讀配色、頁面背景，都能自己調"
        case .alternateAppIcons: return "切換預置的桌面圖標"
        case .launchScreen: return "換上你自己的開屏畫面"
        case .moduleImport: return "從網址、檔案或剪貼簿加入第三方模組"
        case .readingStyles: return "內建多套排版，也能把自己的設定存成樣式"
        }
    }

    var localizedTitle: String { localized(titleKey) }
    var localizedSubtitle: String { localized(subtitleKey) }
}
