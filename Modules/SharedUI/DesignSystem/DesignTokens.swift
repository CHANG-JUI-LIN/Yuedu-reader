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
    /// 回饋中心's 需要你補充資訊 badge: a request, set apart from 排隊中's warning orange.
    static let feedbackNeedsInfo = Color(uiColor: .systemTeal)

    // ── Rankings ──
    /// A custom explore page's rank badges for first, second and third place, white
    /// numerals on them; later places sit on `neutralControlFill`. The number is the cue,
    /// the colour only marks the top three.
    static let rankFirst = Color(uiColor: .systemRed)
    static let rankSecond = Color(uiColor: .systemTeal)
    static let rankThird = Color(uiColor: .systemOrange)

    // ── Custom explore layouts ──
    /// Each layout's hue on its tile in 新增元件, one per layout.
    static let layoutFeaturedCards = Color(uiColor: .systemBlue)
    static let layoutRanking = Color(uiColor: .systemTeal)
    static let layoutGrid = Color(uiColor: .systemGreen)
    static let layoutCarousel = Color(uiColor: .systemCyan)
    static let layoutPagedRanking = Color(uiColor: .systemIndigo)
    static let layoutMultiCategoryRanking = Color(uiColor: .systemOrange)
    static let layoutWaterfall = Color(uiColor: .systemPink)

    // ── Text ──
    // Themed the same way the surfaces below are: an appearance theme (or an
    // imported appearance pack) may author all three levels, and anything that
    // does not resolves to the exact system label colors it used before —
    // `Color.primary` is `.label` and `Color.secondary` is `.secondaryLabel`, so
    // a theme without text colors paints identically to the old constants.
    /// Primary text (auto-adapts to light/dark mode)
    static var textPrimary: Color { themedText(\.primary, fallback: .label) }
    /// Text on strong functional fills.
    static let textOnAccent = Color.white
    /// 精簡閱讀卡片's ground until its cover's colour is known: dark enough for white text.
    static let coverTintPlaceholder = CoverTint.placeholder.color
    /// Secondary text (captions, subtitles)
    static var textSecondary: Color { themedText(\.secondary, fallback: .secondaryLabel) }
    /// Third-level text (footnotes, metadata) — the level iOS calls `tertiaryLabel`.
    static var textTertiary: Color { themedText(\.tertiary, fallback: .tertiaryLabel) }
    /// Disabled text — 弱文字, the level iOS gives tertiary content. This was
    /// `Color.secondary` at half opacity: the same 30% of the label colour that
    /// `tertiaryLabel` is, so a theme without text colours draws exactly what it did.
    static var textDisabled: Color { textTertiary }

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
    /// The dim over the store behind the public-library card carousel.
    static let cardCarouselDim = Color.black
    /// A carousel card's primary action, white with black text in every card colour
    /// and appearance, as Apple Books' 取得.
    static let cardPrimaryActionFill = Color.white
    static let cardPrimaryActionLabel = Color.black
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

    /// Resolves one authored text level as a **dynamic** color, falling back to the
    /// system label for any appearance whose theme did not author the trio. Kept
    /// separate from `themed(_:fallback:)` because text colors are optional on the
    /// preset: a theme opts in, where every theme always has surface colors.
    private static func themedText(
        _ keyPath: KeyPath<AppearanceThemeTextColors, UIColor>,
        fallback: UIColor
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits[AppThemesTrait.self].theme(for: traits.userInterfaceStyle)?
                .authoredTextColors?[keyPath: keyPath] ?? fallback.resolvedColor(with: traits)
        })
    }

    /// Resolves a themed surface color as a **dynamic** color.
    ///
    /// Both the theme and the light or dark palette are read from the trait collection in
    /// effect when a view actually draws (`AppThemesTrait`), never captured when the
    /// color is made. Captured, the color depended on when things ran: dark mode could
    /// paint light-mode surfaces if a screen re-rendered before `ContentView.body` did,
    /// and a view SwiftUI did not rebuild kept the old theme after a switch.
    ///
    /// - Parameter fallback: the system color for an appearance with no theme (classic),
    ///   or with 默認 whose 背景 is as shipped (`keepsSystemBackgrounds`).
    private static func themed(
        _ keyPath: KeyPath<AppearanceThemePreset, UIColor>,
        fallback: UIColor
    ) -> Color {
        Color(uiColor: UIColor { traits in
            guard let theme = traits[AppThemesTrait.self].theme(for: traits.userInterfaceStyle),
                  !theme.keepsSystemBackgrounds
            else { return fallback.resolvedColor(with: traits) }
            return theme[keyPath: keyPath]
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
    /// Shadow under a detail page's cover (Editorial Minimalism, 2026-10-12): a light
    /// lift, as Apple Books draws its book page, not the deep drop `coverHeroShadow` gives.
    static let bookDetailCoverShadow = Color.black.opacity(0.16)
    /// Shadow under a cover in the 搜索 page's lists: the short, soft shadow Apple Books'
    /// search draws under each cover, measured off its screenshots. Decorative, like
    /// `coverHeroShadow`.
    static let searchListCoverShadow = Color.black.opacity(0.35)
    /// Selected highlight
    static let highlight = Color.accentColor.opacity(0.15)

    /// Shadow under an app icon shown in the app.
    static let appIconShadow = Color.black.opacity(0.12)

    /// A site with no icon on the browser's start page: its first letter, white on grey,
    /// as Safari draws one. The tile is decorative — the site's name sits under it.
    static let browserMonogramFill = Color(uiColor: .systemGray2)
    static let browserMonogramForeground = Color.white
    /// A 首頁配置 without a photo: the first letter of its name, white on grey, the same tile.
    static let homeConfigurationMonogramFill = Color(uiColor: .systemGray2)
    static let homeConfigurationMonogramForeground = Color.white

    /// Ring and check of the selection mark on a shelf cover — white, as Apple Books
    /// draws it, whatever the cover and appearance.
    static let coverSelectionMarkForeground = Color.white
    /// Disc inside a selected cover's mark, behind the white check.
    static let coverSelectionMarkFill = Color.black
    /// Soft halo behind the mark, so the white ring still reads on a white cover.
    static let coverSelectionMarkShadow = Color.black.opacity(0.35)

    /// Confetti for the moment Pro unlocks: the accent leads, system colors around it,
    /// so it follows the app theme and reads in light and dark.
    static let celebration: [Color] = [
        Color.accentColor, Color.pink, Color.orange, Color.yellow, Color.green, Color.teal, Color.purple,
    ]

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

@MainActor
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
    /// A section title the way Apple Books heads its sections: Title 2 in bold, set in
    /// the system serif (New York). A chosen interface font draws it like any other style.
    static var serifSectionTitle: Font {
        GlobalAppTypography.font(.title2, weight: .bold, systemDesign: .serif)
    }

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
    /// Compact ambient reader information.
    static let readerBarComponentGap: CGFloat = 2
    /// 2pt — between the stacked text lines of a dense row (a ranking's title, author
    /// and intro beside a cover)
    static let xxs: CGFloat = 2
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
    /// 回饋中心: a picked attachment's square in the form and the composer.
    static let feedbackThumbnailSide: CGFloat = 72
    /// 回饋中心: an attachment's square inside a message bubble.
    static let feedbackBubbleAttachmentSide: CGFloat = 88
    /// 回饋中心: the unread dot before a report's title in 我的回饋.
    static let feedbackUnreadDot: CGFloat = 8
    /// 回饋中心: the status badge's fill, the status colour at this opacity.
    static let feedbackBadgeFillOpacity: Double = 0.15
    /// 回饋中心: the dark disc behind an attachment's remove button, legible on any picture.
    static let feedbackRemoveButtonBackdropOpacity: Double = 0.6
    /// 回饋中心: the info disc at the front of the 問題回報 capsule (截圖後顯示意見回饋入口).
    static let feedbackScreenshotPromptIconSide: CGFloat = 40
    /// Visible width of the tab a tucked-away mini-player leaves on the screen edge. The
    /// tab stays thin so it does not cover text; its hit region is `minimumTapTarget`.
    static let miniPlayerEdgeHandleWidth: CGFloat = 20
    /// Visible height of that edge tab — the mini-player's cover height, so the tab reads
    /// as the same object tucked away.
    static let miniPlayerEdgeHandleHeight: CGFloat = 56
    /// The most a dragged mini-player gives past the edge of where it may rest.
    static let miniPlayerDragMaximumGive: CGFloat = 48
    /// How far the reading assistant keeps the reader's own turn from the leading edge.
    /// The answer uses the full width as plain prose; the question stays a narrower
    /// bubble on the trailing side, so the two never read as the same kind of text.
    static let aiChatBubbleLeadingInset: CGFloat = 48
    /// 人物關係圖: the ring's height, how far related characters sit inside its edge, the
    /// spoke width, and the widest the relation line under a name may get.
    static let relationshipMapHeight: CGFloat = 340
    static let relationshipNodeInset: CGFloat = 52
    static let relationshipLineWidth: CGFloat = 1
    static let relationshipLabelWidth: CGFloat = 96
    /// Source-login controls: visible outlines and tactile feedback over themed artwork.
    static let loginControlBorder: CGFloat = 0.5
    static let loginControlContrastBorder: CGFloat = 2
    static let loginControlPressedScale: CGFloat = 0.96
    static let loginControlDisabledOpacity: Double = 0.5
    /// Search-result cover width shared by native list renderers.
    static let searchResultCoverWidth: CGFloat = 72
    /// Search-result cover height shared by native list renderers.
    static let searchResultCoverHeight: CGFloat = 96
    /// The 搜索 page's lists — results, 最近搜索, 最近閱讀 — as Apple Books lays out its
    /// search, measured off its iOS 26 screenshots on a 402pt-wide iPhone (2026-10-02):
    /// the inset from both edges, the 2:3 cover, and the gap from cover to text, which is
    /// also where a row's separator starts.
    static let searchListHorizontalInset: CGFloat = 29
    static let searchListCoverWidth: CGFloat = 48
    static let searchListCoverHeight: CGFloat = 72
    static let searchListCoverTextSpacing: CGFloat = 14
    /// The shadow under a search-list cover: short and soft, falling below it.
    static let searchListCoverShadowRadius: CGFloat = 5
    static let searchListCoverShadowY: CGFloat = 4
    /// The grey tag after a title (有聲書), drawn as Apple Books draws its language tag:
    /// the padding beside its text, and above and below the text's cap height.
    static let titleTagHorizontalPadding: CGFloat = 3
    static let titleTagVerticalPadding: CGFloat = 2.5
    /// The 搜索 page's progress ring, drawn as the App Store draws a download: its
    /// diameter, the width of its track and arc, and the pause or play glyph inside.
    /// Fixed like the bar it sits in; its tap area is `minimumTapTarget`.
    static let searchProgressRingSize: CGFloat = 28
    static let searchProgressRingLineWidth: CGFloat = 2.5
    static let searchProgressRingGlyphSize: CGFloat = 10
    /// Width of the cover hero at the top of 書籍資訊. 2:3 like the shelf grid,
    /// so the same artwork is not re-cropped between the two screens.
    static let bookCoverHeroWidth: CGFloat = 176
    /// Height of the cover hero at the top of 書籍資訊.
    static let bookCoverHeroHeight: CGFloat = 264
    /// Cover in a 探索 shelf (a featured category's horizontal row), 2:3 like Apple
    /// Books' store shelves.
    static let discoverShelfCoverWidth: CGFloat = 112
    static let discoverShelfCoverHeight: CGFloat = 168
    /// Cover in a 探索 chart row or 查看全部 list row.
    static let discoverRowCoverWidth: CGFloat = 52
    static let discoverRowCoverHeight: CGFloat = 78
    /// How far the next chart column peeks in from the trailing edge, so the row
    /// reads as something to swipe — Apple Books' Top Charts.
    static let discoverChartPeek: CGFloat = 32
    /// A 探索 cover that takes the width it is offered (a grid cell, a waterfall card)
    /// keeps the 2:3 of the fixed-size ones.
    static let discoverCoverAspectRatio: CGFloat = 2.0 / 3.0
    /// Apple Books reference: 32pt outer margins, two 167pt jackets on a 414pt
    /// phone, with the next jacket peeking past the trailing margin.
    static let publicLibraryMargin: CGFloat = 32
    static let publicLibraryMinimumCoverWidth: CGFloat = 148
    static let publicLibraryFeaturedAspect: CGFloat = 1.46
    static let publicLibraryFeaturedRotation: Double = -16
    /// A cover in a row of Explore's home (unified library 5c), 2:3. Between Apple Books'
    /// two jackets to a phone (`publicLibraryMinimumCoverWidth`) and Emby's three: about two
    /// and a half on a 402pt phone, the next one peeking past the edge. Scaled with Dynamic Type.
    static let homeCardCoverWidth: CGFloat = 140
    /// The widest a home cover grows at accessibility text sizes, so one still fits a phone.
    static let homeCardCoverMaxWidth: CGFloat = 240
    /// The reading-progress bar along the bottom of a 繼續閱讀 cover, as Emby marks a
    /// resumable item.
    static let homeCardProgressHeight: CGFloat = 3
    /// The home's other layouts (unified library 5d-3), all 2:3 and scaled with Dynamic Type.
    /// 大型閱讀卡片's cover, beside its text.
    static let homeReadingCardCoverWidth: CGFloat = 110
    /// How much of the next 大型閱讀卡片 shows past the edge, so the row reads as one to swipe.
    static let homeReadingCardPeek: CGFloat = 40
    /// A cover in 多行橫向輪播, and the narrowest a 固定封面網格 column gets: three to a
    /// 402pt phone.
    static let homeCompactCoverWidth: CGFloat = 100
    /// A cover in 圖文資訊清單, beside its text.
    static let homeListCoverWidth: CGFloat = 60
    /// A 首頁配置's round photo in 首頁配置's list, as Rex's 管理配置 draws it.
    static let homeConfigurationRowPhotoSize: CGFloat = 44
    /// The same photo atop the page that changes it.
    static let homeConfigurationFormPhotoSize: CGFloat = 96
    /// A layout's preview in 呈現方式 (decision 34): the layout at its real size, as a template
    /// gallery shows it; a layout read downwards shows this many rows.
    static let homeLayoutPreviewRows = 2
    /// 精選's cover (decision 37), beside its text on the cover's colour: the largest on the
    /// home, one book to a page.
    static let homeFeaturedCoverWidth: CGFloat = 132
    /// 精簡閱讀卡片 (5d-3c), measured off Apple Books' Continue card on a 440pt phone: a 278×80
    /// card, its 40×60 cover inset 10 on every side and 10 from the text. Scaled with Dynamic Type.
    static let homeCompactReadingCardCoverWidth: CGFloat = 40
    static let homeContinueCardWidth: CGFloat = 278
    static let homeContinueCardInset: CGFloat = 10
    /// Its kind line's colour: the cover's hue at most this saturated, at this brightness.
    static let homeContinueTintSaturation: CGFloat = 0.55
    static let homeContinueTintBrightness: CGFloat = 0.78
    /// …and at least this light (WCAG luminance), so a ground exists under it at 7:1.
    static let homeContinueTintMinimumLuminance = 0.4
    /// 訂閱的最新文章's card (5g) in the sideways layouts: wider than a cover, since an article's
    /// picture is landscape. Scaled with Dynamic Type.
    static let homeArticleCardWidth: CGFloat = 240
    /// The widest an article card grows at accessibility text sizes, so one still fits a phone.
    static let homeArticleCardMaxWidth: CGFloat = 340
    /// An article card's picture, 16:9, as feeds' lead images mostly are.
    static let homeArticleImageAspectRatio: CGFloat = 16.0 / 9.0
    /// The dot an unread article carries, as the RSS tab's rows mark one.
    static let homeArticleUnreadDot: CGFloat = 8
    /// 圖文資訊清單's rank badge at the default text size (scaled with Dynamic Type); two-digit
    /// ranks widen it.
    static let homeRankBadgeSize: CGFloat = 24
    /// Site icon in a bookmark or history row.
    static let browserRowIconSide: CGFloat = 28
    /// A site on the browser's start page — Safari's Favorites: the icon, and the
    /// narrowest a tile gets before the grid drops a column (four on a phone).
    static let browserStartTileIconSide: CGFloat = 64
    static let browserStartTileMinWidth: CGFloat = 80
    /// The soft shadow under the start page's site icons, its 編輯 button and the
    /// address field, lifting them off the page as Safari does.
    static let browserLiftShadowRadius: CGFloat = 4
    static let browserLiftShadowY: CGFloat = 1
    /// Narrowest a chip may get in 發現頁設定's grid: four to a row on an iPhone, fewer as
    /// the text grows (scaled with Dynamic Type).
    static let discoverChipMinWidth: CGFloat = 72
    /// A chip, filter or quick action drawn as a capsule (`DSCapsuleLabel`).
    static let capsuleControlHeight: CGFloat = 36
    /// The narrowest a chip in a filter bar gets — 書架's groups, 探索's categories: the
    /// HIG's 44pt minimum control width, so a one-character name is still a capsule wider
    /// than it is tall.
    static let capsuleControlMinWidth: CGFloat = 44
    /// A tab root's title starts to fade once its page has scrolled this far, and is gone
    /// this much further on (書架, as Apple Music's and Books' home titles go).
    static let rootTabTitleFadeStart: CGFloat = 10
    static let rootTabTitleFadeDistance: CGFloat = 30
    /// The square on a 資源庫 card, and its symbol or glyph, at the default text size. They
    /// follow Dynamic Type.
    static let exploreCardArtworkSide: CGFloat = 36
    static let exploreCardArtworkSize: CGFloat = 18
    /// The soft shadow lifting a 資源庫 card off the page.
    static let exploreCardShadowRadius: CGFloat = 8
    static let exploreCardShadowY: CGFloat = 2
    /// Side of the square artwork at the top of an audiobook detail page — Podcasts'
    /// show artwork, a little narrower than a book jacket is tall.
    static let bookDetailSquareArtworkSide: CGFloat = 168
    /// How far a detail page's cover wash runs above the hero, under the status and
    /// navigation bars — taller than both together at the largest text size, so even a
    /// pull-down overscroll does not uncover the page background behind the bars.
    /// Public-library card carousel (Apple Books store card). How far the card
    /// scrolls before its header pins; the tint over the header's glass; secondary
    /// text on the card's coloured top; the dim over the store, measured off Apple
    /// Books (white #FFFFFF under it reads #434343); and how far a resting card has
    /// to be pulled down, or how fast, to close when let go.
    static let cardHeaderPinDistance: CGFloat = 20
    /// Card geometry measured off Apple Books (414pt-wide phone, 2x): the resting
    /// card's top below the status bar; the cover's top below the card's top (under
    /// the 16pt + 44pt header), its height, and the gap to the title under it; and
    /// the coloured top's run below the actions.
    static let cardCarouselTopGap: CGFloat = 13
    static let cardCarouselCoverTop: CGFloat = 83
    static let cardCarouselCoverHeight: CGFloat = 314
    static let cardCarouselCoverTitleSpacing: CGFloat = 34
    static let cardCarouselTopBottomPadding: CGFloat = 44
    static let cardHeaderGlassTintOpacity: Double = 0.35
    static let cardSecondaryTextOpacity: Double = 0.72
    static let cardCarouselDimOpacity: Double = 0.74
    static let cardCarouselDismissPull: CGFloat = 80
    static let cardCarouselDismissVelocity: CGFloat = 600
    /// A card's actions, measured off Apple Books' 試讀 / 取得 (45.5pt tall).
    static let cardActionHeight: CGFloat = 46
    static let cardActionPressedOpacity: Double = 0.7
    static let cardSecondaryActionFillOpacity: Double = 0.14
    static let bookDetailBackdropTopExtension: CGFloat = 320
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
    /// A detail page's hero (Editorial Minimalism, 2026-10-12): a small jacket, so the title
    /// and the reading action carry the page; 2:3 like the shelf grid.
    static let bookDetailCoverWidth: CGFloat = 128
    static let bookDetailCoverHeight: CGFloat = 192
    static let bookDetailCoverShadowRadius: CGFloat = 12
    static let bookDetailCoverShadowOffsetY: CGFloat = 6
    /// The cover's hue washed behind a detail page's hero (`CoverTint.Wash`): faint, and
    /// fading from a third of the hero's height so it melts into the page instead of ending
    /// as a band. A cover less saturated than the minimum gets no wash; the maximum keeps a
    /// loud cover's wash calm.
    static let bookDetailBackdropFadeStart: Double = 0.3
    static let bookDetailWashMinimumSaturation: Double = 0.18
    static let bookDetailWashMaximumSaturation: Double = 0.45
    static let bookDetailWashLightBrightness: Double = 0.92
    static let bookDetailWashLightOpacity: Double = 0.5
    static let bookDetailWashDarkBrightness: Double = 0.45
    static let bookDetailWashDarkOpacity: Double = 0.35
    /// Gap between a shelf-grid cover and the title under it.
    static let bookshelfGridCoverTitleSpacing: CGFloat = 6
    /// A group's folder on the shelf, as shares of its width: the margin around its four
    /// covers, and the gap between them. Shares, so the list's thumbnail and a grid cell's
    /// folder keep one look at their different sizes.
    static let bookshelfFolderInsetRatio: CGFloat = 0.08
    static let bookshelfFolderSpacingRatio: CGFloat = 0.05
    /// A cover inside a folder rounds its corners by this share of the shelf's cover radius.
    static let bookshelfFolderCoverRadiusRatio: CGFloat = 0.5
    /// A shelf cover the selection leaves out while 選取 is on, dimmed as Apple Books'
    /// library dims one: measured off its screenshots at 60% over the page.
    static let bookshelfUnselectedCoverOpacity: Double = 0.6
    /// A button floating over the page while the page scrolls under it (the webtoon
    /// reader's auto-scroll button), dimmed as Aidoku dims its own.
    static let readerFloatingControlScrollingOpacity: Double = 0.5
    /// The most a selected shelf cover grows: Apple Books' own lift, about 11%.
    static let bookshelfSelectedCoverMaximumScale: CGFloat = 1.11
    /// Height a selected grid cover may gain. `BookshelfGridSelectionStyle.liftAnchor`
    /// splits it 8pt up, into the row gap or the grid's top inset, and 4pt down, short of
    /// the title `bookshelfGridCoverTitleSpacing` below.
    static let bookshelfSelectedCoverHeightGrowth: CGFloat = 12
    /// Diameter of the selection mark in a grid cover's corner.
    static let bookshelfSelectionMarkSize: CGFloat = 20
    /// Width of the mark's white ring.
    static let bookshelfSelectionMarkLineWidth: CGFloat = 1.5
    /// Point size of the check inside a selected cover's mark.
    static let bookshelfSelectionCheckmarkSize: CGFloat = 9
    /// Blur of the halo behind the mark (`DSColor.coverSelectionMarkShadow`).
    static let bookshelfSelectionMarkShadowRadius: CGFloat = 1.5
    /// Width of 加入分組's icon and title in the shelf's 選取 bottom bar
    /// (`ToolbarTitleAndIconLabel`): 「加入分組」 fits, a longer title ends in "…".
    static let bookshelfAddToGroupLabelWidth: CGFloat = 104
    /// Width of 繼續問 AI's icon and title in AI 查詞's bottom bar
    /// (`ToolbarTitleAndIconLabel`): the Chinese, Korean and English titles fit, the
    /// longer Japanese one ends in "…". 132 still cut "Ask AI More" on iOS 27.
    static let aiWordLookupAskLabelWidth: CGFloat = 140
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
    /// Width of one background tile in the quick panel's scrolling row. Sized so a
    /// compact phone shows four and a half of them — enough that the fifth is
    /// visibly cut off, which is what tells the reader the row scrolls.
    static let readerQuickPanelBackgroundTileWidth: CGFloat = 74
    /// Starting detent for the reader quick settings sheet, replaced by the
    /// measured content height on the first layout pass.
    static let readerQuickPanelSheetHeight: CGFloat = 420
    /// Maximum width of the Apple Books-style floating reader controls.
    static let readerAppleBooksPanelWidth: CGFloat = 252
    /// Minimum hit target and visible size of Apple Books reader chrome controls.
    static let readerAppleBooksControlSize: CGFloat = 44
    /// Width of each action; four actions plus three gaps exactly fill the panel.
    static let readerAppleBooksActionWidth: CGFloat = 57
    /// Actions the row shows at once; past this it scrolls.
    static let readerAppleBooksVisibleActions = 4
    /// The paywall's picture of a pillar (`PaywallShowcase`).
    static let paywallShowcaseHeight: CGFloat = 150
    /// One reading page in the showcase's fan of themes.
    static let paywallShowcasePageWidth: CGFloat = 96
    /// The tap-zone grid in the showcase.
    static let paywallShowcaseGridWidth: CGFloat = 136
    /// How far the outer pages of the fan lean.
    static let paywallShowcaseTiltDegrees: Double = 6
    /// Symbol column of a paywall benefit row, so the titles line up.
    static let paywallBenefitIconWidth: CGFloat = 24
    /// The app icon heading the Pro member page; the unlock celebration's rings start
    /// from its outline.
    static let paywallAppIconSize: CGFloat = 96
    /// An icon leading a settings row, as `IconConsistentLabelStyle` sizes its symbols.
    static let settingsRowIconSize: CGFloat = 28
    /// Corner radius over side length of the home-screen icon mask; with `.continuous`
    /// corners a rounded rectangle matches the icon's own shape.
    static let appIconCornerRatio: CGFloat = 0.2237
    /// Lift under an app icon shown in the app, as on the About page.
    static let appIconShadowRadius: CGFloat = 10
    static let appIconShadowY: CGFloat = 4
    /// How many pieces one unlock celebration throws.
    static let celebrationConfettiCount = 72
    /// Height of each compact action below the Apple Books reader menu.
    static let readerAppleBooksActionHeight: CGFloat = 44
    /// Height of each Apple Books reader-menu capsule row.
    static let readerAppleBooksMenuRowHeight: CGFloat = 44
    /// VoiceOver increment/decrement step for the Apple Books progress scrubber.
    static let readerAppleBooksProgressAccessibilityStep: Double = 0.01
    /// Diameter of 現代's cover button in the reader toolbar. The cover fills it
    /// as a circle, so this is the control size, not an inset thumbnail size.
    static let readerModernCoverButtonSize: CGFloat = 34
    /// Width of 現代's book-card popover, from the width of the reader under it.
    /// Popovers size to their content, so the card needs an explicit width or a long
    /// book name stretches it; a *fixed* one was the other failure — 320pt on a 440pt
    /// phone left a narrow slip hanging off the cover thumbnail. Insetting from the
    /// reader's own width keeps the proportion on every device, and the cap stops an
    /// iPad popover from growing into a band across the screen.
    static func readerModernBookCardWidth(viewportWidth: CGFloat) -> CGFloat {
        min(max(viewportWidth - DSSpacing.lg * 2, 280), readableNarrowWidth)
    }
    /// The cover inside that card, at the 3:4 the generated covers are drawn to.
    static let readerModernBookCardCoverWidth: CGFloat = 72
    static let readerModernBookCardCoverHeight: CGFloat = 96
    /// One action cell in that card. Past the 44pt minimum because the cell carries a
    /// symbol and a label that may wrap to two lines.
    static let readerModernBookCardActionHeight: CGFloat = 66
    /// The symbol inside one of those cells.
    static let readerModernBookCardActionGlyphSize: CGFloat = 26
    /// Action cells per row before the card's grid wraps to a second row.
    static let readerModernBookCardActionColumns = 4
    /// Width of the quote bar beside the annotated excerpt in the note editor.
    static let readerNoteQuoteBarWidth: CGFloat = 3
    /// Minimum height of the paragraph-comment SVG editor.
    static let readerSVGEditorHeight: CGFloat = 160
    /// Compact fixed width for a paragraph-comment bubble preview tile.
    static let readerBubblePreviewTileWidth: CGFloat = 64
    /// Minimum height of a paragraph-comment bubble preview tile.
    static let readerBubblePreviewHeight: CGFloat = 64
    /// Width a 本章說 / 作者說 / 神評論 template preview is drawn at in 氣泡設定: a phone
    /// reading column, so its text keeps the proportion it has in the book.
    static let readerCommentCardPreviewWidth: CGFloat = 340
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
    /// A public-library carousel card's top corners, fitted to Apple Books' store card.
    static let carouselCard: CGFloat = 35
    /// Extra-extra-large radius (large preview tiles, prominent panel buttons)
    static let xxl: CGFloat = 20
    /// A cover in the 搜索 page's lists: nearly square, as Apple Books' search draws them.
    static let searchListCover: CGFloat = 2
    /// The grey tag after a title (有聲書).
    static let titleTag: CGFloat = 3
}

// MARK: - Design System: Animation Tokens

enum DSAnimation {
    /// A strong ease-out: most of the distance is covered at the start, so the
    /// response to a tap is visible at once, and the rest is a long settle. The
    /// built-in `.easeOut` starts at under half this speed and reads as slower at
    /// the same duration.
    private static func easeOut(duration: TimeInterval) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// Fast interactive feedback
    static let fast = easeOut(duration: 0.15)
    /// Standard transition
    static let standard = easeOut(duration: 0.28)
    /// Public-library carousel, timed off Apple Books' store card at 240 fps: it
    /// opens out of the cover with a spring that peaks at 0.23 s and overshoots ~2%,
    /// drops back to the cover's height in 0.32 s, then shrinks into it and fades.
    static let cardCarouselOpen = Animation.spring(response: 0.3, dampingFraction: 0.78)
    static let cardCarouselFadeIn = easeOut(duration: 0.1)
    static let cardCarouselDrop = easeOut(duration: 0.32)
    static let cardCarouselCollapse = easeOut(duration: 0.3)
    /// A pulled-down card let go: straight back into its cover on a gesture spring,
    /// critically damped enough not to bounce off the shelf, then faded into it.
    static let cardCarouselReturn = Spring(response: 0.35, dampingRatio: 0.9)
    static let cardCarouselFadeOut = easeOut(duration: 0.15)
    /// Slow expansion
    static let slow = Animation.easeInOut(duration: 0.4)
    /// 編輯首頁 coming and going: every section on screen morphing into its card and back. A
    /// strong ease-in-out, for things that move on screen rather than enter it; the built-in
    /// one is too weak to read as one deliberate move across the whole page.
    static let homeEditMorph = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.4)
    /// The reading menu coming up or going away, and whatever moves with it. One
    /// timing for every way the menu is shown or hidden.
    static let readerChrome = easeOut(duration: 0.2)
    /// Press feedback for pill buttons: a quick spring with a slight overshoot.
    /// Callers must skip it under Reduce Motion.
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.8)
    /// Something let go of mid-drag coming to rest inside its bounds. Callers must
    /// skip it under Reduce Motion.
    static let dragSettle = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// The launch image fading away once the app is ready behind it.
    static let splashFade = Animation.easeOut(duration: 0.45)
    /// Deliberate physical open/close duration for the reader book-card transition.
    static let readerBookTransitionDuration: TimeInterval = 0.62
    /// Minimum visible settle time when a short interactive close reverses.
    static let readerBookCancellationSettleDuration: TimeInterval = 0.20
    /// Reduced-motion reader transition duration (opacity only).
    static let readerBookReducedMotionDuration: TimeInterval = 0.18
    /// The app icon popping in when Pro unlocks: overshoots a little, then settles.
    /// Callers must skip it under Reduce Motion.
    static let celebrationPop = Animation.spring(response: 0.45, dampingFraction: 0.55)
    /// One ring spreading out from the icon and fading. Callers must skip it under
    /// Reduce Motion.
    static let celebrationRing = Animation.easeOut(duration: 1.1)
    /// Delay before the second ring, so the two read as a pulse rather than one ring.
    static let celebrationRingStagger: TimeInterval = 0.25
    /// Frame spacing of the confetti's own timeline, which stops with the last piece.
    static let celebrationFrameInterval: TimeInterval = 1.0 / 60
}

// MARK: - View Extensions

extension View {
    /// Standardized section footer styling per Apple HIG (13pt Footnote + secondary color).
    /// Used for all section-level explanatory texts to ensure proper typography,
    /// dynamic type scaling, and consistent appearance across all themes.
    func dsSectionFooter(color: Color = DSColor.textSecondary) -> some View {
        self
            .font(DSFont.footnote)
            .foregroundStyle(color)
    }
}
