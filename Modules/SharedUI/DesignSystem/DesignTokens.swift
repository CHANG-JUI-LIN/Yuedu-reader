import SwiftUI
import UIKit

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
    // When an app appearance theme is active these retint the whole app; with
    // no theme (classic) they resolve to the exact system colors as before.
    /// Page background
    static var background: Color { themed(\.appPageBackground) ?? Color(.systemBackground) }
    /// Group / card background
    static var surface: Color { themed(\.appCardBackground) ?? Color(.secondarySystemBackground) }
    /// Tertiary background (nested groups)
    static var surfaceTertiary: Color { themed(\.appSecondaryBackground) ?? Color(.tertiarySystemBackground) }
    /// Grouped content background
    static var groupedBackground: Color { themed(\.appPageBackground) ?? Color(.systemGroupedBackground) }
    /// Neutral gray fill for controls that must not inherit an appearance-theme tint.
    static let neutralControlFill = Color(uiColor: .systemGray5)
    /// Pressed-state fill layered inside `neutralControlFill` controls (pre-iOS 26 fallback).
    static let neutralControlPressedFill = Color(uiColor: .systemGray3)

    // ── Borders & Separators ──
    /// Thin separator
    static var separator: Color { themed(\.appSeparator) ?? Color(.separator) }
    /// Light border
    static var border: Color { themed(\.appBorder) ?? Color(.systemGray4) }

    /// Resolves a themed surface color from the active app theme, or nil when no
    /// theme is active (classic/system).
    private static func themed(_ keyPath: KeyPath<AppearanceThemePreset, UIColor>) -> Color? {
        guard let theme = AppearanceThemePreset.activeAppTheme else { return nil }
        return Color(uiColor: theme[keyPath: keyPath])
    }

    // ── Functional ──
    /// Light label / selected background
    static let accentLight = Color.accentColor.opacity(0.08)
    /// Card shadow
    static let shadow = Color.black.opacity(0.05)
    /// Selected highlight
    static let highlight = Color.accentColor.opacity(0.15)

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
    /// Smallest label (11pt)
    static var caption2: Font { GlobalAppTypography.font(.caption2) }
    /// Small caption (12pt)
    static var caption: Font { GlobalAppTypography.font(.caption) }
    /// Footnote (13pt)
    static var footnote: Font { GlobalAppTypography.font(.footnote) }
    /// Subheadline (15pt)
    static var subheadline: Font { GlobalAppTypography.font(.subheadline) }
    /// Callout (16pt)
    static var callout: Font { GlobalAppTypography.font(.callout) }
    /// Body (17pt)
    static var body: Font { GlobalAppTypography.font(.body) }
    /// Body bold
    static var bodyBold: Font { GlobalAppTypography.font(.body, weight: .semibold) }
    /// Headline (17pt bold)
    static var headline: Font { GlobalAppTypography.font(.headline) }
    /// Title 3 (20pt)
    static var title3: Font { GlobalAppTypography.font(.title3) }
    /// Title 2 (22pt)
    static var title2: Font { GlobalAppTypography.font(.title2) }
    /// Title (28pt)
    static var title: Font { GlobalAppTypography.font(.title) }
    /// Large title (34pt)
    static var largeTitle: Font { GlobalAppTypography.font(.largeTitle) }

    /// Existing fixed-size UI typography. Monospaced content intentionally
    /// remains system monospaced even when a global interface font is active.
    static func fixed(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        GlobalAppTypography.fixedFont(
            size: size,
            weight: weight,
            systemDesign: design
        )
    }

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
    /// Standard control height in the compact reader quick-settings panel.
    static let readerQuickPanelControlHeight: CGFloat = 54
    /// Compact control height for the quick panel's top toolbar buttons.
    static let readerQuickPanelTopControlHeight: CGFloat = 46
    /// Width reserved for the two icon menus in reader quick settings.
    static let readerQuickPanelMenuWidth: CGFloat = 132
    /// Compact width reserved for the two icon menus in reader quick settings.
    static let readerQuickPanelTopMenuWidth: CGFloat = 120
    /// Height of a landscape reading-background preview button.
    static let readerQuickPanelReadingBackgroundTileHeight: CGFloat = 82
    /// Height reserved for a 3x2 reading-background page and its page indicator.
    static let readerQuickPanelReadingBackgroundPagerHeight: CGFloat = 214
    /// Fixed iOS 17 detent height for the reader quick settings sheet.
    static let readerQuickPanelSheetHeight: CGFloat = 508
    /// Minimum height of the paragraph-comment SVG editor.
    static let readerSVGEditorHeight: CGFloat = 160
    /// Compact fixed width for a paragraph-comment bubble preview tile.
    static let readerBubblePreviewTileWidth: CGFloat = 80
    /// Minimum height of a paragraph-comment bubble preview tile.
    static let readerBubblePreviewHeight: CGFloat = 76
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
    /// Extra-extra-large radius (large preview tiles, prominent panel buttons)
    static let xxl: CGFloat = 20
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

// MARK: - View Extensions

extension View {
    /// Applies `.inlineLarge` toolbar title display mode on iOS 18+,
    /// falling back to `.large` on earlier versions where `.inlineLarge` is unavailable.
    @ViewBuilder
    func toolbarTitleDisplayModeInlineLarge() -> some View {
        if #available(iOS 18, *) {
            self.toolbarTitleDisplayMode(.inlineLarge)
        } else {
            self.toolbarTitleDisplayMode(.large)
        }
    }

    /// Like `toolbarTitleDisplayModeInlineLarge()`, but falls back to `.inline`
    /// on iOS 17 instead of `.large`. Use on views that also apply `.refreshable`
    /// — combining `.large` with SwiftUI's `.refreshable` on iOS 17 triggers an
    /// infinite layout recursion in `_UINavigationBarLayout` +
    /// `_UINavigationControllerRefreshControlHost` (`EXC_BAD_ACCESS`).
    @ViewBuilder
    func toolbarTitleDisplayModeInlineLargeOrInline() -> some View {
        if #available(iOS 18, *) {
            self.toolbarTitleDisplayMode(.inlineLarge)
        } else {
            self.toolbarTitleDisplayMode(.inline)
        }
    }
}
