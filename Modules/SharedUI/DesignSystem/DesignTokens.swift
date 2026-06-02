import SwiftUI

// MARK: - Design System: Color Tokens

enum DSColor {
    // ── Brand ──
    /// Primary accent (buttons, links, selected state)
    static let accent = Color.accentColor
    /// Success state
    static let success = Color.green
    /// Warning state
    static let warning = Color.orange
    /// Destructive / delete
    static let destructive = Color.red

    // ── Text ──
    /// Primary text (auto-adapts to light/dark mode)
    static let textPrimary = Color.primary
    /// Text on strong functional fills.
    static let textOnAccent = Color.white
    /// Secondary text (captions, subtitles)
    static let textSecondary = Color.secondary
    /// Disabled text
    static let textDisabled = Color.secondary.opacity(0.5)

    // ── Background ──
    /// Page background
    static let background = Color(.systemBackground)
    /// Group / card background
    static let surface = Color(.secondarySystemBackground)
    /// Tertiary background (nested groups)
    static let surfaceTertiary = Color(.tertiarySystemBackground)
    /// Grouped content background
    static let groupedBackground = Color(.systemGroupedBackground)

    // ── Borders & Separators ──
    /// Thin separator
    static let separator = Color(.separator)
    /// Light border
    static let border = Color(.systemGray4)

    // ── Functional ──
    /// Light label / selected background
    static let accentLight = Color.blue.opacity(0.08)
    /// Card shadow
    static let shadow = Color.black.opacity(0.05)
    /// Selected highlight
    static let highlight = Color.blue.opacity(0.15)

    // ── Book Cover Gradient Palette ──
    static let coverGradients: [[Color]] = [
        [Color(red: 0.2, green: 0.3, blue: 0.7), Color(red: 0.1, green: 0.6, blue: 0.8)],
        [Color(red: 0.6, green: 0.1, blue: 0.1), Color(red: 0.9, green: 0.4, blue: 0.1)],
        [Color(red: 0.1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.7, blue: 0.4)],
        [Color(red: 0.4, green: 0.0, blue: 0.5), Color(red: 0.7, green: 0.2, blue: 0.6)],
        [Color(red: 0.1, green: 0.1, blue: 0.15), Color(red: 0.3, green: 0.3, blue: 0.5)],
    ]

    // ── Search Engine Brand Colors ──
    static let brandBaidu = Color(red: 0.1, green: 0.4, blue: 0.9)
    static let brandBing = Color(red: 0.0, green: 0.5, blue: 0.7)
}

// MARK: - Design System: Font Tokens

enum DSFont {
    /// Smallest label (10pt)
    static let caption2 = Font.caption2
    /// Small caption (12pt)
    static let caption = Font.caption
    /// Subheadline (15pt)
    static let subheadline = Font.subheadline
    /// Body (17pt)
    static let body = Font.body
    /// Body bold
    static let bodyBold = Font.body.weight(.semibold)
    /// Headline (17pt bold)
    static let headline = Font.headline
    /// Title 2 (22pt)
    static let title2 = Font.title2
    /// Title (28pt)
    static let title = Font.title
    /// Large title (34pt)
    static let largeTitle = Font.largeTitle

    /// Monospaced font for code, rules, and URLs
    static func monospaced(size: CGFloat = 13) -> Font {
        .system(size: size, design: .monospaced)
    }

    /// Toolbar icon font
    static let toolbarIcon = Font.system(size: 16)
    /// Toolbar large icon
    static let toolbarIconLarge = Font.system(size: 18, weight: .semibold)
}

// MARK: - Design System: Spacing Tokens

enum DSSpacing {
    /// 4pt — extra-small (between compact elements)
    static let xs: CGFloat = 4
    /// 8pt — small (within elements)
    static let sm: CGFloat = 8
    /// 12pt — medium (between elements)
    static let md: CGFloat = 12
    /// 16pt — large (between groups / blocks)
    static let lg: CGFloat = 16
    /// 24pt — extra-large (page padding)
    static let xl: CGFloat = 24
    /// 32pt — maximum (region separation)
    static let xxl: CGFloat = 32
}

// MARK: - Design System: Layout Tokens

enum DSLayout {
    /// Narrow modal content such as confirmations or small pickers.
    static let readableNarrowWidth: CGFloat = 480
    /// Compact sheets with short forms or account actions.
    static let readableCompactWidth: CGFloat = 640
    /// iPad form width optimized for grouped settings readability.
    static let readableFormWidth: CGFloat = 700
    /// Standard sheet/list width for settings, reader panels, and focused lists.
    static let readableListWidth: CGFloat = 760
    /// Wider inspector or preview panels.
    static let readablePanelWidth: CGFloat = 820
    /// Search and source-management layouts that need more horizontal room.
    static let readableExpandedWidth: CGFloat = 900
    /// Bookshelf content width with multiple columns.
    static let readableShelfWidth: CGFloat = 920
    /// Reader overlays that should not span the entire iPad display.
    static let readableOverlayWidth: CGFloat = 960
    /// Wide management surfaces such as book-source lists.
    static let readableWideWidth: CGFloat = 980
    /// Extra horizontal inset applied to regular-width reader pages.
    static let readerRegularExtraHorizontalInset: CGFloat = 28
    /// Gutter between two pages in iPad landscape spread mode.
    static let readerSpreadGutter: CGFloat = 28
}

// MARK: - Design System: Corner Radius Tokens

enum DSRadius {
    /// Small radius (labels, small buttons)
    static let sm: CGFloat = 6
    /// Medium radius (buttons, input fields)
    static let md: CGFloat = 8
    /// Large radius (cards, dialogs)
    static let lg: CGFloat = 12
    /// Extra-large radius (image containers)
    static let xl: CGFloat = 16
}

// MARK: - Design System: Animation Tokens

enum DSAnimation {
    /// Fast interactive feedback
    static let fast = Animation.easeOut(duration: 0.15)
    /// Standard transition
    static let standard = Animation.easeOut(duration: 0.28)
    /// Slow expansion
    static let slow = Animation.easeInOut(duration: 0.4)
}
