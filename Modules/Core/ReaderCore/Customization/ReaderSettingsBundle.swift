import Foundation

/// Everything 閱讀設定 lets a reader change, in one `.yuedustyle` archive:
/// the layout parameters, the chapter-title style, and the regex highlight
/// rules — with every referenced image packed alongside by
/// `ReaderStylePackage`, so the file survives AirDrop to another device.
///
/// 章節標題樣式 and 正則高亮 keep their own single-purpose exports; this is the
/// "take all of it with me" file. Each part is optional so a future version can
/// drop or add one without making older archives undecodable.
struct ReaderSettingsBundle: Codable, Equatable, Sendable {
    static let formatIdentifier = "yuedu-reader-settings"
    static let currentVersion = 1

    var format: String
    var version: Int
    /// The `readConfig.json` bytes produced by `ReaderLayoutPresetExporter`,
    /// carried verbatim (base64 inside the manifest JSON) rather than re-modelled
    /// here. Importing hands these straight to `ReaderLayoutPresetImporter`, so
    /// the app keeps exactly one parser for layout parameters instead of growing
    /// a second one that drifts.
    var layoutConfig: Data?
    var chapterTitleStyle: ChapterTitleStyle?
    var regexHighlights: RegexHighlightConfiguration?

    init(
        layoutConfig: Data?,
        chapterTitleStyle: ChapterTitleStyle?,
        regexHighlights: RegexHighlightConfiguration?
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.layoutConfig = layoutConfig
        self.chapterTitleStyle = chapterTitleStyle
        self.regexHighlights = regexHighlights
    }

    /// Every asset the bundle's two style halves reference, so the package packs
    /// them once and an import restores backgrounds instead of blanks.
    var assetIDs: [UUID] {
        var values: [UUID] = []
        if let chapterTitleStyle {
            values += ReaderStyleAssetReferences.assetIDs(in: chapterTitleStyle)
        }
        if let regexHighlights {
            values += ReaderStyleAssetReferences.assetIDs(in: regexHighlights)
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

/// What an import actually applied, so the confirmation names it instead of
/// claiming a flat "done".
struct ReaderSettingsImportSummary: Equatable, Sendable {
    var appliedLayout = false
    var appliedChapterTitleStyle = false
    var appliedRegexHighlights = false

    var isEmpty: Bool {
        !appliedLayout && !appliedChapterTitleStyle && !appliedRegexHighlights
    }

    var localizedDescription: String {
        var parts: [String] = []
        if appliedLayout { parts.append(localized("排版參數")) }
        if appliedChapterTitleStyle { parts.append(localized("章節標題樣式")) }
        if appliedRegexHighlights { parts.append(localized("正則高亮")) }
        guard !parts.isEmpty else { return localized("這個檔案沒有可匯入的內容。") }
        return String(
            format: localized("已匯入 %@。"),
            parts.joined(separator: localized("、"))
        )
    }
}
