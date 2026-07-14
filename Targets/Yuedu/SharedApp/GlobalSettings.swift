import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import SwiftUI
import UIKit

// MARK: - Reader Text Conversion

enum TextConversion: String, CaseIterable {
    case original = "原文"
    case toTraditional = "繁體"
    case toSimplified = "简体"
}

// MARK: - Page-Turn Style

enum PageTurnStyle: String, CaseIterable {
    case slide = "滑動"
    case cover = "覆蓋翻頁"
    case curl = "仿真翻書"
    case none = "無動畫"
}

enum ReaderCommentBubblePresetMode: String, CaseIterable, Identifiable {
    case builtin
    case square
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .builtin: return "氣泡"
        case .square: return "方泡"
        case .custom: return "自訂 SVG"
        }
    }

    var localizedTitle: String { localized(titleKey) }
}

enum ReaderCustomBackgroundMode: String, CaseIterable, Identifiable {
    case none
    case color
    case image

    var id: String { rawValue }
}

// MARK: - Reader Theme

enum ReaderTheme: String, CaseIterable {
    case night = "夜間"
    case white = "白天"
    case green = "護眼綠"
    case sepia = "護眼"

    private static let userDefaultsKey = "yd_reader_theme"
    private static let lastLightThemeKey = "lastLightTheme"
    private static let weChatAccent = UIColor(red: 56 / 255, green: 151 / 255, blue: 241 / 255, alpha: 1)
    private static let weChatDayBackground = UIColor(red: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    private static let weChatNightBackground = UIColor.black
    private static let weChatNightBarBackground = UIColor(red: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
    private static let eyeComfortGreenBackground = UIColor(
        red: 207 / 255,
        green: 232 / 255,
        blue: 204 / 255,
        alpha: 1
    )

    var titleKey: String {
        switch self {
        case .night: return "黑色"
        case .white: return "白色"
        case .green: return "護眼綠"
        case .sepia: return "棕色"
        }
    }

    var localizedTitle: String { localized(titleKey) }

    static func loadPersisted() -> ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .white
    }

    /// The most recently used non-night theme. Used by "follow system" mode to
    /// pick a light-appearance theme when the system switches to light.
    static var lastLightTheme: ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: lastLightThemeKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .white
    }

    /// The theme to apply when "follow system" mode is on, for the given scheme.
    static func forSystem(dark: Bool) -> ReaderTheme {
        dark ? .night : lastLightTheme
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
        if self != .night {
            UserDefaults.standard.set(rawValue, forKey: Self.lastLightThemeKey)
        }
    }

    var backgroundColor: Color {
        Color(uiColor: uiBackgroundColor)
    }

    var previewBackgroundColor: Color {
        Color(uiColor: intrinsicUIBackgroundColor)
    }

    var textColor: Color {
        Color(uiColor: uiTextColor)
    }

    var previewTextColor: Color {
        Color(uiColor: intrinsicUITextColor)
    }

    var accentColor: Color {
        Color(uiColor: uiAccentColor)
    }

    var uiBackgroundColor: UIColor {
        if let preset = AppearanceThemePreset.activeReaderTheme { return preset.background }
        return intrinsicUIBackgroundColor
    }

    private var intrinsicUIBackgroundColor: UIColor {
        switch self {
        case .white: return Self.weChatDayBackground
        case .green: return Self.eyeComfortGreenBackground
        case .sepia: return UIColor(red: 244 / 255, green: 236 / 255, blue: 216 / 255, alpha: 1)
        case .night: return Self.weChatNightBackground
        }
    }

    var uiTextColor: UIColor {
        if let preset = AppearanceThemePreset.activeReaderTheme { return preset.text }
        return intrinsicUITextColor
    }

    private var intrinsicUITextColor: UIColor {
        switch self {
        case .white: return UIColor(red: 51 / 255, green: 51 / 255, blue: 51 / 255, alpha: 1)
        case .green: return UIColor(red: 47 / 255, green: 61 / 255, blue: 47 / 255, alpha: 1)
        case .sepia: return UIColor(red: 91 / 255, green: 70 / 255, blue: 54 / 255, alpha: 1)
        case .night: return UIColor(red: 217 / 255, green: 217 / 255, blue: 217 / 255, alpha: 1)
        }
    }

    var uiAccentColor: UIColor {
        if let preset = AppearanceThemePreset.activeReaderTheme { return preset.accent }
        return Self.weChatAccent
    }

    /// Text tint for the "對話文字高亮" reading decoration. Returns the theme accent
    /// nudged slightly toward the body text color, so long dialogue passages stay soft
    /// yet clearly distinct. Readable on every theme (the accent always has contrast
    /// against its own background). Returns `nil` when the decoration is disabled.
    func dialogueHighlightColor(enabled: Bool) -> UIColor? {
        guard enabled else { return nil }
        return AppearanceThemePreset.mix(uiAccentColor, uiTextColor, 0.15)
    }

    var barColor: Color {
        Color(uiColor: uiBarColor)
    }

    var uiBarColor: UIColor {
        if let preset = AppearanceThemePreset.activeReaderTheme { return preset.bar }
        switch self {
        case .white: return .white
        case .green:
            return UIColor(red: 191 / 255, green: 218 / 255, blue: 188 / 255, alpha: 1)
        case .sepia: return UIColor(red: 0.93, green: 0.91, blue: 0.83, alpha: 1)
        case .night: return Self.weChatNightBarBackground
        }
    }

    var epubJSName: String {
        switch self {
        case .white: return "white"
        case .green: return "green"
        case .sepia: return "sepia"
        case .night: return "night"
        }
    }
}

enum ReaderConfigRefreshKind {
    case layout
    case appearance
}

@MainActor
final class ReaderConfig: ObservableObject {
    static let shared = ReaderConfig()

    @Published var fontSize: CGFloat
    @Published var lineHeightMultiple: CGFloat
    @Published var letterSpacing: CGFloat
    @Published var paragraphSpacingMultiplier: CGFloat
    @Published var pageMarginH: CGFloat
    @Published var pageMarginV: CGFloat
    @Published var footerBottomPadding: CGFloat
    @Published var footerTextGap: CGFloat
    @Published var readerTitleVisible: Bool
    @Published var readerTitleSize: CGFloat
    @Published var readerTitleTopSpacing: CGFloat
    @Published var readerTitleBottomSpacing: CGFloat
    @Published var readerFontBold: Bool
    @Published var readerHeaderVisible: Bool
    @Published var readerHeaderTopPadding: CGFloat
    @Published var readerHeaderTextGap: CGFloat
    @Published var readerHeaderHorizontalPadding: CGFloat
    @Published var readerFooterVisible: Bool
    @Published var readerFooterHorizontalPadding: CGFloat
    @Published var theme: ReaderTheme

    var lineSpacing: CGFloat {
        max(0, (lineHeightMultiple - 1.0) * fontSize)
    }

    var paragraphSpacing: CGFloat {
        max(0, fontSize * paragraphSpacingMultiplier)
    }

    let refresh = PassthroughSubject<ReaderConfigRefreshKind, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var suppressRefresh = false

    private init() {
        let gs = GlobalSettings.shared
        fontSize = CGFloat(gs.readerFontSize)
        lineHeightMultiple = CGFloat(gs.lineHeightMultiple)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacingMultiplier = CGFloat(gs.paragraphSpacingMultiplier)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        footerBottomPadding = CGFloat(gs.footerBottomPadding)
        footerTextGap = CGFloat(gs.footerTextGap)
        readerTitleVisible = gs.readerTitleVisible
        readerTitleSize = CGFloat(gs.readerTitleSize)
        readerTitleTopSpacing = CGFloat(gs.readerTitleTopSpacing)
        readerTitleBottomSpacing = CGFloat(gs.readerTitleBottomSpacing)
        readerFontBold = gs.readerFontBold
        readerHeaderVisible = gs.readerHeaderVisible
        readerHeaderTopPadding = CGFloat(gs.readerHeaderTopPadding)
        readerHeaderTextGap = CGFloat(gs.readerHeaderTextGap)
        readerHeaderHorizontalPadding = CGFloat(gs.readerHeaderHorizontalPadding)
        readerFooterVisible = gs.readerFooterVisible
        readerFooterHorizontalPadding = CGFloat(gs.readerFooterHorizontalPadding)
        theme = ReaderTheme.loadPersisted()
        setupBindings()
    }

    func syncFromGlobalSettings() {
        let gs = GlobalSettings.shared
        suppressRefresh = true
        fontSize = CGFloat(gs.readerFontSize)
        lineHeightMultiple = CGFloat(gs.lineHeightMultiple)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacingMultiplier = CGFloat(gs.paragraphSpacingMultiplier)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        footerBottomPadding = CGFloat(gs.footerBottomPadding)
        footerTextGap = CGFloat(gs.footerTextGap)
        readerTitleVisible = gs.readerTitleVisible
        readerTitleSize = CGFloat(gs.readerTitleSize)
        readerTitleTopSpacing = CGFloat(gs.readerTitleTopSpacing)
        readerTitleBottomSpacing = CGFloat(gs.readerTitleBottomSpacing)
        readerFontBold = gs.readerFontBold
        readerHeaderVisible = gs.readerHeaderVisible
        readerHeaderTopPadding = CGFloat(gs.readerHeaderTopPadding)
        readerHeaderTextGap = CGFloat(gs.readerHeaderTextGap)
        readerHeaderHorizontalPadding = CGFloat(gs.readerHeaderHorizontalPadding)
        readerFooterVisible = gs.readerFooterVisible
        readerFooterHorizontalPadding = CGFloat(gs.readerFooterHorizontalPadding)
        theme = ReaderTheme.loadPersisted()
        suppressRefresh = false
    }

    private func setupBindings() {
        let layoutPublisher = Publishers.CombineLatest4($fontSize, $lineHeightMultiple, $letterSpacing, $paragraphSpacingMultiplier)
            .combineLatest($pageMarginH, $pageMarginV)
            .combineLatest($footerBottomPadding, $footerTextGap)
            .combineLatest($readerFontBold)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)

        layoutPublisher
            .dropFirst()
            .sink { [weak self] combinedAll, readerFontBold in
                guard let self else { return }
                let (combinedMargins, footerBottomPadding, footerTextGap) = combinedAll
                let (combined, marginH, marginV) = combinedMargins
                let (fontSize, lineHeightMultiple, letterSpacing, paragraphSpacingMultiplier) = combined
                let gs = GlobalSettings.shared
                gs.readerFontSize = Double(fontSize)
                gs.lineHeightMultiple = Double(lineHeightMultiple)
                gs.letterSpacing = Double(letterSpacing)
                gs.paragraphSpacingMultiplier = Double(paragraphSpacingMultiplier)
                gs.pageMarginH = Double(marginH)
                gs.pageMarginV = Double(marginV)
                gs.footerBottomPadding = Double(footerBottomPadding)
                gs.footerTextGap = Double(footerTextGap)
                gs.readerFontBold = readerFontBold
                guard !self.suppressRefresh else { return }
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)

