import Foundation

/// A reading setup — everything 閱讀設定 lets a reader change about how the page looks.
///
/// Two kinds of value have this shape. The shared setup every theme falls back on is
/// complete. A theme's own values are sparse: every field is optional and means "this
/// theme does not speak for that setting", the same contract as the rest of the extras.
/// A pack that sets the type size and the header/footer leaves the highlight rules
/// alone, and keeps leaving them alone after an edit, because an edit records only the
/// field it changed. Which of the two the reader wears is decided per setting by
/// 排版生效範圍 (`ReadingSettingsScopeItem`, `GlobalSettings.synchronizeReadingSettings`).
///
/// Deliberately left out: 繁簡轉換, gestures, tap zones and brightness. Those are how
/// the reader *behaves*, not how the page looks, and a theme switch changing them
/// would read as a malfunction rather than a new look.
struct AppearanceThemeReadingSettings: Codable, Equatable, Sendable {
    /// The one custom reading background as it was stored before backgrounds became a
    /// saved list (2026-09-29): a mode and the colour or picture it names. Only read, by
    /// `ReaderBackgroundMigration`, which makes a saved background of it.
    struct CustomBackground: Codable, Hashable, Sendable {
        /// `ReaderCustomBackgroundMode` raw value.
        var mode: String
        var colorHex: UInt32?
        var imageFileName: String?
    }

    struct TextUnderline: Codable, Hashable, Sendable {
        var isEnabled: Bool
        var colorHex: UInt32
        /// `ReaderTextUnderlineStyle` raw value.
        var style: Int
        var thickness: Double
        var offset: Double
    }

    /// Which comment bubble is drawn and at what size. The custom styles themselves stay
    /// in the one shared library; a theme only names the entry it wears.
    struct CommentBubble: Codable, Hashable, Sendable {
        var followsSourceSVG: Bool
        /// `ReaderCommentBubblePresetMode` raw value.
        var presetMode: String
        var customStyleID: UUID?
        var scale: Double
        var textScale: Double
    }

    // MARK: 文字

    /// PostScript name of the reading face; `""` means the default one.
    var fontPostScript: String?
    var fontSize: Double?
    var isBold: Bool?
    /// Body text colour per reading background, keyed by `ReaderTheme` raw value.
    var textColorOverrides: [String: UInt32]?

    // MARK: 間距與邊距

    var lineHeightMultiple: Double?
    var letterSpacing: Double?
    var paragraphSpacingMultiplier: Double?
    var pageMarginH: Double?
    var pageMarginV: Double?
    var pageMarginTop: Double?
    var pageMarginBottom: Double?

    // MARK: 翻頁

    /// `PageTurnStyle` raw value.
    var pageTurnStyle: String?
    var scrollMode: Bool?

    // MARK: 排版方向

    /// `ReaderWritingMode` raw value: 橫排 or 直排, for books that carry no writing mode
    /// of their own (TXT and online books).
    var writingMode: String?

    // MARK: 頁首頁尾

    var barLayout: ReaderBarLayout?
    var headerVisible: Bool?
    var footerVisible: Bool?
    var headerTopPadding: Double?
    var headerTextGap: Double?
    var headerHorizontalPadding: Double?
    var footerHorizontalPadding: Double?
    var footerBottomPadding: Double?
    var footerTextGap: Double?

    // MARK: 章節標題

    var chapterTitleStyle: ChapterTitleStyle?

    // MARK: 閱讀背景

    /// `ReaderTheme` raw value — 白色／護眼綠／棕色／黑色.
    var readerTheme: String?
    /// 跟隨系統: the reading background switching to 黑色 in dark appearance.
    var followsSystemTheme: Bool?
    /// 綁定閱讀主題 and its two picks. They decide the reading background as much as
    /// `readerTheme` does — while on, they overwrite it — so a theme that owns the
    /// background has to own them too.
    var bindsAppearanceReaderTheme: Bool?
    var boundLightReaderTheme: String?
    var boundDarkReaderTheme: String?
    /// The saved background (`ReaderCustomBackground`) worn over `readerTheme`, as its id —
    /// `""` for none.
    var readerBackgroundID: String?
    /// Written before saved backgrounds existed; see `CustomBackground`. Never written now.
    var customBackground: CustomBackground?

