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
    static var background: Color { themed(\.appPageBackground, fallback: .systemBackground) }
    /// Group / card background
    static var surface: Color { themed(\.appCardBackground, fallback: .secondarySystemGroupedBackground) }
    /// Tertiary background (nested groups)
    static var surfaceTertiary: Color { themed(\.appSecondaryBackground, fallback: .tertiarySystemBackground) }
    /// Grouped content background
    static var groupedBackground: Color { themed(\.appPageBackground, fallback: .systemGroupedBackground) }
    /// Neutral gray fill for controls that must not inherit an appearance-theme tint.
    static let neutralControlFill = Color(uiColor: .systemGray5)
    /// Pressed-state fill layered inside `neutralControlFill` controls (pre-iOS 26 fallback).
    static let neutralControlPressedFill = Color(uiColor: .systemGray3)
    /// Strong neutral fill used by the emphasized Apple Books reader-menu row.
    static let neutralControlEmphasizedFill = Color.black
    /// Foreground drawn on the black emphasized reader control.
    static let neutralControlEmphasizedForeground = Color.white
    /// Solid read-progress fill inside the emphasized reader scrubber.
    static let neutralControlProgressFill = Color.white
    /// Text drawn over the solid white read-progress fill.
    static let neutralControlProgressForeground = Color.black

    // ── Borders & Separators ──
    /// Thin separator
    static var separator: Color { themed(\.appSeparator, fallback: .separator) }
    /// Light border
    static var border: Color { themed(\.appBorder, fallback: .systemGray4) }

    /// Resolves a themed surface color as a **dynamic** color.
    ///
    /// UIKit picks the light or dark palette from the trait collection in effect when a
    /// view actually draws, so the result no longer depends on when `activeAppThemes` was
    /// last written. That ordering was the bug: only `ContentView.body` refreshes the
    /// global on a system appearance change, and SwiftUI can re-render a themed screen
    /// before it runs, leaving dark mode painted with light-mode surfaces.
    ///
    /// - Parameter fallback: the system color for an appearance with no theme (classic).
    private static func themed(
        _ keyPath: KeyPath<AppearanceThemePreset, UIColor>,
        fallback: UIColor
    ) -> Color {
        let themes = AppearanceThemePreset.activeAppThemes
        guard themes.isActive else { return Color(uiColor: fallback) }
        return Color(uiColor: UIColor { traits in
            themes.theme(for: traits.userInterfaceStyle)?[keyPath: keyPath] ?? fallback
        })
    }

    // ── Functional ──
    /// Light label / selected background
    static let accentLight = Color.accentColor.opacity(0.08)
    /// Card shadow
    static let shadow = Color.black.opacity(0.05)
    /// Drop shadow under a hero book cover. Deeper than `shadow` because the
    /// cover has to lift off a blurred wash of itself rather than a flat card.
    /// Decorative only — it carries no state, so it may go unnoticed against a
    /// dark backdrop without costing the user anything.
    static let coverHeroShadow = Color.black.opacity(0.3)
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
    /// Smallest comfortable hit target for any control (HIG default). Reach for
    /// it when a control's own content is shorter than a finger — a bare menu
    /// label, an icon button — rather than relying on the row's padding.
    static let minimumTapTarget: CGFloat = 44
    /// Search-result cover width shared by native list renderers.
    static let searchResultCoverWidth: CGFloat = 72
    /// Search-result cover height shared by native list renderers.
    static let searchResultCoverHeight: CGFloat = 96
    /// Diameter of the audiobook badge over a search-result cover.
    static let searchResultAudiobookBadgeSize: CGFloat = 20
    /// Width of the cover hero at the top of 書籍資訊. 2:3 like the shelf grid,
    /// so the same artwork is not re-cropped between the two screens.
    static let bookCoverHeroWidth: CGFloat = 176
    /// Height of the cover hero at the top of 書籍資訊.
    static let bookCoverHeroHeight: CGFloat = 264
    /// Blur radius of the cover repeated behind the hero as a colour wash.
    static let bookCoverHeroBackdropBlur: CGFloat = 44
    /// Opacity of the blurred hero backdrop over the page background.
    static let bookCoverHeroBackdropOpacity: Double = 0.55
    /// Saturation lift that keeps the blurred backdrop from going muddy grey.
    static let bookCoverHeroBackdropSaturation: Double = 1.5
    /// Drop-shadow radius under the hero cover.
    static let bookCoverHeroShadowRadius: CGFloat = 18
    /// Drop-shadow vertical offset under the hero cover.
    static let bookCoverHeroShadowOffsetY: CGFloat = 10
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
    /// Maximum width of the Apple Books-style floating reader controls.
    static let readerAppleBooksPanelWidth: CGFloat = 252
    /// Minimum hit target and visible size of Apple Books reader chrome controls.
    static let readerAppleBooksControlSize: CGFloat = 44
    /// Width of each action; four actions plus three gaps exactly fill the panel.
    static let readerAppleBooksActionWidth: CGFloat = 57
    /// Height of each compact action below the Apple Books reader menu.
    static let readerAppleBooksActionHeight: CGFloat = 44
    /// Height of each Apple Books reader-menu capsule row.
    static let readerAppleBooksMenuRowHeight: CGFloat = 44
    /// VoiceOver increment/decrement step for the Apple Books progress scrubber.
    static let readerAppleBooksProgressAccessibilityStep: Double = 0.01
    /// Minimum height of the paragraph-comment SVG editor.
    static let readerSVGEditorHeight: CGFloat = 160
    /// Compact fixed width for a paragraph-comment bubble preview tile.
    static let readerBubblePreviewTileWidth: CGFloat = 64
    /// Minimum height of a paragraph-comment bubble preview tile.
    static let readerBubblePreviewHeight: CGFloat = 64
    /// Width of a battery SVG preview in the template-management list.
    static let readerBatterySVGPreviewWidth: CGFloat = 72
    /// Height of a battery SVG preview in the template-management list.
    static let readerBatterySVGPreviewHeight: CGFloat = 32
    /// Minimum editor hit target for a freely positioned reader overlay component.
    static let readerOverlayEditorMinimumHitSize: CGFloat = 44
    /// Selection outline width for the reader overlay editor.
    static let readerOverlaySelectionLineWidth: CGFloat = 2
    /// Minimum width of a total-progress overlay component.
    static let readerOverlayProgressMinimumWidth: CGFloat = 72
    /// Maximum width of a total-progress overlay component on compact reader canvases.
    static let readerOverlayProgressMaximumWidth: CGFloat = 240
    /// Progress width relative to the component font line height.
    static let readerOverlayProgressWidthScale: CGFloat = 5
    /// System and imported battery width relative to the component font line height.
    static let readerOverlayBatteryAspectRatio: CGFloat = 2.25
    /// Width of the anchored edit/delete menu beside a selected reader overlay component.
    static let readerOverlayActionMenuWidth: CGFloat = 156
    /// Height of anchored editor menus and compact floating controls.
    static let readerOverlayActionMenuHeight: CGFloat = 48
    /// Gap between a selected component and its anchored action menu.
    static let readerOverlayActionMenuGap: CGFloat = 8
    /// Maximum width of the bottom add-component action.
    static let readerOverlayEditorBottomActionMaxWidth: CGFloat = 320
    /// Width of the centered reader-overlay editor control stack.
    static let readerOverlayEditorControlStackWidth: CGFloat = 240
    /// Width reserved for leading/trailing actions in the editor toolbar.
    static let readerOverlayEditorToolbarActionWidth: CGFloat = 72
    /// Alignment guide stroke width.
    static let readerOverlayGuideLineWidth: CGFloat = 1
    /// Alignment guide dash length.
    static let readerOverlayGuideDashLength: CGFloat = 5
    /// Precise distance at which a dragged overlay component acquires an alignment guide.
    static let readerOverlaySnapAcquireDistance: CGFloat = 3
    /// Distance at which a dragged overlay component releases its current guide.
    static let readerOverlaySnapReleaseDistance: CGFloat = 6
    /// Wide management surfaces such as book-source lists.
    static let readableWideWidth: CGFloat = 980
    /// Extra horizontal inset applied to regular-width reader pages.
    static let readerRegularExtraHorizontalInset: CGFloat = 28
    /// Gutter between two pages in iPad landscape spread mode.
    static let readerSpreadGutter: CGFloat = 28
    /// Width of the centered source card when no live bookshelf cover frame is available.
    static let readerCardFallbackWidth: CGFloat = 96
    /// Physical book-cover height/width ratio used by the transition fallback.
    static let readerCardFallbackAspectRatio: CGFloat = 1.45
    /// Outer glow radius of a floating surface at 光暈強度 100%.
    static let interfaceGlowOuterRadius: CGFloat = 32
    /// Inner (tighter, denser) glow radius at 光暈強度 100%.
    static let interfaceGlowInnerRadius: CGFloat = 12
    /// Outer glow opacity at 光暈強度 100%.
    static let interfaceGlowOuterOpacity: Double = 0.5
    /// Inner glow opacity at 光暈強度 100%.
    static let interfaceGlowInnerOpacity: Double = 0.3
    /// Height of the 界面效果 live preview card.
    static let interfaceEffectPreviewHeight: CGFloat = 220
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
    /// Deliberate physical open/close duration for the reader book-card transition.
    static let readerBookTransitionDuration: TimeInterval = 0.62
    /// Minimum visible settle time when a short interactive close reverses.
    static let readerBookCancellationSettleDuration: TimeInterval = 0.20
    /// Reduced-motion reader transition duration (opacity only).
    static let readerBookReducedMotionDuration: TimeInterval = 0.18
}

// MARK: - View Extensions

extension View {
    /// Applies `.inlineLarge` toolbar title display mode on iOS 18+,
    /// falling back to `.inline` on iOS 17 where `.inlineLarge` is unavailable.
    /// Per the title-mode rule (docs/design.md §2.1), this is allowed only on
    /// the main root screens; everything else uses `.inline` directly.
    @ViewBuilder
    func toolbarTitleDisplayModeInlineLargeOrInline() -> some View {
        if #available(iOS 18, *) {
            self.toolbarTitleDisplayMode(.inlineLarge)
        } else {
            self.toolbarTitleDisplayMode(.inline)
        }
    }
}