        $theme
            .dropFirst()
            .sink { [weak self] theme in
                theme.persist()
                guard let self, !self.suppressRefresh else { return }
                self.refresh.send(.appearance)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4($readerTitleVisible, $readerTitleSize, $readerTitleTopSpacing, $readerTitleBottomSpacing)
            .dropFirst()
            .sink { [weak self] visible, size, topSpacing, bottomSpacing in
                let gs = GlobalSettings.shared
                gs.readerTitleVisible = visible
                gs.readerTitleSize = Double(size)
                gs.readerTitleTopSpacing = Double(topSpacing)
                gs.readerTitleBottomSpacing = Double(bottomSpacing)
                guard let self, !self.suppressRefresh else { return }
                // Title size/spacing/visibility change the in-content title, which
                // shifts pagination — needs a relayout, not just a recolor.
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4($readerHeaderVisible, $readerHeaderTopPadding, $readerHeaderTextGap, $readerHeaderHorizontalPadding)
            .dropFirst()
            .sink { [weak self] visible, topPadding, textGap, hPadding in
                let gs = GlobalSettings.shared
                gs.readerHeaderVisible = visible
                gs.readerHeaderTopPadding = Double(topPadding)
                gs.readerHeaderTextGap = Double(textGap)
                gs.readerHeaderHorizontalPadding = Double(hPadding)
                guard let self, !self.suppressRefresh else { return }
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($readerFooterVisible, $readerFooterHorizontalPadding)
            .dropFirst()
            .sink { [weak self] visible, hPadding in
                let gs = GlobalSettings.shared
                gs.readerFooterVisible = visible
                gs.readerFooterHorizontalPadding = Double(hPadding)
                guard let self, !self.suppressRefresh else { return }
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)
    }
}

extension String {
    /// Offline ICU text conversion for book content.
    func converted(to mode: TextConversion) -> String {
        switch mode {
        case .original: return self
        case .toTraditional:
            return self.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false)
                ?? self
        case .toSimplified:
            return self.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false)
                ?? self
        }
    }
}

func localized(_ key: String, bundle: Bundle = .main) -> String {
    NSLocalizedString(key, bundle: bundle, comment: "")
}

// MARK: - Global Settings

