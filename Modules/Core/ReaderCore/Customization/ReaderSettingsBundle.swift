import Foundation

/// Everything 閱讀設定 lets a reader change, in one `.yuedustyle` archive, so a reading
/// setup can be shared whole: the page look (`readingSettings`), how the reader behaves
/// (`behavior`), and every library item those name — the saved reading backgrounds, the
/// custom comment bubble, the fonts — with every picture and font file packed alongside
/// by `ReaderStylePackage`, so the file survives AirDrop to another device.
///
/// 章節標題樣式 and 正則高亮 keep their own single-purpose exports; this is the
/// "take all of it with me" file. Each part is optional so a future version can
/// drop or add one without making older archives undecodable.
///
/// Version 2 (2026-11-14) added everything after `regexHighlights`. The three version-1
/// parts are still written, so a build that predates version 2 still imports the layout,
/// the title style and the highlight rules of a new file.
struct ReaderSettingsBundle: Codable, Equatable, Sendable {
    static let formatIdentifier = "yuedu-reader-settings"
    static let currentVersion = 2

    /// A saved reading background (`ReaderCustomBackground`) named by the setup — the
    /// worn one or a 綁定閱讀主題 pick — with its picture as a package attachment.
    struct ReaderBackground: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var colorHex: UInt32
        var textColorHex: UInt32?
        var isDark: Bool
        /// `ReaderStylePackageFile.id` of the picture; nil for a plain colour.
        var imageAttachmentID: String?
    }

    /// An imported font the setup reads with, as a package attachment.
    struct Font: Codable, Equatable, Sendable {
        var postScriptName: String
        var attachmentID: String
    }

    var format: String
    var version: Int
    /// The `readConfig.json` bytes produced by `ReaderLayoutPresetExporter`,
    /// carried verbatim (base64 inside the manifest JSON) rather than re-modelled
    /// here. Only a version-1 file is imported through it — a version-2 file's
    /// `readingSettings` speaks for every field it covers.
    var layoutConfig: Data?
    var chapterTitleStyle: ChapterTitleStyle?
    var regexHighlights: RegexHighlightConfiguration?
    /// The whole page look, every field filled in (`currentReadingSettingsSnapshot`).
    var readingSettings: AppearanceThemeReadingSettings?
    var behavior: ReaderBehaviorSettings?
    var readerBackgrounds: [ReaderBackground]?
    /// The custom comment bubble `readingSettings.commentBubble` wears, when it wears one.
    var commentBubbleStyle: ReaderCommentBubbleCustomStyle?
    var fonts: [Font]?

    init(
        layoutConfig: Data?,
        chapterTitleStyle: ChapterTitleStyle?,
        regexHighlights: RegexHighlightConfiguration?,
        readingSettings: AppearanceThemeReadingSettings? = nil,
        behavior: ReaderBehaviorSettings? = nil,
        readerBackgrounds: [ReaderBackground]? = nil,
        commentBubbleStyle: ReaderCommentBubbleCustomStyle? = nil,
        fonts: [Font]? = nil
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.layoutConfig = layoutConfig
        self.chapterTitleStyle = chapterTitleStyle
        self.regexHighlights = regexHighlights
        self.readingSettings = readingSettings
        self.behavior = behavior
        self.readerBackgrounds = readerBackgrounds
        self.commentBubbleStyle = commentBubbleStyle
        self.fonts = fonts
    }

    /// Every reader-style asset the bundle references — title design, highlight rules
    /// and dialogue bubbles — so the package packs them once and an import restores
    /// pictures instead of blanks.
    var assetIDs: [UUID] {
        var values: [UUID] = []
        if let chapterTitleStyle {
            values += ReaderStyleAssetReferences.assetIDs(in: chapterTitleStyle)
        }
        if let regexHighlights {
            values += ReaderStyleAssetReferences.assetIDs(in: regexHighlights)
        }
        if let readingSettings {
            values += ReaderStyleAssetReferences.assetIDs(in: readingSettings)
        }
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// The layout half decoded through the app's single layout parser. `nil`
    /// when the bundle carried no layout section; a *malformed* section throws,
    /// because silently importing "everything except the layout" is the kind of
    /// half-applied result that reads as a rendering bug later.
    func decodedLayoutPreset() throws -> ReaderLayoutPreset? {
        guard let layoutConfig else { return nil }
        return try ReaderLayoutPresetImporter.decode(data: layoutConfig)
    }
}

