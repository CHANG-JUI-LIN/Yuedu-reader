import Foundation

/// Where one reading setting comes from — 排版生效範圍 in 閱讀設定.
///
/// Every appearance theme, built-in or custom, can keep its own value for a setting, and
/// there is one more value every theme shares. The scope picks which one the reader
/// wears, per setting, for all themes at once: 字體大小 can stay the same everywhere while
/// the reading background changes with the theme.
enum ReadingSettingsScope: String, Codable, CaseIterable, Sendable {
    /// 跟隨主題: the theme being worn keeps its own value. A theme that has none yet
    /// shows the shared one, and the first edit made under it becomes its own.
    case theme
    /// 跟隨全域: one value for every theme.
    case global

    var titleKey: String {
        switch self {
        case .theme: return "跟隨主題"
        case .global: return "跟隨全域"
        }
    }
}

/// One row of 排版生效範圍: the fields of `AppearanceThemeReadingSettings` that follow the
/// theme or not together. Named after the control in 閱讀設定 that edits them, so a row
/// here always points at something the reader can find there.
enum ReadingSettingsScopeItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case font
    case fontSize
    case bold
    case textColor
    case writingMode
    case lineSpacing
    case letterSpacing
    case paragraphSpacing
    case pageMargins
    case headerFooter
    case chapterTitle
    case background
    case pageTurn
    case commentBubble
    case dialogueBubble
    case regexHighlight
    case textUnderline

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .font: return "字體"
        case .fontSize: return "字體大小"
        case .bold: return "粗體"
        case .textColor: return "文字顏色"
        case .writingMode: return "排版方向"
        case .lineSpacing: return "行距"
        case .letterSpacing: return "字距"
        case .paragraphSpacing: return "段距"
        case .pageMargins: return "頁面邊距"
        case .headerFooter: return "頁首頁尾"
        case .chapterTitle: return "章節標題樣式"
        // Its own key: the shared 閱讀背景 is lower-case English, written for use
        // inside a sentence rather than as a row title.
        case .background: return "ReadingSetup.Background"
        case .pageTurn: return "翻頁方式"
        case .commentBubble: return "段評氣泡"
        case .dialogueBubble: return "對話氣泡"
        case .regexHighlight: return "正則高亮"
        case .textUnderline: return "文字底線"
        }
    }

    /// The same symbol the control wears in 閱讀設定. None of these may be one SF Symbols
    /// draws with localized letters: `textformat` turns into the characters 「格式」 in
    /// Chinese, and `textformat.size` and `a.magnify` put a 「字」 in, which read as stray
    /// text beside the title.
    var systemImage: String {
        switch self {
        case .font: return "f.cursive"
        case .fontSize: return "plus.magnifyingglass"
        case .bold: return "bold"
        case .textColor: return "paintbrush"
        case .writingMode: return "arrow.turn.right.down"
        case .lineSpacing: return "arrow.up.and.down.text.horizontal"
        case .letterSpacing: return "arrow.left.and.right.text.vertical"
        case .paragraphSpacing: return "paragraphsign"
        case .pageMargins: return "arrow.left.and.line.vertical.and.arrow.right"
        case .headerFooter: return "rectangle.split.3x1"
        case .chapterTitle: return "t.square"
        case .background: return "photo.on.rectangle"
        case .pageTurn: return "book.pages"
        case .commentBubble: return "text.bubble"
        case .dialogueBubble: return "bubble.left.and.bubble.right"
        case .regexHighlight: return "text.magnifyingglass"
        case .textUnderline: return "underline"
        }
    }
}

/// 排版生效範圍 as stored: one scope for every row, and the rows set on their own.
struct ReadingSettingsScopeConfiguration: Codable, Equatable, Sendable {
    var defaultScope: ReadingSettingsScope
    /// Keyed by `ReadingSettingsScopeItem` raw value, so a row a later build drops is
    /// ignored instead of failing the whole decode.
    private var overrides: [String: ReadingSettingsScope]

    /// Everything follows the theme until the reader says otherwise: a theme — a pack above
    /// all — is a whole look, its reading setup included, and switching themes switches
    /// all of it. A theme that has no value of its own for a setting wears 全域's.
    ///
    /// Was `.global` for a day (171aa952), which left every pack's reading values stored
    /// on its theme and never worn — 「主題包的設置要獨立」, 2026-09-29.
    static let `default` = Self(defaultScope: .theme, overrides: [:])

    private init(defaultScope: ReadingSettingsScope, overrides: [String: ReadingSettingsScope]) {
        self.defaultScope = defaultScope
        self.overrides = overrides
    }

    func scope(of item: ReadingSettingsScopeItem) -> ReadingSettingsScope {
        overrides[item.rawValue] ?? defaultScope
    }

    /// A row set to what the default already says stops being set on its own, so the next
    /// change of the default moves it along with the rest.
    mutating func setScope(_ scope: ReadingSettingsScope, for item: ReadingSettingsScopeItem) {
        overrides[item.rawValue] = scope == defaultScope ? nil : scope
    }

    var themeItems: Set<ReadingSettingsScopeItem> {
        Set(ReadingSettingsScopeItem.allCases.filter { scope(of: $0) == .theme })
    }
}

extension AppearanceThemeReadingSettings {
    /// Drops every field `item` governs.
    mutating func clear(_ item: ReadingSettingsScopeItem) {
        switch item {
        case .font:
            fontPostScript = nil
        case .fontSize:
            fontSize = nil
        case .bold:
            isBold = nil
        case .textColor:
            textColorOverrides = nil
        case .writingMode:
            writingMode = nil
        case .lineSpacing:
            lineHeightMultiple = nil
        case .letterSpacing:
            letterSpacing = nil
        case .paragraphSpacing:
            paragraphSpacingMultiplier = nil
        case .pageMargins:
            pageMarginH = nil
            pageMarginV = nil
            pageMarginTop = nil
            pageMarginBottom = nil
        case .headerFooter:
            barLayout = nil
            headerVisible = nil
            footerVisible = nil
            headerTopPadding = nil
            headerTextGap = nil
            headerHorizontalPadding = nil
            footerHorizontalPadding = nil
            footerBottomPadding = nil
            footerTextGap = nil
        case .chapterTitle:
            chapterTitleStyle = nil
        case .background:
            readerTheme = nil
            followsSystemTheme = nil
            bindsAppearanceReaderTheme = nil
            boundLightReaderTheme = nil
            boundDarkReaderTheme = nil
            readerBackgroundID = nil
            customBackground = nil
        case .pageTurn:
            pageTurnStyle = nil
            scrollMode = nil
        case .commentBubble:
            commentBubble = nil
        case .dialogueBubble:
            dialogueBubbleStyle = nil
        case .regexHighlight:
            regexHighlights = nil
        case .textUnderline:
            textUnderline = nil
        }
    }

    /// Only the fields `items` govern.
    func restricted(to items: Set<ReadingSettingsScopeItem>) -> Self {
        var result = self
        for item in ReadingSettingsScopeItem.allCases where !items.contains(item) {
            result.clear(item)
        }
        return result
    }

    /// The rows this value says anything about.
    var items: Set<ReadingSettingsScopeItem> {
        Set(ReadingSettingsScopeItem.allCases.filter { !restricted(to: [$0]).isEmpty })
    }
}
