import SwiftUI

// MARK: - 設計系統：顏色 Token

enum DSColor {
    // ── 品牌色 ──
    /// 主要強調色（按鈕、連結、選中態）
    static let accent = Color.accentColor
    /// 成功狀態
    static let success = Color.green
    /// 警告狀態
    static let warning = Color.orange
    /// 危險/刪除
    static let destructive = Color.red

    // ── 文字 ──
    /// 主要文字（自動適配亮/暗模式）
    static let textPrimary = Color.primary
    /// 次要文字（說明、副標題）
    static let textSecondary = Color.secondary
    /// 禁用狀態文字
    static let textDisabled = Color.secondary.opacity(0.5)

    // ── 背景 ──
    /// 頁面底色
    static let background = Color(.systemBackground)
    /// 分組/卡片背景
    static let surface = Color(.secondarySystemBackground)
    /// 三級背景（嵌套分組）
    static let surfaceTertiary = Color(.tertiarySystemBackground)
    /// 分組內容背景
    static let groupedBackground = Color(.systemGroupedBackground)

    // ── 邊框與分隔線 ──
    /// 細分隔線
    static let separator = Color(.separator)
    /// 輕量邊框
    static let border = Color(.systemGray4)

    // ── 功能色 ──
    /// 淺色標籤/選中背景
    static let accentLight = Color.blue.opacity(0.08)
    /// 卡片陰影
    static let shadow = Color.black.opacity(0.05)
    /// 選中高亮
    static let highlight = Color.blue.opacity(0.15)

    // ── 書封面漸層調色板 ──
    static let coverGradients: [[Color]] = [
        [Color(red: 0.2, green: 0.3, blue: 0.7), Color(red: 0.1, green: 0.6, blue: 0.8)],
        [Color(red: 0.6, green: 0.1, blue: 0.1), Color(red: 0.9, green: 0.4, blue: 0.1)],
        [Color(red: 0.1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.7, blue: 0.4)],
        [Color(red: 0.4, green: 0.0, blue: 0.5), Color(red: 0.7, green: 0.2, blue: 0.6)],
        [Color(red: 0.1, green: 0.1, blue: 0.15), Color(red: 0.3, green: 0.3, blue: 0.5)],
    ]

    // ── 搜尋引擎品牌色 ──
    static let brandBaidu = Color(red: 0.1, green: 0.4, blue: 0.9)
    static let brandBing = Color(red: 0.0, green: 0.5, blue: 0.7)
}

// MARK: - 設計系統：字體 Token

enum DSFont {
    /// 最小標籤（10pt）
    static let caption2 = Font.caption2
    /// 小型說明文字（12pt）
    static let caption = Font.caption
    /// 副標題（15pt）
    static let subheadline = Font.subheadline
    /// 正文（17pt）
    static let body = Font.body
    /// 正文粗體
    static let bodyBold = Font.body.weight(.semibold)
    /// 標題級（17pt bold）
    static let headline = Font.headline
    /// 次級標題（22pt）
    static let title2 = Font.title2
    /// 主標題（28pt）
    static let title = Font.title
    /// 大標題（34pt）
    static let largeTitle = Font.largeTitle

    /// 等寬字體（代碼/規則/URL）
    static func monospaced(size: CGFloat = 13) -> Font {
        .system(size: size, design: .monospaced)
    }

    /// 工具欄圖標字體
    static let toolbarIcon = Font.system(size: 16)
    /// 工具欄大圖標
    static let toolbarIconLarge = Font.system(size: 18, weight: .semibold)
}

// MARK: - 設計系統：間距 Token

enum DSSpacing {
    /// 4pt — 極小間距（緊湊元素間）
    static let xs: CGFloat = 4
    /// 8pt — 小間距（元素內部）
    static let sm: CGFloat = 8
    /// 12pt — 中間距（元素之間）
    static let md: CGFloat = 12
    /// 16pt — 大間距（分組/區塊之間）
    static let lg: CGFloat = 16
    /// 24pt — 超大間距（頁面留白）
    static let xl: CGFloat = 24
    /// 32pt — 最大間距（區域分隔）
    static let xxl: CGFloat = 32
}

// MARK: - 設計系統：圓角 Token

enum DSRadius {
    /// 小圓角（標籤、小按鈕）
    static let sm: CGFloat = 6
    /// 中圓角（按鈕、輸入框）
    static let md: CGFloat = 8
    /// 大圓角（卡片、對話框）
    static let lg: CGFloat = 12
    /// 超大圓角（圖片容器）
    static let xl: CGFloat = 16
}

// MARK: - 設計系統：動畫 Token

enum DSAnimation {
    /// 快速交互反饋
    static let fast = Animation.easeOut(duration: 0.15)
    /// 標準過渡
    static let standard = Animation.easeOut(duration: 0.28)
    /// 慢速展開
    static let slow = Animation.easeInOut(duration: 0.4)
}