    // MARK: 閱讀裝飾

    var commentBubble: CommentBubble?
    var dialogueBubbleStyle: ReaderDialogueBubbleStyle?
    var regexHighlights: RegexHighlightConfiguration?
    var textUnderline: TextUnderline?

    init() {}

    /// Speaks for nothing.
    var isEmpty: Bool { self == Self() }

    private enum CodingKeys: String, CodingKey {
        case fontPostScript, fontSize, isBold, textColorOverrides
        case lineHeightMultiple, letterSpacing, paragraphSpacingMultiplier
        case pageMarginH, pageMarginV, pageMarginTop, pageMarginBottom
        case pageTurnStyle, scrollMode
        case writingMode
        case barLayout, headerVisible, footerVisible, headerTopPadding, headerTextGap
        case headerHorizontalPadding, footerHorizontalPadding, footerBottomPadding, footerTextGap
        case chapterTitleStyle
        case readerTheme, followsSystemTheme, bindsAppearanceReaderTheme
        case boundLightReaderTheme, boundDarkReaderTheme, readerBackgroundID, customBackground
        case commentBubble, dialogueBubbleStyle, regexHighlights, textUnderline
    }

    /// Field by field, so one value this build cannot read costs that field alone.
    /// The custom themes are stored as a single array; a throw from here would fail
    /// the whole decode and come back as an empty theme list on the next launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<Value: Decodable>(_ key: CodingKeys) -> Value? {
            do {
                return try c.decodeIfPresent(Value.self, forKey: key)
            } catch {
                AppLogger.parse(
                    "⟐ theme reading field unreadable, dropped",
                    error: error,
                    context: ["field": key.stringValue]
                )
                return nil
            }
        }
        fontPostScript = field(.fontPostScript)
        fontSize = field(.fontSize)
        isBold = field(.isBold)
        textColorOverrides = field(.textColorOverrides)
        lineHeightMultiple = field(.lineHeightMultiple)
        letterSpacing = field(.letterSpacing)
        paragraphSpacingMultiplier = field(.paragraphSpacingMultiplier)
        pageMarginH = field(.pageMarginH)
        pageMarginV = field(.pageMarginV)
        pageMarginTop = field(.pageMarginTop)
        pageMarginBottom = field(.pageMarginBottom)
        pageTurnStyle = field(.pageTurnStyle)
        scrollMode = field(.scrollMode)
        writingMode = field(.writingMode)
        barLayout = field(.barLayout)
        headerVisible = field(.headerVisible)
        footerVisible = field(.footerVisible)
        headerTopPadding = field(.headerTopPadding)
        headerTextGap = field(.headerTextGap)
        headerHorizontalPadding = field(.headerHorizontalPadding)
        footerHorizontalPadding = field(.footerHorizontalPadding)
        footerBottomPadding = field(.footerBottomPadding)
        footerTextGap = field(.footerTextGap)
        chapterTitleStyle = field(.chapterTitleStyle)
        readerTheme = field(.readerTheme)
        followsSystemTheme = field(.followsSystemTheme)
        bindsAppearanceReaderTheme = field(.bindsAppearanceReaderTheme)
        boundLightReaderTheme = field(.boundLightReaderTheme)
        boundDarkReaderTheme = field(.boundDarkReaderTheme)
        readerBackgroundID = field(.readerBackgroundID)
        customBackground = field(.customBackground)
        commentBubble = field(.commentBubble)
        dialogueBubbleStyle = field(.dialogueBubbleStyle)
        regexHighlights = field(.regexHighlights)
        textUnderline = field(.textUnderline)
    }

    /// Each non-nil field of `other` replaces this value's — how an import lands on a
    /// theme that already carries a reading setup, without erasing what the import
    /// does not mention.
    func overlaid(with other: Self) -> Self {
        var merged = self
        merged.fontPostScript = other.fontPostScript ?? fontPostScript
        merged.fontSize = other.fontSize ?? fontSize
        merged.isBold = other.isBold ?? isBold
        merged.textColorOverrides = other.textColorOverrides ?? textColorOverrides
        merged.lineHeightMultiple = other.lineHeightMultiple ?? lineHeightMultiple
        merged.letterSpacing = other.letterSpacing ?? letterSpacing
        merged.paragraphSpacingMultiplier = other.paragraphSpacingMultiplier ?? paragraphSpacingMultiplier
        merged.pageMarginH = other.pageMarginH ?? pageMarginH
        merged.pageMarginV = other.pageMarginV ?? pageMarginV
        merged.pageMarginTop = other.pageMarginTop ?? pageMarginTop
        merged.pageMarginBottom = other.pageMarginBottom ?? pageMarginBottom
        merged.pageTurnStyle = other.pageTurnStyle ?? pageTurnStyle
        merged.scrollMode = other.scrollMode ?? scrollMode
        merged.writingMode = other.writingMode ?? writingMode
        merged.barLayout = other.barLayout ?? barLayout
        merged.headerVisible = other.headerVisible ?? headerVisible
        merged.footerVisible = other.footerVisible ?? footerVisible
        merged.headerTopPadding = other.headerTopPadding ?? headerTopPadding
        merged.headerTextGap = other.headerTextGap ?? headerTextGap
        merged.headerHorizontalPadding = other.headerHorizontalPadding ?? headerHorizontalPadding
        merged.footerHorizontalPadding = other.footerHorizontalPadding ?? footerHorizontalPadding
        merged.footerBottomPadding = other.footerBottomPadding ?? footerBottomPadding
        merged.footerTextGap = other.footerTextGap ?? footerTextGap
        merged.chapterTitleStyle = other.chapterTitleStyle ?? chapterTitleStyle
        merged.readerTheme = other.readerTheme ?? readerTheme
        merged.followsSystemTheme = other.followsSystemTheme ?? followsSystemTheme
        merged.bindsAppearanceReaderTheme = other.bindsAppearanceReaderTheme ?? bindsAppearanceReaderTheme
        merged.boundLightReaderTheme = other.boundLightReaderTheme ?? boundLightReaderTheme
        merged.boundDarkReaderTheme = other.boundDarkReaderTheme ?? boundDarkReaderTheme
        merged.readerBackgroundID = other.readerBackgroundID ?? readerBackgroundID
        merged.customBackground = other.customBackground ?? customBackground
        merged.commentBubble = other.commentBubble ?? commentBubble
        merged.dialogueBubbleStyle = other.dialogueBubbleStyle ?? dialogueBubbleStyle
        merged.regexHighlights = other.regexHighlights ?? regexHighlights
        merged.textUnderline = other.textUnderline ?? textUnderline
        return merged
    }
}

/// `AppearanceThemeExtras` is `Hashable`, but the layout, title and highlight models
/// this carries are only `Equatable`. Hashing the scalar fields alone keeps the
/// contract — equal values always hash equal — without making every nested style
/// model hashable for a hash nobody keys on.
extension AppearanceThemeReadingSettings: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(fontPostScript)
        hasher.combine(fontSize)
        hasher.combine(isBold)
        hasher.combine(lineHeightMultiple)
        hasher.combine(pageTurnStyle)
        hasher.combine(scrollMode)
        hasher.combine(writingMode)
        hasher.combine(readerTheme)
        hasher.combine(readerBackgroundID)
        hasher.combine(customBackground)
    }
}