/// The rows of 閱讀設定 that are about how the reader behaves rather than how the page
/// looks — kept out of `AppearanceThemeReadingSettings` on purpose, since a theme switch
/// changing them would read as a malfunction. Only a 匯入閱讀設定 file carries them.
/// Every field optional: nil leaves the receiving device's value alone.
struct ReaderBehaviorSettings: Codable, Equatable, Sendable {
    /// `TextConversion` raw value — 繁簡轉換.
    var textConversion: String?
    /// 套用書本間距.
    var usesBookSpacing: Bool?
    /// `ReaderSpreadMode` raw value — 頁面顯示.
    var spreadMode: String?
    /// 全局翻頁.
    var tapBothSidesNextPage: Bool?
    /// 上滑退出閱讀.
    var swipeUpToExit: Bool?
    /// 下拉加入書籤.
    var pullDownToBookmark: Bool?
    /// 翻頁區塊編輯, one layout per reading direction as `TouchZoneConfig` keeps them.
    var touchZonesLeftToRight: TouchZoneConfig?
    var touchZonesRightToLeft: TouchZoneConfig?
    /// 跟隨系統亮度 and 閱讀亮度.
    var followsSystemBrightness: Bool?
    var brightness: Double?
    /// 閱讀時螢幕常亮.
    var keepsScreenAwake: Bool?

    static let brightnessRange: ClosedRange<Double> = 0.05...1.0

    /// What can be applied as it stands: an unknown raw value, a touch layout that is not
    /// a 3×3 grid or a brightness outside the slider's range is dropped. The file is
    /// shared and untrusted.
    func sanitized() -> ReaderBehaviorSettings {
        var value = self
        if let zones = touchZonesLeftToRight, zones.zones.count != 9 { value.touchZonesLeftToRight = nil }
        if let zones = touchZonesRightToLeft, zones.zones.count != 9 { value.touchZonesRightToLeft = nil }
        if let spreadMode, ReaderSpreadMode(rawValue: spreadMode) == nil { value.spreadMode = nil }
        if let textConversion, TextConversion(rawValue: textConversion) == nil { value.textConversion = nil }
        if let brightness {
            value.brightness = brightness.isFinite
                ? min(Self.brightnessRange.upperBound, max(Self.brightnessRange.lowerBound, brightness))
                : nil
        }
        return value
    }

    var isEmpty: Bool { self == ReaderBehaviorSettings() }
}

/// What an import actually applied, so the confirmation names it instead of
/// claiming a flat "done".
struct ReaderSettingsImportSummary: Equatable, Sendable {
    var appliedLayout = false
    var appliedChapterTitleStyle = false
    var appliedRegexHighlights = false
    var appliedDialogueBubbleStyle = false
    var appliedBehavior = false

    var isEmpty: Bool {
        !appliedLayout && !appliedChapterTitleStyle && !appliedRegexHighlights
            && !appliedDialogueBubbleStyle && !appliedBehavior
    }

    var localizedDescription: String {
        var parts: [String] = []
        if appliedLayout { parts.append(localized("排版參數")) }
        if appliedChapterTitleStyle { parts.append(localized("章節標題樣式")) }
        if appliedRegexHighlights { parts.append(localized("正則高亮")) }
        if appliedDialogueBubbleStyle { parts.append(localized("對話氣泡")) }
        if appliedBehavior { parts.append(localized("翻頁與手勢")) }
        guard !parts.isEmpty else { return localized("這個檔案沒有可匯入的內容。") }
        return String(
            format: localized("已匯入 %@。"),
            parts.joined(separator: localized("、"))
        )
    }
}