class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    static let bookshelfGridColumnCountOptions = [2, 3, 4, 5]
    static let defaultBookshelfGridColumnCount = 3
    private static let bookshelfGridColumnCountKey = "yd_bookshelf_grid_column_count"
    /// "默認" (classic) — the app's original look; also the fallback when a
    /// selected Pro theme becomes unavailable (entitlement lapse / deletion).
    static let defaultAppearanceThemeID = AppearanceThemePreset.classicID
    private static let appearanceThemeIDKey = "yd_appearance_theme_id"
    private static let appearanceDarkThemeIDKey = "yd_appearance_dark_theme_id"
    private static let appearanceSeparateDarkThemeKey = "yd_appearance_separate_dark_theme"
    private static let appearanceBindReaderThemeKey = "yd_appearance_bind_reader_theme"
    private static let appearanceReaderInterfaceKey = "yd_appearance_reader_interface"
    private static let customAppearanceThemesKey = "yd_custom_appearance_themes"
    private static let appearancePageBackgroundsKey = "yd_appearance_page_backgrounds"
    private static let globalFontPostScriptKey = "yd_global_font_postscript"
    private static let commentBubbleFollowsSourceSVGKey = "yd_comment_bubble_follows_source_svg"
    private static let commentBubblePresetModeKey = "yd_comment_bubble_preset_mode"
    private static let commentBubbleCustomSVGKey = "yd_comment_bubble_custom_svg"
    private static let commentBubbleCustomStyleNameKey = "yd_comment_bubble_custom_style_name"
    private static let commentBubbleCustomStylesV2Key = "yd_comment_bubble_custom_styles_v2"
    private static let commentBubbleSelectedCustomStyleIDKey = "yd_comment_bubble_selected_custom_style_id"
    private static let commentBubbleScaleKey = "yd_comment_bubble_scale"
    private static let commentBubbleTextScaleKey = "yd_comment_bubble_text_scale"
    private static let readerTextUnderlineDecorationKey = "yd_reader_text_underline_decoration"
    private static let readerTextUnderlineDecorationColorHexKey = "yd_reader_text_underline_decoration_color_hex"
    private static let readerDialogueHighlightKey = "yd_reader_dialogue_highlight"
    private static let readerDialogueHighlightColorHexKey = "yd_reader_dialogue_highlight_color_hex"
    private static let readerDialogueBoxKey = "yd_reader_dialogue_box"
    private static let readerDialogueBoxColorHexKey = "yd_reader_dialogue_box_color_hex"
    private static let readerCustomBackgroundModeKey = "yd_reader_custom_background_mode"
    private static let readerCustomBackgroundColorHexKey = "yd_reader_custom_background_color_hex"
    private static let readerCustomBackgroundImageFileNameKey = "yd_reader_custom_background_image_file_name"
    private static let readerOverlayLayoutDataKey = "yd_reader_overlay_layout_data"
    private static let readerOverlayLayoutMigrationVersionKey = "yd_reader_overlay_layout_migration_version"
    private static let readerOverlayLayoutCorruptBackupKey = "yd_reader_overlay_layout_corrupt_backup"
    private static let launchImageEnabledKey = "yd_launch_image_enabled"
    private static let launchImageLightFileNameKey = "yd_launch_image_light_file_name"
    private static let launchImageDarkFileNameKey = "yd_launch_image_dark_file_name"
    private static let rootTabVisibleIDsKey = "yd_root_tab_visible_ids"
    private static let rootTabHidesLabelsKey = "yd_root_tab_hides_labels"
    private static let rootTabIconSizeKey = "yd_root_tab_icon_size"
    static let rootTabIconAssetsKey = "yd_root_tab_icon_assets"
    static let commentBubbleScaleRange: ClosedRange<Double> = 0.5...2.0
    static let commentBubbleTextScaleRange: ClosedRange<Double> = 0.2...0.8
    static let defaultCommentBubbleScale = 1.0
    static let defaultCommentBubbleTextScale = 0.4
    static let defaultReaderUnderlineColorHex: UInt32 = 0x8E8E93
    static let defaultReaderDialogueHighlightColorHex: UInt32 = 0xFF6B3A
    static let defaultReaderDialogueBoxColorHex: UInt32 = 0xFFF0C0

    static func uiColor(rgbHex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgbHex >> 16) & 0xFF) / 255,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255,
            blue: CGFloat(rgbHex & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - Account State

    @Published var isLoggedIn: Bool {
        didSet { UserDefaults.standard.set(isLoggedIn, forKey: "yd_account_logged_in") }
    }
    @Published var accountDisplayName: String {
        didSet { UserDefaults.standard.set(accountDisplayName, forKey: "yd_account_display_name") }
    }
    @Published var accountEmail: String {
        didSet { UserDefaults.standard.set(accountEmail, forKey: "yd_account_email") }
    }
    @Published var accountProvider: String {
        didSet { UserDefaults.standard.set(accountProvider, forKey: "yd_account_provider") }
    }
    @Published var accountUserIdentifier: String {
        didSet { UserDefaults.standard.set(accountUserIdentifier, forKey: "yd_account_user_identifier") }
    }
    @Published var accountPhotoURL: String {
        didSet { UserDefaults.standard.set(accountPhotoURL, forKey: "yd_account_photo_url") }
    }

    /// Subtitle shown under the account name. Prefers a real email, otherwise falls
    /// back to a provider description so we never display an opaque identifier.
    var accountSubtitle: String {
        guard isLoggedIn else { return localized("登入後可同步進度") }
        if !accountEmail.isEmpty { return accountEmail }
        switch accountProvider {
        case "Apple": return localized("透過 Apple 登入")
        case "Google": return localized("透過 Google 登入")
        default: return localized("已登入")
        }
    }
    @Published var accountAvatarData: Data? {
        didSet {
            if let accountAvatarData {
                UserDefaults.standard.set(accountAvatarData, forKey: "yd_account_avatar_data")
            } else {
                UserDefaults.standard.removeObject(forKey: "yd_account_avatar_data")
            }
        }
    }

    @Published var textConversion: TextConversion {
        didSet { UserDefaults.standard.set(textConversion.rawValue, forKey: "yd_text_conv") }
    }
    @Published var lineHeightMultiple: Double {
        didSet { UserDefaults.standard.set(lineHeightMultiple, forKey: "yd_line_height_multiple") }
    }
    @Published var scrollMode: Bool {
        didSet { UserDefaults.standard.set(scrollMode, forKey: "yd_scroll_mode") }
    }
    @Published var readerBrightness: Double {
        didSet { UserDefaults.standard.set(readerBrightness, forKey: "yd_reader_brightness") }
    }
    @Published var followSystemBrightness: Bool {
        didSet {
            UserDefaults.standard.set(followSystemBrightness, forKey: "yd_follow_sys_brightness")
        }
    }
    @Published var letterSpacing: Double {
        didSet { UserDefaults.standard.set(letterSpacing, forKey: "yd_letter_spacing") }
    }
    @Published var paragraphSpacingMultiplier: Double {
        didSet { UserDefaults.standard.set(paragraphSpacingMultiplier, forKey: "yd_paragraph_spacing_mult") }
    }
    @Published var pageMarginH: Double {
        didSet { UserDefaults.standard.set(pageMarginH, forKey: "yd_page_margin_h") }
    }
    @Published var pageMarginV: Double {
        didSet { UserDefaults.standard.set(pageMarginV, forKey: "yd_page_margin_v") }
    }
    @Published var footerBottomPadding: Double {
        didSet { UserDefaults.standard.set(footerBottomPadding, forKey: "yd_footer_bottom_padding") }
    }
    @Published var footerTextGap: Double {
        didSet { UserDefaults.standard.set(footerTextGap, forKey: "yd_footer_text_gap") }
    }
    @Published var readerTitleVisible: Bool {
        didSet { UserDefaults.standard.set(readerTitleVisible, forKey: "yd_reader_title_visible") }
    }
    @Published var readerTitleSize: Double {
        didSet { UserDefaults.standard.set(readerTitleSize, forKey: "yd_reader_title_size") }
    }
    @Published var readerTitleTopSpacing: Double {
        didSet { UserDefaults.standard.set(readerTitleTopSpacing, forKey: "yd_reader_title_top_spacing") }
    }
    @Published var readerTitleBottomSpacing: Double {
        didSet { UserDefaults.standard.set(readerTitleBottomSpacing, forKey: "yd_reader_title_bottom_spacing") }
    }
    /// Reader header (頁眉): the info band above the text in paged mode.
    @Published var readerHeaderVisible: Bool {
        didSet { UserDefaults.standard.set(readerHeaderVisible, forKey: "yd_reader_header_visible") }
    }
    @Published var readerHeaderTopPadding: Double {
        didSet { UserDefaults.standard.set(readerHeaderTopPadding, forKey: "yd_reader_header_top_padding") }
    }
    @Published var readerHeaderTextGap: Double {
        didSet { UserDefaults.standard.set(readerHeaderTextGap, forKey: "yd_reader_header_text_gap") }
    }
    @Published var readerHeaderHorizontalPadding: Double {
        didSet { UserDefaults.standard.set(readerHeaderHorizontalPadding, forKey: "yd_reader_header_h_padding") }
    }
    /// Reader footer (頁腳): the page/progress/clock band below the text in paged mode.
    @Published var readerFooterVisible: Bool {
        didSet { UserDefaults.standard.set(readerFooterVisible, forKey: "yd_reader_footer_visible") }
    }
    @Published var readerFooterHorizontalPadding: Double {
        didSet { UserDefaults.standard.set(readerFooterHorizontalPadding, forKey: "yd_reader_footer_h_padding") }
    }
    /// Placement of each header field, keyed by `ReaderHeaderField.rawValue`
    /// with `ReaderHeaderFieldPosition.rawValue` values. Fields without an
    /// entry are hidden. Display-only — changing it never repaginates.
    @Published var readerHeaderFieldPositions: [String: String] {
        didSet { UserDefaults.standard.set(readerHeaderFieldPositions, forKey: "yd_reader_header_positions") }
    }
    @Published var readerOverlayLayout: ReaderOverlayLayout {
        didSet {
            Self.persistReaderOverlayLayout(readerOverlayLayout)
        }
    }
    @Published var pageTurnStyle: PageTurnStyle {
        didSet { UserDefaults.standard.set(pageTurnStyle.rawValue, forKey: "yd_page_turn_style") }
    }
    @Published var readerSpreadMode: ReaderSpreadMode {
        didSet { UserDefaults.standard.set(readerSpreadMode.rawValue, forKey: "yd_reader_spread_mode") }
    }
    @Published var readerWritingMode: ReaderWritingMode {
        didSet { UserDefaults.standard.set(readerWritingMode.rawValue, forKey: "yd_reader_writing_mode") }
    }
    /// When on, tapping EITHER side edge of a paged reader turns to the next page
    /// (instead of left = previous / right = next). The center zone still toggles the menu.
    /// Read at tap time by `CoreTextPageEngineView`'s gesture handler — no relayout needed.
    @Published var readerTapBothSidesNextPage: Bool {
        didSet { UserDefaults.standard.set(readerTapBothSidesNextPage, forKey: "yd_reader_tap_both_next") }
    }
    /// Paged mode only: swiping up shows a growing ✕ chip and releasing closes
    /// the reader. Defaults ON; scroll mode never installs the gesture. Read at
    /// gesture-begin time by `CoreTextPageEngineView` — no relayout needed.
    @Published var readerSwipeUpToExit: Bool {
        didSet { UserDefaults.standard.set(readerSwipeUpToExit, forKey: "yd_reader_swipe_up_exit") }
    }
    /// When on, the reader theme automatically follows the system light/dark
    /// appearance (light → last light theme, dark → night). Selecting a specific
    /// theme from the menu turns this off. Applied live in `ReaderView`.
    @Published var readerFollowSystemTheme: Bool {
        didSet { UserDefaults.standard.set(readerFollowSystemTheme, forKey: "yd_reader_follow_system_theme") }
    }
    @Published var readerTextUnderlineDecorationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(readerTextUnderlineDecorationEnabled, forKey: Self.readerTextUnderlineDecorationKey)
        }
    }
    @Published var readerTextUnderlineDecorationColorHex: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(readerTextUnderlineDecorationColorHex), forKey: Self.readerTextUnderlineDecorationColorHexKey)
        }
    }
    /// Tint quoted dialogue (「」『』"" '') in the theme accent color. Applied as a
    /// `.foregroundColor` override when the chapter attributed string is built, so it
    /// colors justified glyphs natively and works in both horizontal and vertical modes.
    @Published var readerDialogueHighlightEnabled: Bool {
        didSet {
            UserDefaults.standard.set(readerDialogueHighlightEnabled, forKey: Self.readerDialogueHighlightKey)
        }
    }
    @Published var readerDialogueHighlightColorHex: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(readerDialogueHighlightColorHex), forKey: Self.readerDialogueHighlightColorHexKey)
        }
    }
    /// Draws a `.backgroundColor` box behind quoted dialogue (nested under 對話文字高亮).
    @Published var readerDialogueBoxEnabled: Bool {
        didSet {
            UserDefaults.standard.set(readerDialogueBoxEnabled, forKey: Self.readerDialogueBoxKey)
        }
    }
    @Published var readerDialogueBoxColorHex: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(readerDialogueBoxColorHex), forKey: Self.readerDialogueBoxColorHexKey)
        }
    }
    @Published var commentBubbleFollowsSourceSVG: Bool {
        didSet {
            UserDefaults.standard.set(commentBubbleFollowsSourceSVG, forKey: Self.commentBubbleFollowsSourceSVGKey)
        }
    }
    @Published var commentBubblePresetMode: ReaderCommentBubblePresetMode {
        didSet {
            UserDefaults.standard.set(commentBubblePresetMode.rawValue, forKey: Self.commentBubblePresetModeKey)
        }
    }
    @Published private(set) var commentBubbleCustomStyles: [ReaderCommentBubbleCustomStyle] {
        didSet {
            Self.saveCommentBubbleCustomStyles(commentBubbleCustomStyles)
        }
    }
    @Published private(set) var commentBubbleSelectedCustomStyleID: UUID? {
        didSet {
            Self.saveCommentBubbleSelectedCustomStyleID(commentBubbleSelectedCustomStyleID)
        }
    }
    var commentBubbleSelectedCustomStyle: ReaderCommentBubbleCustomStyle? {
        guard let commentBubbleSelectedCustomStyleID else { return nil }
        return commentBubbleCustomStyles.first { $0.id == commentBubbleSelectedCustomStyleID }
    }
    /// Read-only compatibility accessor for renderer and settings call sites.
    var commentBubbleCustomSVG: String {
        commentBubbleSelectedCustomStyle?.svg ?? ""
    }
    /// Read-only compatibility accessor for renderer and settings call sites.
    var commentBubbleCustomStyleName: String {
        commentBubbleSelectedCustomStyle?.name ?? ""
    }
    @Published var commentBubbleScale: Double {
        didSet {
            let sanitized = Self.sanitizedCommentBubbleScale(commentBubbleScale)
            if commentBubbleScale != sanitized {
                commentBubbleScale = sanitized
            } else {
                UserDefaults.standard.set(commentBubbleScale, forKey: Self.commentBubbleScaleKey)
            }
        }
    }
    @Published var commentBubbleTextScale: Double {
        didSet {
            let sanitized = Self.sanitizedCommentBubbleTextScale(commentBubbleTextScale)
            if commentBubbleTextScale != sanitized {
                commentBubbleTextScale = sanitized
            } else {
                UserDefaults.standard.set(commentBubbleTextScale, forKey: Self.commentBubbleTextScaleKey)
            }
        }
    }
    @Published var readerCustomBackgroundMode: ReaderCustomBackgroundMode {
        didSet {
            UserDefaults.standard.set(readerCustomBackgroundMode.rawValue, forKey: Self.readerCustomBackgroundModeKey)
        }
    }
    @Published var readerCustomBackgroundColorHex: UInt32? {
        didSet {
            if let readerCustomBackgroundColorHex {
                UserDefaults.standard.set(Int(readerCustomBackgroundColorHex), forKey: Self.readerCustomBackgroundColorHexKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.readerCustomBackgroundColorHexKey)
            }
        }
    }
    @Published var readerCustomBackgroundImageFileName: String? {
        didSet {
            if let readerCustomBackgroundImageFileName, !readerCustomBackgroundImageFileName.isEmpty {
                UserDefaults.standard.set(readerCustomBackgroundImageFileName, forKey: Self.readerCustomBackgroundImageFileNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.readerCustomBackgroundImageFileNameKey)
            }
        }
    }

    // MARK: - App Appearance Themes

    @Published var appearanceThemeID: String {
        didSet { UserDefaults.standard.set(appearanceThemeID, forKey: Self.appearanceThemeIDKey) }
    }
    @Published var appearanceDarkThemeID: String {
        didSet { UserDefaults.standard.set(appearanceDarkThemeID, forKey: Self.appearanceDarkThemeIDKey) }
    }
    @Published var appearanceUsesSeparateDarkTheme: Bool {
        didSet { UserDefaults.standard.set(appearanceUsesSeparateDarkTheme, forKey: Self.appearanceSeparateDarkThemeKey) }
    }
    @Published var appearanceBindReaderTheme: Bool {
        didSet { UserDefaults.standard.set(appearanceBindReaderTheme, forKey: Self.appearanceBindReaderThemeKey) }
    }

    // MARK: - Launch Image (App Splash)

    /// Master switch for the custom launch splash. Defaults off; gated on Pro at
    /// the UI entry point and again when the overlay decides whether to present.
    @Published var launchImageEnabled: Bool {
        didSet { UserDefaults.standard.set(launchImageEnabled, forKey: Self.launchImageEnabledKey) }
    }
    @Published var launchImageLightFileName: String? {
        didSet {
            if let launchImageLightFileName, !launchImageLightFileName.isEmpty {
                UserDefaults.standard.set(launchImageLightFileName, forKey: Self.launchImageLightFileNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.launchImageLightFileNameKey)
            }
        }
    }
    @Published var launchImageDarkFileName: String? {
        didSet {
            if let launchImageDarkFileName, !launchImageDarkFileName.isEmpty {
                UserDefaults.standard.set(launchImageDarkFileName, forKey: Self.launchImageDarkFileNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.launchImageDarkFileNameKey)
            }
        }
    }
    @Published var appearanceReaderInterface: AppearanceReaderInterface {
        didSet { UserDefaults.standard.set(appearanceReaderInterface.rawValue, forKey: Self.appearanceReaderInterfaceKey) }
    }
    @Published var customAppearanceThemes: [AppearanceCustomTheme] {
        didSet { Self.saveCustomAppearanceThemes(customAppearanceThemes) }
    }
    /// Live per-scope page backgrounds (keyed by `AppearancePageBackgroundScope`
    /// raw value). This is what tabs render; saved themes only feed it through
    /// 保存為新主題 / theme selection / 導入主題.
    @Published var appearancePageBackgrounds: [String: AppearancePageBackgroundConfig] {
        didSet { Self.savePageBackgrounds(appearancePageBackgrounds) }
    }

    // MARK: - Root Tab Customization

    @Published var rootTabVisibleIDs: [String] {
        didSet {
            let sanitized = Self.sanitizedRootTabVisibleIDs(rootTabVisibleIDs)
            if rootTabVisibleIDs != sanitized {
                rootTabVisibleIDs = sanitized
            } else {
                UserDefaults.standard.set(rootTabVisibleIDs, forKey: Self.rootTabVisibleIDsKey)
            }
        }
    }
    @Published var rootTabHidesLabels: Bool {
        didSet { UserDefaults.standard.set(rootTabHidesLabels, forKey: Self.rootTabHidesLabelsKey) }
    }
    @Published var rootTabIconSize: Double {
        didSet {
            let sanitized = Self.sanitizedRootTabIconSize(rootTabIconSize)
            if abs(rootTabIconSize - sanitized) > 0.001 {
                rootTabIconSize = sanitized
            } else {
                UserDefaults.standard.set(rootTabIconSize, forKey: Self.rootTabIconSizeKey)
            }
        }
    }
    @Published var rootTabIconAssets: [RootTabIconAsset] {
        didSet { Self.saveRootTabIconAssets(rootTabIconAssets) }
    }

    @Published var selectedGlobalFontPostScript: String? {
        didSet {
            if let selectedGlobalFontPostScript, !selectedGlobalFontPostScript.isEmpty {
                UserDefaults.standard.set(
                    selectedGlobalFontPostScript,
                    forKey: Self.globalFontPostScriptKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Self.globalFontPostScriptKey)
            }
        }
    }
    @Published var selectedReaderFontPostScript: String? {
        didSet {
            if let selectedReaderFontPostScript, !selectedReaderFontPostScript.isEmpty {
                UserDefaults.standard.set(selectedReaderFontPostScript, forKey: "yd_reader_font_postscript")
            } else {
                UserDefaults.standard.removeObject(forKey: "yd_reader_font_postscript")
            }
        }
    }

    var resolvedGlobalFontPostScript: String? {
        guard let selectedGlobalFontPostScript,
              userFonts.contains(where: { $0.postScriptName == selectedGlobalFontPostScript }) else {
            return nil
        }
        return selectedGlobalFontPostScript
    }

    func validateGlobalFontSelection() {
        guard let selectedGlobalFontPostScript else { return }
        guard userFonts.contains(where: { $0.postScriptName == selectedGlobalFontPostScript }),
              UIFont(name: selectedGlobalFontPostScript, size: 17) != nil else {
            self.selectedGlobalFontPostScript = nil
            return
        }
    }
    @Published var userFonts: [UserFontInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(userFonts) {
                UserDefaults.standard.set(data, forKey: "yd_user_fonts")
            }
        }
    }

    // MARK: - Reader Font (persisted across sessions)

    @Published var readerFontBold: Bool {
        didSet { UserDefaults.standard.set(readerFontBold, forKey: "yd_reader_font_bold") }
    }

    @Published var readerFontSize: Double {
        didSet { UserDefaults.standard.set(readerFontSize, forKey: "yd_reader_font_size") }
    }

    /// Additional inter-line spacing derived from the line-height multiplier (pt).
    var lineSpacing: Double {
        max(0, (lineHeightMultiple - 1.0) * readerFontSize)
    }

    /// Paragraph spacing derived from the multiplier (pt).
    var paragraphSpacing: Double {
        max(0, readerFontSize * paragraphSpacingMultiplier)
    }

    var localeIdentifier: String {
        Locale.autoupdatingCurrent.identifier
    }

    // MARK: - Bookshelf Settings

    @Published var bookshelfGridColumnCount: Int {
        didSet {
            let sanitized = Self.sanitizedBookshelfGridColumnCount(bookshelfGridColumnCount)
            if bookshelfGridColumnCount != sanitized {
                bookshelfGridColumnCount = sanitized
            } else {
                UserDefaults.standard.set(sanitized, forKey: Self.bookshelfGridColumnCountKey)
            }
        }
    }

    static func sanitizedBookshelfGridColumnCount(_ value: Int) -> Int {
        guard let minimum = bookshelfGridColumnCountOptions.min(),
              let maximum = bookshelfGridColumnCountOptions.max() else {
            return defaultBookshelfGridColumnCount
        }
        return min(max(value, minimum), maximum)
    }

    // MARK: - Network Settings

    @Published var searchConcurrency: Int {
        didSet { UserDefaults.standard.set(searchConcurrency, forKey: "yd_search_concurrency") }
    }
    @Published var searchAutoPauseCount: Int {
        didSet {
            UserDefaults.standard.set(searchAutoPauseCount, forKey: "yd_search_auto_pause_count")
        }
    }
    @Published var searchCacheDays: Int {
        didSet { UserDefaults.standard.set(searchCacheDays, forKey: "yd_search_cache_days") }
    }

    /// Auto iCloud sync: merge with iCloud on launch and when backgrounding.
    @Published var iCloudAutoSync: Bool {
        didSet { UserDefaults.standard.set(iCloudAutoSync, forKey: "yd_icloud_auto_sync") }
    }

    // MARK: - TTS Settings

    @Published var httpTtsUrlTemplate: String {
        didSet { UserDefaults.standard.set(httpTtsUrlTemplate, forKey: "yd_http_tts_url_template") }
    }
    @Published var httpTtsHeaders: [String: String] {
        didSet { Self.saveTTSHeaders(httpTtsHeaders) }
    }
    @Published var importedTTSSources: [ImportedTTSSource] {
        didSet { Self.saveImportedTTSSources(importedTTSSources) }
    }
    /// Force the offline, on-device `AVSpeechSynthesizer` voice even when an HTTP source exists.
    @Published var ttsUseSystemVoice: Bool {
        didSet { UserDefaults.standard.set(ttsUseSystemVoice, forKey: "yd_tts_use_system_voice") }
    }
    /// Selected `AVSpeechSynthesisVoice` identifier for the offline engine; empty = auto by language.
    @Published var ttsSystemVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(ttsSystemVoiceIdentifier, forKey: "yd_tts_system_voice_id") }
    }

    /// The currently active TTS source, derived from matching `httpTtsUrlTemplate` against imported sources.
    var activeTTSSource: ImportedTTSSource? {
        let template = httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }
        return importedTTSSources.first { $0.urlTemplate == template }
    }

    private init() {
        UserDefaults.standard.removeObject(forKey: "yd_app_lang")
        isLoggedIn = UserDefaults.standard.bool(forKey: "yd_account_logged_in")
        accountDisplayName = UserDefaults.standard.string(forKey: "yd_account_display_name") ?? ""
        accountEmail = UserDefaults.standard.string(forKey: "yd_account_email") ?? ""
        accountProvider = UserDefaults.standard.string(forKey: "yd_account_provider") ?? ""
        accountUserIdentifier = UserDefaults.standard.string(forKey: "yd_account_user_identifier") ?? ""
        accountPhotoURL = UserDefaults.standard.string(forKey: "yd_account_photo_url") ?? ""
        accountAvatarData = UserDefaults.standard.data(forKey: "yd_account_avatar_data")
        let rawConv = UserDefaults.standard.string(forKey: "yd_text_conv") ?? ""
        textConversion = TextConversion(rawValue: rawConv) ?? .original
        readerFontBold = UserDefaults.standard.bool(forKey: "yd_reader_font_bold")
        let persistedFontSize =
            (UserDefaults.standard.object(forKey: "yd_reader_font_size") as? Double) ?? 18.0
        readerFontSize = persistedFontSize

        if let savedLineHeightMultiple = UserDefaults.standard.object(forKey: "yd_line_height_multiple") as? Double {
            lineHeightMultiple = savedLineHeightMultiple
        } else if let legacyLineSpacing = UserDefaults.standard.object(forKey: "yd_line_spacing") as? Double {
            lineHeightMultiple = max(1.0, 1.0 + legacyLineSpacing / max(persistedFontSize, 1.0))
        } else {
            lineHeightMultiple = 1.65
        }

        scrollMode = UserDefaults.standard.bool(forKey: "yd_scroll_mode")
        readerBrightness =
            (UserDefaults.standard.object(forKey: "yd_reader_brightness") as? Double) ?? 0.8
        if UserDefaults.standard.object(forKey: "yd_follow_sys_brightness") == nil {
            followSystemBrightness = true
        } else {
            followSystemBrightness = UserDefaults.standard.bool(forKey: "yd_follow_sys_brightness")
        }
        letterSpacing =
            (UserDefaults.standard.object(forKey: "yd_letter_spacing") as? Double) ?? 0.0

        if let savedParagraphSpacingMultiplier = UserDefaults.standard.object(forKey: "yd_paragraph_spacing_mult") as? Double {
            paragraphSpacingMultiplier = savedParagraphSpacingMultiplier
        } else if let legacyParagraphSpacing = UserDefaults.standard.object(forKey: "yd_paragraph_spacing") as? Double {
            paragraphSpacingMultiplier = max(0, legacyParagraphSpacing / max(persistedFontSize, 1.0))
        } else {
            paragraphSpacingMultiplier = 0.8
        }

        pageMarginH =
            (UserDefaults.standard.object(forKey: "yd_page_margin_h") as? Double) ?? 24.0
        pageMarginV =
            (UserDefaults.standard.object(forKey: "yd_page_margin_v") as? Double) ?? 16.0
        let loadedFooterBottomPadding =
            (UserDefaults.standard.object(forKey: "yd_footer_bottom_padding") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultFooterBottomPadding)
        footerBottomPadding = loadedFooterBottomPadding
        let loadedFooterTextGap =
            (UserDefaults.standard.object(forKey: "yd_footer_text_gap") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultFooterTextGap)
        footerTextGap = loadedFooterTextGap
        readerTitleVisible =
            (UserDefaults.standard.object(forKey: "yd_reader_title_visible") as? Bool) ?? true
        readerTitleSize =
            (UserDefaults.standard.object(forKey: "yd_reader_title_size") as? Double) ?? 28.0
        readerTitleTopSpacing =
            (UserDefaults.standard.object(forKey: "yd_reader_title_top_spacing") as? Double) ?? 10.0
        readerTitleBottomSpacing =
            (UserDefaults.standard.object(forKey: "yd_reader_title_bottom_spacing") as? Double) ?? 20.0
        let loadedReaderHeaderVisible =
            (UserDefaults.standard.object(forKey: "yd_reader_header_visible") as? Bool) ?? true
        readerHeaderVisible = loadedReaderHeaderVisible
        let loadedReaderHeaderTopPadding =
            (UserDefaults.standard.object(forKey: "yd_reader_header_top_padding") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultHeaderTopPadding)
        readerHeaderTopPadding = loadedReaderHeaderTopPadding
        let loadedReaderHeaderTextGap =
            (UserDefaults.standard.object(forKey: "yd_reader_header_text_gap") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultHeaderTextGap)
        readerHeaderTextGap = loadedReaderHeaderTextGap
        let loadedReaderFooterVisible =
            (UserDefaults.standard.object(forKey: "yd_reader_footer_visible") as? Bool) ?? true
        readerFooterVisible = loadedReaderFooterVisible
        let loadedReaderHeaderHorizontalPadding =
            (UserDefaults.standard.object(forKey: "yd_reader_header_h_padding") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultHeaderHorizontalPadding)
        readerHeaderHorizontalPadding = loadedReaderHeaderHorizontalPadding
        let loadedReaderFooterHorizontalPadding =
            (UserDefaults.standard.object(forKey: "yd_reader_footer_h_padding") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultFooterHorizontalPadding)
        readerFooterHorizontalPadding = loadedReaderFooterHorizontalPadding
        let loadedReaderHeaderFieldPositions =
            (UserDefaults.standard.dictionary(forKey: "yd_reader_header_positions") as? [String: String])
            ?? ReaderHeaderLayout.defaultFieldPositions
        readerHeaderFieldPositions = loadedReaderHeaderFieldPositions
        let legacyOverlaySettings = ReaderLegacyOverlaySettings(
            headerVisible: loadedReaderHeaderVisible,
            footerVisible: loadedReaderFooterVisible,
            headerFieldPositions: loadedReaderHeaderFieldPositions,
            headerTopPadding: loadedReaderHeaderTopPadding,
            headerHorizontalPadding: loadedReaderHeaderHorizontalPadding,
            footerBottomPadding: loadedFooterBottomPadding,
            footerHorizontalPadding: loadedReaderFooterHorizontalPadding,
            topContentReservation: Double(
                ReaderLayoutMetrics.topInset(
                    safeTop: 0,
                    headerVisible: loadedReaderHeaderVisible,
                    headerTopPadding: CGFloat(loadedReaderHeaderTopPadding),
                    headerTextGap: CGFloat(loadedReaderHeaderTextGap)
                )
            ),
            bottomContentReservation: Double(
                ReaderLayoutMetrics.bottomInset(
                    safeBottom: 0,
                    footerVisible: loadedReaderFooterVisible,
                    footerBottomPadding: CGFloat(loadedFooterBottomPadding),
                    footerTextGap: CGFloat(loadedFooterTextGap)
                )
            )
        )
        let overlayDefaults = UserDefaults.standard
        let overlayResolution = ReaderOverlayLayoutMigration.resolve(
            storedData: overlayDefaults.data(forKey: Self.readerOverlayLayoutDataKey),
            legacy: legacyOverlaySettings
        )
        readerOverlayLayout = overlayResolution.layout
        if let corruptData = overlayResolution.corruptData {
            overlayDefaults.set(corruptData, forKey: Self.readerOverlayLayoutCorruptBackupKey)
        }
        Self.persistReaderOverlayLayout(overlayResolution.layout, defaults: overlayDefaults)
        let rawPageTurn = UserDefaults.standard.string(forKey: "yd_page_turn_style") ?? ""
        pageTurnStyle = PageTurnStyle(rawValue: rawPageTurn) ?? .slide
        let rawSpreadMode = UserDefaults.standard.string(forKey: "yd_reader_spread_mode") ?? ""
        let loadedSpreadMode = (ReaderSpreadMode(rawValue: rawSpreadMode) ?? .singlePage).normalizedForUserSelection
        readerSpreadMode = loadedSpreadMode
        if rawSpreadMode != loadedSpreadMode.rawValue {
            UserDefaults.standard.set(loadedSpreadMode.rawValue, forKey: "yd_reader_spread_mode")
        }
        let rawWritingMode = UserDefaults.standard.string(forKey: "yd_reader_writing_mode") ?? ""
        readerWritingMode = ReaderWritingMode(rawValue: rawWritingMode) ?? .horizontal
        readerTapBothSidesNextPage = UserDefaults.standard.bool(forKey: "yd_reader_tap_both_next")
        readerSwipeUpToExit =
            (UserDefaults.standard.object(forKey: "yd_reader_swipe_up_exit") as? Bool) ?? true
        readerFollowSystemTheme = UserDefaults.standard.bool(forKey: "yd_reader_follow_system_theme")
        readerTextUnderlineDecorationEnabled = UserDefaults.standard.bool(forKey: Self.readerTextUnderlineDecorationKey)
        readerTextUnderlineDecorationColorHex = UInt32(clamping:
            (UserDefaults.standard.object(forKey: Self.readerTextUnderlineDecorationColorHexKey) as? Int)
                ?? Int(Self.defaultReaderUnderlineColorHex)
        )
        readerDialogueHighlightEnabled = UserDefaults.standard.bool(forKey: Self.readerDialogueHighlightKey)
        readerDialogueHighlightColorHex = UInt32(clamping:
            (UserDefaults.standard.object(forKey: Self.readerDialogueHighlightColorHexKey) as? Int)
                ?? Int(Self.defaultReaderDialogueHighlightColorHex)
        )
        readerDialogueBoxEnabled = UserDefaults.standard.bool(forKey: Self.readerDialogueBoxKey)
        readerDialogueBoxColorHex = UInt32(clamping:
            (UserDefaults.standard.object(forKey: Self.readerDialogueBoxColorHexKey) as? Int)
                ?? Int(Self.defaultReaderDialogueBoxColorHex)
        )
        if UserDefaults.standard.object(forKey: Self.commentBubbleFollowsSourceSVGKey) == nil {
            commentBubbleFollowsSourceSVG = true
        } else {
            commentBubbleFollowsSourceSVG = UserDefaults.standard.bool(forKey: Self.commentBubbleFollowsSourceSVGKey)
        }
        let defaults = UserDefaults.standard
        let rawBubbleMode = defaults.string(forKey: Self.commentBubblePresetModeKey) ?? ""
        var loadedBubbleMode = ReaderCommentBubblePresetMode(rawValue: rawBubbleMode) ?? .builtin
        let legacyName = defaults.string(forKey: Self.commentBubbleCustomStyleNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedName = legacyName.flatMap { $0.isEmpty ? nil : $0 }
            ?? localized("自訂 SVG")
        let recoverableLegacyStyles = ReaderCommentBubbleCustomStyleLibrary.migratingLegacyStyleIfNeeded(
            in: [],
            legacySVG: defaults.string(forKey: Self.commentBubbleCustomSVGKey) ?? "",
            generatedPlaceholderSVG: CommentBubbleSVGRecognizer.builtinBubbleSVG,
            migratedName: migratedName
        )
        let loadedCustomStyles: [ReaderCommentBubbleCustomStyle]
        let loadedSelectedCustomStyleID: UUID?
        let shouldPersistLoadedLibrary: Bool
        let shouldRemoveLegacyKeys: Bool
        let v2DecodingResult = ReaderCommentBubbleCustomStyleLibrary.decodeV2(
            keyExists: defaults.object(forKey: Self.commentBubbleCustomStylesV2Key) != nil,
            data: defaults.data(forKey: Self.commentBubbleCustomStylesV2Key)
        )
        switch v2DecodingResult {
        case .valid(let decodedStyles):
            loadedCustomStyles = ReaderCommentBubbleCustomStyleLibrary.uniqued(decodedStyles)
            let persistedSelectedID = defaults.string(forKey: Self.commentBubbleSelectedCustomStyleIDKey)
                .flatMap { UUID(uuidString: $0) }
            loadedSelectedCustomStyleID = ReaderCommentBubbleCustomStyleLibrary.validatedSelectedID(
                persistedSelectedID,
                in: loadedCustomStyles
            )
            shouldPersistLoadedLibrary = true
            shouldRemoveLegacyKeys = true
        case .missing:
            loadedCustomStyles = recoverableLegacyStyles
            loadedSelectedCustomStyleID = loadedCustomStyles.first?.id
            shouldPersistLoadedLibrary = true
            shouldRemoveLegacyKeys = true
        case .invalid where !recoverableLegacyStyles.isEmpty:
            loadedCustomStyles = recoverableLegacyStyles
            loadedSelectedCustomStyleID = loadedCustomStyles.first?.id
            shouldPersistLoadedLibrary = true
            shouldRemoveLegacyKeys = true
        case .invalid:
            loadedCustomStyles = []
            loadedSelectedCustomStyleID = nil
            shouldPersistLoadedLibrary = false
            shouldRemoveLegacyKeys = false
        }
        if loadedBubbleMode == .custom, loadedSelectedCustomStyleID == nil {
            loadedBubbleMode = .builtin
        }
        commentBubblePresetMode = loadedBubbleMode
        commentBubbleCustomStyles = loadedCustomStyles
        commentBubbleSelectedCustomStyleID = loadedSelectedCustomStyleID
        if shouldPersistLoadedLibrary {
            Self.saveCommentBubbleCustomStyles(loadedCustomStyles)
            Self.saveCommentBubbleSelectedCustomStyleID(loadedSelectedCustomStyleID)
            defaults.set(loadedBubbleMode.rawValue, forKey: Self.commentBubblePresetModeKey)
        }
        if shouldRemoveLegacyKeys {
            defaults.removeObject(forKey: Self.commentBubbleCustomSVGKey)
            defaults.removeObject(forKey: Self.commentBubbleCustomStyleNameKey)
        }
        commentBubbleScale = Self.sanitizedCommentBubbleScale(
            (UserDefaults.standard.object(forKey: Self.commentBubbleScaleKey) as? Double)
                ?? Self.defaultCommentBubbleScale
        )
        commentBubbleTextScale = Self.sanitizedCommentBubbleTextScale(
            (UserDefaults.standard.object(forKey: Self.commentBubbleTextScaleKey) as? Double)
                ?? Self.defaultCommentBubbleTextScale
        )
        let rawCustomBackgroundMode = UserDefaults.standard.string(forKey: Self.readerCustomBackgroundModeKey) ?? ""
        readerCustomBackgroundMode = ReaderCustomBackgroundMode(rawValue: rawCustomBackgroundMode) ?? .none
        if let savedCustomBackgroundColor = UserDefaults.standard.object(forKey: Self.readerCustomBackgroundColorHexKey) as? Int {
            readerCustomBackgroundColorHex = UInt32(clamping: savedCustomBackgroundColor)
        } else {
            readerCustomBackgroundColorHex = nil
        }
        readerCustomBackgroundImageFileName = UserDefaults.standard.string(forKey: Self.readerCustomBackgroundImageFileNameKey)
        customAppearanceThemes = Self.loadCustomAppearanceThemes()
        appearancePageBackgrounds = Self.loadPageBackgrounds()
        appearanceThemeID = UserDefaults.standard.string(forKey: Self.appearanceThemeIDKey)
            ?? Self.defaultAppearanceThemeID
        appearanceDarkThemeID = UserDefaults.standard.string(forKey: Self.appearanceDarkThemeIDKey)
            ?? Self.defaultAppearanceThemeID
        appearanceUsesSeparateDarkTheme = UserDefaults.standard.bool(forKey: Self.appearanceSeparateDarkThemeKey)
        appearanceBindReaderTheme = UserDefaults.standard.bool(forKey: Self.appearanceBindReaderThemeKey)
        launchImageEnabled = UserDefaults.standard.bool(forKey: Self.launchImageEnabledKey)
        launchImageLightFileName = UserDefaults.standard.string(forKey: Self.launchImageLightFileNameKey)
        launchImageDarkFileName = UserDefaults.standard.string(forKey: Self.launchImageDarkFileNameKey)
        let rawReaderInterface = UserDefaults.standard.string(forKey: Self.appearanceReaderInterfaceKey) ?? ""
        appearanceReaderInterface = AppearanceReaderInterface(rawValue: rawReaderInterface) ?? .classic
        rootTabVisibleIDs = Self.sanitizedRootTabVisibleIDs(
            UserDefaults.standard.stringArray(forKey: Self.rootTabVisibleIDsKey)
                ?? Self.defaultRootTabVisibleIDs
        )
        rootTabHidesLabels = UserDefaults.standard.bool(forKey: Self.rootTabHidesLabelsKey)
        let loadedRootTabIconSize =
            (UserDefaults.standard.object(forKey: Self.rootTabIconSizeKey) as? Double)
            ?? Self.defaultRootTabIconSize
        rootTabIconSize = Self.sanitizedRootTabIconSize(loadedRootTabIconSize)
        rootTabIconAssets = Self.loadRootTabIconAssets()
        let decodedUserFonts: [UserFontInfo]
        if let fontData = UserDefaults.standard.data(forKey: "yd_user_fonts"),
           let decodedFonts = try? JSONDecoder().decode([UserFontInfo].self, from: fontData) {
            decodedUserFonts = decodedFonts
        } else {
            decodedUserFonts = []
        }
        userFonts = decodedUserFonts
        selectedReaderFontPostScript = UserDefaults.standard.string(forKey: "yd_reader_font_postscript")
        let storedGlobalFont = UserDefaults.standard.string(forKey: Self.globalFontPostScriptKey)
        let validatedGlobalFont = storedGlobalFont.flatMap { postScriptName in
            decodedUserFonts.contains { $0.postScriptName == postScriptName }
                ? postScriptName
                : nil
        }
        selectedGlobalFontPostScript = validatedGlobalFont
        if storedGlobalFont != nil, validatedGlobalFont == nil {
            UserDefaults.standard.removeObject(forKey: Self.globalFontPostScriptKey)
        }

        bookshelfGridColumnCount = Self.sanitizedBookshelfGridColumnCount(
            (UserDefaults.standard.object(forKey: Self.bookshelfGridColumnCountKey) as? Int)
            ?? Self.defaultBookshelfGridColumnCount
        )

        searchConcurrency =
            (UserDefaults.standard.object(forKey: "yd_search_concurrency") as? Int) ?? 8
        searchAutoPauseCount =
            (UserDefaults.standard.object(forKey: "yd_search_auto_pause_count") as? Int) ?? 0
        searchCacheDays =
            (UserDefaults.standard.object(forKey: "yd_search_cache_days") as? Int) ?? 5
        iCloudAutoSync =
            (UserDefaults.standard.object(forKey: "yd_icloud_auto_sync") as? Bool) ?? true
        httpTtsUrlTemplate = UserDefaults.standard.string(forKey: "yd_http_tts_url_template") ?? ""
        httpTtsHeaders = Self.loadTTSHeaders()
        importedTTSSources = Self.loadImportedTTSSources()
        ttsUseSystemVoice = UserDefaults.standard.bool(forKey: "yd_tts_use_system_voice")
        ttsSystemVoiceIdentifier = UserDefaults.standard.string(forKey: "yd_tts_system_voice_id") ?? ""
    }

    func selectCommentBubbleBuiltinStyle() {
        commentBubblePresetMode = .builtin
    }

    func selectCommentBubbleSquareStyle() {
        commentBubblePresetMode = .square
    }

    func selectCommentBubbleCustomStyle(id: UUID) {
        guard ReaderCommentBubbleCustomStyleLibrary.validatedSelectedID(
            id,
            in: commentBubbleCustomStyles
        ) != nil else {
            commentBubbleSelectedCustomStyleID = nil
            commentBubblePresetMode = .builtin
            return
        }

        commentBubbleSelectedCustomStyleID = id
        commentBubblePresetMode = .custom
    }

    func upsertCommentBubbleCustomStyle(_ style: ReaderCommentBubbleCustomStyle) {
        commentBubbleCustomStyles = ReaderCommentBubbleCustomStyleLibrary.uniqued(
            ReaderCommentBubbleCustomStyleLibrary.upserting(
                style,
                into: commentBubbleCustomStyles
            )
        )
        commentBubbleSelectedCustomStyleID = style.id
        commentBubblePresetMode = .custom
    }

    func deleteCommentBubbleCustomStyle(id: UUID) {
        let wasSelected = commentBubbleSelectedCustomStyleID == id
        commentBubbleCustomStyles = ReaderCommentBubbleCustomStyleLibrary.deleting(
            id: id,
            from: commentBubbleCustomStyles
        )

        guard wasSelected else { return }
        commentBubbleSelectedCustomStyleID = nil
        commentBubblePresetMode = .builtin
    }

    private static func saveCommentBubbleCustomStyles(
        _ styles: [ReaderCommentBubbleCustomStyle]
    ) {
        let encodedStyles = (try? JSONEncoder().encode(styles)) ?? Data("[]".utf8)
        UserDefaults.standard.set(encodedStyles, forKey: commentBubbleCustomStylesV2Key)
    }

    private static func saveCommentBubbleSelectedCustomStyleID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(
                id.uuidString,
                forKey: commentBubbleSelectedCustomStyleIDKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: commentBubbleSelectedCustomStyleIDKey)
        }
    }

    @discardableResult
    private static func persistReaderOverlayLayout(
        _ layout: ReaderOverlayLayout,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(layout) else { return false }
        defaults.set(data, forKey: readerOverlayLayoutDataKey)
        guard defaults.data(forKey: readerOverlayLayoutDataKey) == data else { return false }
        defaults.set(
            ReaderOverlayLayout.currentVersion,
            forKey: readerOverlayLayoutMigrationVersionKey
        )
        return true
    }

    static func sanitizedCommentBubbleScale(_ value: Double) -> Double {
        min(max(value, commentBubbleScaleRange.lowerBound), commentBubbleScaleRange.upperBound)
    }

    static func sanitizedCommentBubbleTextScale(_ value: Double) -> Double {
        min(max(value, commentBubbleTextScaleRange.lowerBound), commentBubbleTextScaleRange.upperBound)
    }

    private static func loadImportedTTSSources() -> [ImportedTTSSource] {
        guard let data = UserDefaults.standard.data(forKey: "yd_imported_tts_sources"),
              let decoded = try? JSONDecoder().decode([ImportedTTSSource].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveImportedTTSSources(_ sources: [ImportedTTSSource]) {
        if sources.isEmpty {
            UserDefaults.standard.removeObject(forKey: "yd_imported_tts_sources")
            return
        }
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: "yd_imported_tts_sources")
        }
    }

    private static func loadTTSHeaders() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "yd_http_tts_headers"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveTTSHeaders(_ headers: [String: String]) {
        if headers.isEmpty {
            UserDefaults.standard.removeObject(forKey: "yd_http_tts_headers")
            return
        }
        if let data = try? JSONEncoder().encode(headers) {
            UserDefaults.standard.set(data, forKey: "yd_http_tts_headers")
        }
    }

    func selectedAppearanceThemeID(for colorScheme: ColorScheme) -> String {
        if appearanceUsesSeparateDarkTheme, colorScheme == .dark {
            return appearanceDarkThemeID
        }
        return appearanceThemeID
    }

    func appearanceTheme(
        for colorScheme: ColorScheme,
        isProActive: Bool
    ) -> AppearanceThemePreset {
        let selectedID = selectedAppearanceThemeID(for: colorScheme)
        if let selected = AppearanceThemePreset.preset(id: selectedID, customThemes: customAppearanceThemes),
           isProActive || !selected.requiresPro {
            return selected
        }
        return AppearanceThemePreset.preset(
            id: Self.defaultAppearanceThemeID,
            customThemes: customAppearanceThemes
        ) ?? AppearanceThemePreset.freeSolidPresets[0]
    }

    func setAppearanceTheme(_ preset: AppearanceThemePreset, for colorScheme: ColorScheme) {
        if appearanceUsesSeparateDarkTheme, colorScheme == .dark {
            appearanceDarkThemeID = preset.id
        } else {
            appearanceThemeID = preset.id
        }
        applyPageBackgroundsFromCustomTheme(id: preset.id)
        // Sync the DSColor-facing global in the same turn as the selection.
        // `activeAppTheme` is otherwise refreshed only in ContentView.body, which
        // SwiftUI may run *after* re-rendering the themed screen that triggered
        // this — so surfaces would read last frame's theme and only catch up on
        // the next tap (the "switch takes two taps" bug). Matches ContentView's
        // resolvedAppTheme rule: presets retint only in light appearance.
        AppearanceThemePreset.activeAppTheme =
            (colorScheme == .light && !preset.isClassic) ? preset : nil
    }

    @discardableResult
    func createCustomAppearanceTheme(from preset: AppearanceThemePreset) -> AppearanceCustomTheme {
        var custom = preset.customCopy(name: localized("自訂主題"))
        var index = 1
        let existingNames = Set(customAppearanceThemes.map(\.name))
        while existingNames.contains(custom.name) {
            index += 1
            custom.name = localized("自訂主題") + " \(index)"
        }
        customAppearanceThemes.append(custom)
        appearanceThemeID = custom.id
        return custom
    }

    /// Deletes a custom theme. Any selection (light or dark slot) pointing at
    /// the deleted theme falls back to the classic default.
    func deleteCustomAppearanceTheme(id: String) {
        if let payload = customAppearanceThemes.first(where: { $0.id == id })?.pageBackgrounds {
            deletePageBackgroundFiles(in: payload)
        }
        customAppearanceThemes.removeAll { $0.id == id }
        if appearanceThemeID == id {
            appearanceThemeID = Self.defaultAppearanceThemeID
        }
        if appearanceDarkThemeID == id {
            appearanceDarkThemeID = Self.defaultAppearanceThemeID
        }
    }

    private static func loadCustomAppearanceThemes() -> [AppearanceCustomTheme] {
        guard let data = UserDefaults.standard.data(forKey: customAppearanceThemesKey),
              let decoded = try? JSONDecoder().decode([AppearanceCustomTheme].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveCustomAppearanceThemes(_ themes: [AppearanceCustomTheme]) {
        if themes.isEmpty {
            UserDefaults.standard.removeObject(forKey: customAppearanceThemesKey)
            return
        }
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: customAppearanceThemesKey)
        }
    }

    // MARK: - Page Backgrounds (app-wide)

    private static func loadPageBackgrounds() -> [String: AppearancePageBackgroundConfig] {
        guard let data = UserDefaults.standard.data(forKey: appearancePageBackgroundsKey),
              let decoded = try? JSONDecoder().decode(
                  [String: AppearancePageBackgroundConfig].self,
                  from: data
              ) else {
            return [:]
        }
        return decoded
    }

    private static func savePageBackgrounds(_ value: [String: AppearancePageBackgroundConfig]) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: appearancePageBackgroundsKey)
            return
        }
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: appearancePageBackgroundsKey)
        }
    }

    func pageBackgroundConfig(for scope: AppearancePageBackgroundScope) -> AppearancePageBackgroundConfig {
        appearancePageBackgrounds[scope.rawValue] ?? AppearancePageBackgroundConfig()
    }

    func updatePageBackgroundConfig(
        _ config: AppearancePageBackgroundConfig,
        for scope: AppearancePageBackgroundScope
    ) {
        if config.isEmpty {
            appearancePageBackgrounds.removeValue(forKey: scope.rawValue)
        } else {
            appearancePageBackgrounds[scope.rawValue] = config
        }
    }

    /// The layer to draw behind `scope` in `colorScheme`: the scope's own config
    /// when it paints anything for that appearance, otherwise the global one.
    /// Nil keeps the stock system look.
    func resolvedPageBackgroundSlice(
        for scope: AppearancePageBackgroundScope,
        colorScheme: ColorScheme
    ) -> AppearancePageBackgroundSlice? {
        if let own = appearancePageBackgrounds[scope.rawValue]?.slice(for: colorScheme) {
            return own
        }
        guard scope != .global else { return nil }
        return appearancePageBackgrounds[AppearancePageBackgroundScope.global.rawValue]?
            .slice(for: colorScheme)
    }

    @discardableResult
    func importPageBackgroundImage(
        from url: URL,
        scope: AppearancePageBackgroundScope,
        appearance colorScheme: ColorScheme
    ) throws -> String {
        let fileName = try AppearancePageBackgroundImageStore.shared.importImage(fileURL: url)
        replacePageBackgroundImage(fileName: fileName, scope: scope, colorScheme: colorScheme)
        return fileName
    }

    @discardableResult
    func importPageBackgroundImage(
        data: Data,
        scope: AppearancePageBackgroundScope,
        appearance colorScheme: ColorScheme
    ) throws -> String {
        let fileName = try AppearancePageBackgroundImageStore.shared.importImage(data: data)
        replacePageBackgroundImage(fileName: fileName, scope: scope, colorScheme: colorScheme)
        return fileName
    }

    func clearPageBackgroundImage(
        scope: AppearancePageBackgroundScope,
        appearance colorScheme: ColorScheme
    ) {
        replacePageBackgroundImage(fileName: nil, scope: scope, colorScheme: colorScheme)
    }

    private func replacePageBackgroundImage(
        fileName: String?,
        scope: AppearancePageBackgroundScope,
        colorScheme: ColorScheme
    ) {
        var config = pageBackgroundConfig(for: scope)
        if let old = config.imageFileName(for: colorScheme) {
            AppearancePageBackgroundImageStore.shared.delete(fileName: old)
        }
        config.setImageFileName(fileName, for: colorScheme)
        updatePageBackgroundConfig(config, for: scope)
    }

    /// Clears every scope's page background and deletes the imported images.
    func resetAllPageBackgrounds() {
        deletePageBackgroundFiles(in: appearancePageBackgrounds)
        appearancePageBackgrounds = [:]
    }

    private func deletePageBackgroundFiles(in configs: [String: AppearancePageBackgroundConfig]) {
        for config in configs.values {
            for name in config.imageFileNames {
                AppearancePageBackgroundImageStore.shared.delete(fileName: name)
            }
        }
    }

    /// Deep-copies a page-background dict, duplicating the image files, so the
    /// copy's owner can be deleted independently of the source.
    private func duplicatedPageBackgrounds(
        _ source: [String: AppearancePageBackgroundConfig]
    ) -> [String: AppearancePageBackgroundConfig]? {
        guard !source.isEmpty else { return nil }
        var result: [String: AppearancePageBackgroundConfig] = [:]
        for (key, config) in source {
            var copy = config
            copy.lightImageFileName = config.lightImageFileName.flatMap {
                AppearancePageBackgroundImageStore.shared.duplicate(fileName: $0)
            }
            copy.darkImageFileName = config.darkImageFileName.flatMap {
                AppearancePageBackgroundImageStore.shared.duplicate(fileName: $0)
            }
            if !copy.isEmpty {
                result[key] = copy
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Snapshots the current theme colors plus the live page backgrounds into a
    /// new custom theme and selects it. Image files are duplicated so the theme
    /// owns its copies.
    @discardableResult
    func saveCurrentAppearanceAsTheme(
        named name: String,
        basedOn preset: AppearanceThemePreset
    ) -> AppearanceCustomTheme {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var custom = preset.customCopy(
            name: uniqueCustomThemeName(base: trimmed.isEmpty ? localized("自訂主題") : trimmed)
        )
        custom.pageBackgrounds = duplicatedPageBackgrounds(appearancePageBackgrounds)
        customAppearanceThemes.append(custom)
        appearanceThemeID = custom.id
        return custom
    }

    /// Selecting a saved theme that carries a page-background snapshot replaces
    /// the live page backgrounds with it (the snapshot itself stays untouched).
    private func applyPageBackgroundsFromCustomTheme(id: String) {
        guard let theme = customAppearanceThemes.first(where: { $0.id == id }),
              let payload = theme.pageBackgrounds,
              !payload.isEmpty else {
            return
        }
        deletePageBackgroundFiles(in: appearancePageBackgrounds)
        appearancePageBackgrounds = duplicatedPageBackgrounds(payload) ?? [:]
    }

    private func uniqueCustomThemeName(base: String) -> String {
        let existing = Set(customAppearanceThemes.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Theme export / import

    /// Packages `preset`'s colors and the live page backgrounds (images embedded
    /// as base64) into a shareable single-file theme.
    func appearanceThemeExportFile(for preset: AppearanceThemePreset) -> AppearanceThemeExportFile {
        var payloads: [String: AppearanceThemeExportFile.PageBackgroundPayload] = [:]
        for (key, config) in appearancePageBackgrounds {
            payloads[key] = AppearanceThemeExportFile.PageBackgroundPayload(
                lightPrimaryHex: config.lightPrimaryHex,
                lightSecondaryHex: config.lightSecondaryHex,
                darkPrimaryHex: config.darkPrimaryHex,
                darkSecondaryHex: config.darkSecondaryHex,
                lightImage: exportImagePayload(config.lightImageFileName),
                darkImage: exportImagePayload(config.darkImageFileName),
                lightImageOpacity: config.lightImageOpacity,
                darkImageOpacity: config.darkImageOpacity
            )
        }
        return AppearanceThemeExportFile(
            format: AppearanceThemeExportFile.formatIdentifier,
            version: 1,
            name: preset.localizedName,
            backgroundHex: preset.background.rgbHex ?? 0xF4F5F7,
            textHex: preset.text.rgbHex ?? 0x333333,
            barHex: preset.bar.rgbHex ?? 0xFFFFFF,
            accentHex: preset.accent.rgbHex ?? 0x007AFF,
            dialogueHex: preset.dialogue.rgbHex ?? 0xD8E9FB,
            pageBackgrounds: payloads.isEmpty ? nil : payloads
        )
    }

    private func exportImagePayload(_ fileName: String?) -> AppearanceThemeExportFile.ImagePayload? {
        guard let fileName, !fileName.isEmpty,
              let data = AppearancePageBackgroundImageStore.shared.fileData(fileName: fileName) else {
            return nil
        }
        return AppearanceThemeExportFile.ImagePayload(
            fileExtension: (fileName as NSString).pathExtension,
            base64: data.base64EncodedString()
        )
    }

    /// Imports a theme file: creates a custom theme (with its page-background
    /// snapshot), selects it, and applies the snapshot to the live settings.
    @discardableResult
    func importAppearanceTheme(from data: Data) throws -> AppearanceCustomTheme {
        guard let file = try? JSONDecoder().decode(AppearanceThemeExportFile.self, from: data),
              file.format == AppearanceThemeExportFile.formatIdentifier else {
            throw AppearanceThemeImportError.invalidFile
        }

        var payloadConfigs: [String: AppearancePageBackgroundConfig] = [:]
        for (key, payload) in file.pageBackgrounds ?? [:] {
            guard AppearancePageBackgroundScope(rawValue: key) != nil else { continue }
            var config = AppearancePageBackgroundConfig(
                lightPrimaryHex: payload.lightPrimaryHex,
                lightSecondaryHex: payload.lightSecondaryHex,
                darkPrimaryHex: payload.darkPrimaryHex,
                darkSecondaryHex: payload.darkSecondaryHex
            )
            config.lightImageFileName = writeImportedThemeImage(payload.lightImage)
            config.darkImageFileName = writeImportedThemeImage(payload.darkImage)
            config.lightImageOpacity = payload.lightImageOpacity
            config.darkImageOpacity = payload.darkImageOpacity
            if !config.isEmpty {
                payloadConfigs[key] = config
            }
        }

        let custom = AppearanceCustomTheme(
            name: uniqueCustomThemeName(
                base: file.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? localized("自訂主題")
                    : file.name
            ),
            backgroundHex: file.backgroundHex,
            textHex: file.textHex,
            barHex: file.barHex,
            accentHex: file.accentHex,
            dialogueHex: file.dialogueHex,
            pageBackgrounds: payloadConfigs.isEmpty ? nil : payloadConfigs
        )
        customAppearanceThemes.append(custom)
        appearanceThemeID = custom.id
        applyPageBackgroundsFromCustomTheme(id: custom.id)
        return custom
    }

    private func writeImportedThemeImage(
        _ payload: AppearanceThemeExportFile.ImagePayload?
    ) -> String? {
        guard let payload, let data = Data(base64Encoded: payload.base64) else { return nil }
        return try? AppearancePageBackgroundImageStore.shared.importImage(data: data)
    }

    var readerCustomBackgroundImageURL: URL? {
        guard let fileName = readerCustomBackgroundImageFileName, !fileName.isEmpty else { return nil }
        return try? ReaderCustomBackgroundStorageManager.shared.fileURL(fileName: fileName)
    }

    var readerCustomBackgroundPreviewUIColor: UIColor {
        switch readerCustomBackgroundMode {
        case .color:
            if let readerCustomBackgroundColorHex {
                return AppearanceThemePreset.hex(readerCustomBackgroundColorHex)
            }
            return ReaderTheme.white.uiBackgroundColor
        case .image:
            return UIColor.white
        case .none:
            return UIColor.systemGray5
        }
    }

    var readerCustomBackgroundPreviewTextUIColor: UIColor {
        switch readerCustomBackgroundMode {
        case .color:
            return Self.readableTextColor(for: readerCustomBackgroundPreviewUIColor)
        case .image:
            return AppearanceThemePreset.hex(0x2E322F)
        case .none:
            return UIColor.label
        }
    }

    var readerCustomBackgroundPreset: AppearanceThemePreset? {
        guard readerCustomBackgroundMode != .none else { return nil }
        let background = readerCustomBackgroundPreviewUIColor
        let text = readerCustomBackgroundPreviewTextUIColor
        let accent = AppearanceThemePreset.hex(0x007AFF)
        return AppearanceThemePreset(
            id: "reader_custom_\(readerCustomBackgroundMode.rawValue)_\(readerCustomBackgroundColorHex ?? 0)_\(readerCustomBackgroundImageFileName ?? "")",
            nameKey: "自定義",
            displayName: localized("自定義"),
            background: background,
            text: text,
            bar: background,
            accent: accent,
            dialogue: accent.withAlphaComponent(0.16),
            previewBackground: background,
            relativePreviewImagePath: nil,
            imagePaths: [],
            requiresPro: false,
            isImagePreset: readerCustomBackgroundMode == .image,
            isCustom: true
        )
    }

    func applyReaderCustomBackgroundColor(_ color: UIColor) {
        readerCustomBackgroundColorHex = color.rgbHex ?? 0xF4F5F7
        readerCustomBackgroundMode = .color
        readerFollowSystemTheme = false
        appearanceBindReaderTheme = false
        AppearanceThemePreset.activeReaderTheme = readerCustomBackgroundPreset
        sendReaderAppearanceRefresh()
    }

    @discardableResult
    func importReaderCustomBackgroundImage(from url: URL) throws -> String {
        let fileName = try ReaderCustomBackgroundStorageManager.shared.importBackground(fileURL: url)
        readerCustomBackgroundImageFileName = fileName
        readerCustomBackgroundMode = .image
        readerFollowSystemTheme = false
        appearanceBindReaderTheme = false
        AppearanceThemePreset.activeReaderTheme = readerCustomBackgroundPreset
        sendReaderAppearanceRefresh()
        return fileName
    }

    func clearReaderCustomBackground() {
        readerCustomBackgroundMode = .none
        AppearanceThemePreset.activeReaderTheme = appearanceBindReaderTheme ? AppearanceThemePreset.activeReaderTheme : nil
        sendReaderAppearanceRefresh()
    }

    // MARK: - Launch Image import / resolution

    @discardableResult
    func importLaunchImage(from url: URL, for scheme: LaunchImageScheme) throws -> String {
        let fileName = try LaunchImageStorageManager.shared.importImage(fileURL: url, scheme: scheme)
        switch scheme {
        case .light:
            removeLaunchImageFile(launchImageLightFileName)
            launchImageLightFileName = fileName
        case .dark:
            removeLaunchImageFile(launchImageDarkFileName)
            launchImageDarkFileName = fileName
        }
        return fileName
    }

    func clearLaunchImage(for scheme: LaunchImageScheme) {
        switch scheme {
        case .light:
            removeLaunchImageFile(launchImageLightFileName)
            launchImageLightFileName = nil
        case .dark:
            removeLaunchImageFile(launchImageDarkFileName)
            launchImageDarkFileName = nil
        }
    }

    func launchImageFileName(for scheme: LaunchImageScheme) -> String? {
        let name = scheme == .dark ? launchImageDarkFileName : launchImageLightFileName
        return (name?.isEmpty == false) ? name : nil
    }

    /// On-disk URL of the splash image to show for `colorScheme`, or nil when the
    /// matching (and fallback) slot is empty. Falls back to the other appearance's
    /// image so a single imported image still shows in both modes.
    func launchImageURL(for colorScheme: ColorScheme) -> URL? {
        let primary = colorScheme == .dark ? launchImageDarkFileName : launchImageLightFileName
        let secondary = colorScheme == .dark ? launchImageLightFileName : launchImageDarkFileName
        let name = (primary?.isEmpty == false ? primary : nil)
            ?? (secondary?.isEmpty == false ? secondary : nil)
        guard let name,
              let url = try? LaunchImageStorageManager.shared.fileURL(fileName: name),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func removeLaunchImageFile(_ fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        LaunchImageStorageManager.shared.delete(fileName: fileName)
    }

    private func sendReaderAppearanceRefresh() {
        Task { @MainActor in
            ReaderConfig.shared.refresh.send(.appearance)
        }
    }

    private static func readableTextColor(for color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .label
        }
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
        return luminance > 0.45 ? AppearanceThemePreset.hex(0x2E322F) : AppearanceThemePreset.hex(0xF5F5F5)
    }

    @discardableResult
    private func importUserFont(from url: URL) throws -> UserFontInfo {
        let info = try UserFontStorageManager.shared.importFont(fileURL: url)
        userFonts.removeAll { $0.postScriptName == info.postScriptName }
        userFonts.append(info)
        userFonts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return info
    }

    @discardableResult
    func importReaderFont(from url: URL) throws -> UserFontInfo {
        let info = try importUserFont(from: url)
        selectedReaderFontPostScript = info.postScriptName
        return info
    }

    @discardableResult
    func importGlobalFont(from url: URL) throws -> UserFontInfo {
        let info = try importUserFont(from: url)
        selectedGlobalFontPostScript = info.postScriptName
        return info
    }

    func deleteUserFont(_ font: UserFontInfo) {
        UserFontStorageManager.shared.delete(font)
        userFonts.removeAll { $0.id == font.id }
        if selectedGlobalFontPostScript == font.postScriptName {
            selectedGlobalFontPostScript = nil
        }
        if selectedReaderFontPostScript == font.postScriptName {
            selectedReaderFontPostScript = nil
        }
    }

    func signIn(displayName: String, email: String, provider: String, userIdentifier: String = "") {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentifier = userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        accountDisplayName = trimmedName.isEmpty ? trimmedEmail : trimmedName
        accountEmail = trimmedEmail
        accountProvider = provider
        accountUserIdentifier = trimmedIdentifier
        isLoggedIn = true
    }

    @MainActor
    func applyFirebaseUser(_ user: User?, providerOverride: String? = nil) {
        guard let user else {
            clearAccountState()
            return
        }

        let email = user.email ?? ""
        let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        accountDisplayName = displayName?.isEmpty == false ? displayName! : (email.isEmpty ? localized("已登入") : email)
        accountEmail = email
        accountProvider = providerOverride ?? Self.providerDisplayName(from: user)
        accountUserIdentifier = user.uid
        accountPhotoURL = user.photoURL?.absoluteString ?? accountPhotoURL
        isLoggedIn = true
    }

    @MainActor
    func applyFirebaseProfile(_ profile: UserProfile) {
        accountDisplayName = profile.displayName
        accountEmail = profile.email
        accountProvider = profile.provider
        accountUserIdentifier = profile.uid
        accountPhotoURL = profile.photoURL ?? ""
        isLoggedIn = true
        profile.preferences.apply(to: self)
    }

    func updateAccountAvatar(data: Data?) {
        accountAvatarData = data
    }

    func updateAccountDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accountDisplayName = trimmed
    }

    func signOut(
        revokeGoogleAccess: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        let provider = accountProvider

        guard provider == "Google" else {
            clearAccountState()
            completion?(nil)
            return
        }

        if revokeGoogleAccess {
            GIDSignIn.sharedInstance.disconnect { [weak self] error in
                if error != nil {
                    GIDSignIn.sharedInstance.signOut()
                }
                DispatchQueue.main.async {
                    self?.clearAccountState()
                    completion?(error)
                }
            }
            return
        }

        GIDSignIn.sharedInstance.signOut()
        clearAccountState()
        completion?(nil)
    }

    func clearAccountState() {
        isLoggedIn = false
        accountDisplayName = ""
        accountEmail = ""
        accountProvider = ""
        accountUserIdentifier = ""
        accountPhotoURL = ""
        accountAvatarData = nil
    }

    private static func providerDisplayName(from user: User) -> String {
        switch user.providerData.first?.providerID {
        case "google.com":
            return "Google"
        case "apple.com":
            return "Apple"
        case "password":
            return "Email"
        default:
            return user.providerData.first?.providerID ?? "Firebase"
        }
    }
}

enum ReaderCustomBackgroundStorageError: Error {
    case unsupportedImageFile
    case cannotReadImage

    var messageKey: String {
        switch self {
        case .unsupportedImageFile:
            return "只支援 WebP、JPG、JPEG 圖片。"
        case .cannotReadImage:
            return "無法讀取圖片。"
        }
    }
}

final class ReaderCustomBackgroundStorageManager {
    static let shared = ReaderCustomBackgroundStorageManager()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importBackground(fileURL: URL) throws -> String {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw ReaderCustomBackgroundStorageError.unsupportedImageFile
        }
        guard let image = UIImage(contentsOfFile: fileURL.path),
              image.size.width > 0,
              image.size.height > 0 else {
            throw ReaderCustomBackgroundStorageError.cannotReadImage
        }

        let directory = try backgroundsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "reader-background-\(UUID().uuidString).\(sourceExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: fileURL, to: destination)
        return fileName
    }

    func fileURL(fileName: String) throws -> URL {
        try backgroundsDirectoryURL().appendingPathComponent(fileName)
    }

    private func backgroundsDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ReaderBackgrounds", isDirectory: true)
    }
}

// MARK: - Launch Image storage

enum LaunchImageScheme: String, CaseIterable, Identifiable {
    case light
    case dark
    var id: String { rawValue }
}

enum LaunchImageStorageError: Error {
    case unsupportedImageFile
    case cannotReadImage

    var messageKey: String {
        switch self {
        case .unsupportedImageFile:
            return "只支援 WebP、JPG、JPEG 或 PNG 圖片。"
        case .cannotReadImage:
            return "無法讀取圖片。"
        }
    }
}

/// Copies imported launch images into Application Support/LaunchImages and hands
/// back a stable file name persisted in `GlobalSettings`.
final class LaunchImageStorageManager {
    static let shared = LaunchImageStorageManager()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importImage(fileURL: URL, scheme: LaunchImageScheme) throws -> String {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw LaunchImageStorageError.unsupportedImageFile
        }
        guard let image = UIImage(contentsOfFile: fileURL.path),
              image.size.width > 0,
              image.size.height > 0 else {
            throw LaunchImageStorageError.cannotReadImage
        }

        let directory = try imagesDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "launch-\(scheme.rawValue)-\(UUID().uuidString).\(sourceExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: fileURL, to: destination)
        return fileName
    }

    func fileURL(fileName: String) throws -> URL {
        try imagesDirectoryURL().appendingPathComponent(fileName)
    }

    func delete(fileName: String) {
        guard let url = try? fileURL(fileName: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func imagesDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("LaunchImages", isDirectory: true)
    }
}
