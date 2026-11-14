import Foundation
import UniformTypeIdentifiers

/// What a file picked by 匯入閱讀設定 turned out to contain, before anything is
/// written. Loading and applying are separate so replacing the reading setup can
/// be confirmed with the user *after* the file parsed and *before* it lands.
struct ReaderSettingsImportPlan {
    var layout: ReaderLayoutPreset?
    var chapterTitleStyle: ChapterTitleStyle?
    var regexHighlights: RegexHighlightConfiguration?
    var dialogueBubbleStyle: ReaderDialogueBubbleStyle?
    /// Name carried by a file that has no layout preset to name it — currently
    /// the `nm` of an imported Lottie title template.
    var contentName: String?
    /// What the file asked for but could not be reproduced exactly. Reported
    /// alongside the success message so a lossy conversion is never silent.
    var notes: [String] = []

    // A version-2 匯出閱讀設定 file (`ReaderSettingsBundle`): the whole setup, and the
    // library items it names. Empty for every other file.

    /// The page look, every field filled in. When set it is the setup, and `layout` is nil:
    /// one source per field.
    var fullReadingSettings: AppearanceThemeReadingSettings?
    var behavior: ReaderBehaviorSettings?
    var readerBackgrounds: [ImportedReaderBackground] = []
    var commentBubbleStyle: ReaderCommentBubbleCustomStyle?
    var fonts: [ImportedFont] = []

    struct ImportedReaderBackground {
        var background: ReaderSettingsBundle.ReaderBackground
        var imageData: Data?
    }

    struct ImportedFont {
        var postScriptName: String
        var fileExtension: String
        var data: Data
    }

    var isEmpty: Bool {
        layout == nil && chapterTitleStyle == nil && regexHighlights == nil
            && dialogueBubbleStyle == nil && fullReadingSettings == nil
            && (behavior?.isEmpty ?? true)
    }

    /// Whether applying this replaces the reading setup — type, spacing, page turn and the
    /// rest — and so is confirmed first. A page's own 匯入 (章節標題、正則高亮、對話氣泡)
    /// never does and changes only what that page is about.
    var replacesReadingSetup: Bool {
        layout != nil || fullReadingSettings != nil || !(behavior?.isEmpty ?? true)
    }

    var name: String? {
        let candidate = layout?.name ?? contentName
        return candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReaderSettingsImportError: LocalizedError {
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return localized("這個檔案沒有可匯入的內容。")
        }
    }
}

/// The single route every 閱讀設定 import takes — the 匯入閱讀設定 button, the
/// 正則高亮 ⋯ menu, and the older 匯入排版參數 file all land here.
///
/// Deliberately one entry point: layout parameters are parsed only by
/// `ReaderLayoutPresetImporter`, styles only by `ReaderStylePackage`. A second
/// parse route is how two files that look identical start importing differently.
@MainActor
enum ReaderSettingsImportService {
    static let readerSettingsContentTypes: [UTType] = [
        .yueduReaderStyle,
        .json,
        UTType(filenameExtension: "zip") ?? .data,
        .data,
    ]

    static let styleContentTypes: [UTType] = [.yueduReaderStyle, .json, .plainText, .data]

    /// Accepts every style file the app writes plus legado's `readConfig.json` /
    /// `.zip`. A `.yuedustyle` holding only one half (章節標題樣式 or 正則高亮) is
    /// accepted here too — the user picked it, and refusing a file we authored
    /// because it is "the wrong kind of ours" is not a useful failure.
    static func loadReaderSettings(from url: URL) async throws -> ReaderSettingsImportPlan {
        guard url.pathExtension.lowercased() == "yuedustyle" else {
            let data = try Data(contentsOf: url)
            // Another reader's highlight-rule pack: only its rules, merged into the user's.
            if let format = HighlightPackImporter.format(fileExtension: url.pathExtension, data: data) {
                return try await HighlightPackImportService.plan(
                    data,
                    format: format,
                    fallbackName: url.deletingPathExtension().lastPathComponent
                )
            }
            // Checked before the chapter-title probe: a Lottie document shares
            // none of its keys, but both end up as a 章節標題樣式 and only one
            // decoder can be right for a given file.
            // Checked first: a bubble script is a `{ name, script … }` document
            // whose `name` would otherwise satisfy the layout-preset decoder.
            if DialogueBubbleScriptImporter.looksLikeBubbleScript(data) {
                let imported = try await DialogueBubbleScriptImporter.import(
                    data,
                    assetStore: .shared
                )
                return ReaderSettingsImportPlan(
                    layout: nil,
                    chapterTitleStyle: nil,
                    regexHighlights: nil,
                    dialogueBubbleStyle: imported.style,
                    contentName: imported.name,
                    notes: imported.notes
                )
            }
            if LottieTitleTemplateImporter.looksLikeTitleTemplate(data) {
                let imported = try await LottieTitleTemplateImporter.import(
                    data,
                    assetStore: .shared
                )
                return ReaderSettingsImportPlan(
                    layout: nil,
                    chapterTitleStyle: imported.style,
                    regexHighlights: nil,
                    dialogueBubbleStyle: nil,
                    contentName: imported.templateName,
                    notes: imported.notes
                )
            }
            if looksLikeChapterTitleJSON(data) {
                return ReaderSettingsImportPlan(
                    layout: nil,
                    chapterTitleStyle: try ReaderStylePackage.decodeLegacyChapterTitleJSON(data),
                    regexHighlights: nil
                )
            }
            return ReaderSettingsImportPlan(
                layout: try await ReaderLayoutPresetImporter.importPreset(from: url),
                chapterTitleStyle: nil,
                regexHighlights: nil
            )
        }

        let contents = try await ReaderStylePackage.importContents(
            try Data(contentsOf: url),
            assetStore: .shared
        )
        return try plan(from: contents.payload, attachments: contents.attachments)
    }

    static func plan(
        from payload: ReaderStylePackagePayload,
        attachments: [String: ReaderStylePackageAttachment] = [:]
    ) throws -> ReaderSettingsImportPlan {
        switch payload.kind {
        case .readerSettings:
            let bundle = try payload.decode(ReaderSettingsBundle.self)
            if bundle.readingSettings != nil || bundle.behavior != nil {
                return try fullPlan(from: bundle, attachments: attachments)
            }
            return ReaderSettingsImportPlan(
                layout: try bundle.decodedLayoutPreset(),
                chapterTitleStyle: bundle.chapterTitleStyle?.sanitized(),
                regexHighlights: bundle.regexHighlights?.sanitized()
            )
        case .chapterTitle:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: try payload.decode(ChapterTitleStyle.self).sanitized(),
                regexHighlights: nil
            )
        case .regexHighlights:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: nil,
                regexHighlights: try payload.decode(RegexHighlightConfiguration.self).sanitized()
            )
        case .appearance:
            throw ReaderStylePackageError.unexpectedKind(
                expected: .readerSettings,
                actual: .appearance
            )
        }
    }

    /// A version-2 file: its `readingSettings` is the setup, and `layoutConfig` (kept for
    /// older builds) is read only for the setup's name. The file is shared and untrusted,
    /// so the styles go through the same `sanitized()` every other import uses, and a
    /// library item naming an attachment the package does not hold fails the import.
    private static func fullPlan(
        from bundle: ReaderSettingsBundle,
        attachments: [String: ReaderStylePackageAttachment]
    ) throws -> ReaderSettingsImportPlan {
        func attachment(_ id: String) throws -> ReaderStylePackageAttachment {
            guard let value = attachments[id] else { throw ReaderStylePackageError.malformedManifest }
            return value
        }

        let reading = bundle.readingSettings.map { original in
            var value = original
            value.chapterTitleStyle = original.chapterTitleStyle?.sanitized()
            value.regexHighlights = original.regexHighlights?.sanitized()
            value.dialogueBubbleStyle = original.dialogueBubbleStyle?.sanitized()
            return value
        }

        var plan = ReaderSettingsImportPlan(
            layout: nil,
            chapterTitleStyle: reading?.chapterTitleStyle,
            regexHighlights: reading?.regexHighlights,
            dialogueBubbleStyle: reading?.dialogueBubbleStyle,
            contentName: try bundle.decodedLayoutPreset()?.name
        )
        plan.fullReadingSettings = reading
        plan.behavior = bundle.behavior?.sanitized()
        plan.readerBackgrounds = try (bundle.readerBackgrounds ?? []).map { background in
            ReaderSettingsImportPlan.ImportedReaderBackground(
                background: background,
                imageData: try background.imageAttachmentID.map { try attachment($0).data }
            )
        }
        // Only the bubble the setup wears; any other entry would be a library change the
        // file never showed.
        if let style = bundle.commentBubbleStyle,
           reading?.commentBubble?.customStyleID == style.id {
            plan.commentBubbleStyle = style
        }
        plan.fonts = try (bundle.fonts ?? []).map { font in
            let file = try attachment(font.attachmentID)
            return ReaderSettingsImportPlan.ImportedFont(
                postScriptName: font.postScriptName,
                fileExtension: file.fileExtension,
                data: file.data
            )
        }
        return plan
    }

    /// Both `ChapterTitleStyle` and legado's `readConfig.json` decode every field
    /// with `decodeIfPresent`, so **either** decoder accepts **any** JSON object
    /// and silently returns a full set of defaults. A bare `.json` therefore has
    /// to be told apart by the keys it carries, not by which decoder throws —
    /// otherwise importing a 章節標題樣式 file quietly resets the type size to 18pt.
    nonisolated static func looksLikeChapterTitleJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let keys = Set(object.keys)
        // Keys unique to one schema. Anything both share (there is nothing today)
        // must stay out of both sets.
        let titleKeys: Set<String> = [
            "visible", "topSpacing", "bottomSpacing", "weight", "alignment",
            "followsBodyFont", "splitEnabled", "numberRelativeSize",
            "numberFontPostScript", "nameFontPostScript",
            "advancedCSSEnabled", "lightTemplate", "darkTemplate", "design",
        ]
        let layoutKeys: Set<String> = [
            "textSize", "textBold", "lineSpacingExtra", "paragraphSpacing",
            "paddingLeft", "paddingRight", "paddingTop", "paddingBottom",
            "pageAnim", "headerMode", "readerOverlayLayout",
        ]
        return !titleKeys.isDisjoint(with: keys) && layoutKeys.isDisjoint(with: keys)
    }

    /// Writes the plan into the reader's current setup through the one reading-setup
    /// writer that theme switches use too. It lands like an edit, setting by setting:
    /// on the worn theme for what 排版生效範圍 lets follow the theme, in 全域 for the rest.
    ///
    /// A version-2 file's library items go in first — fonts, saved backgrounds, the custom
    /// comment bubble — so the setup that names them finds them. Its behaviour rows go in
    /// last and only here: they never follow a theme.
    @discardableResult
    static func apply(_ plan: ReaderSettingsImportPlan) throws -> ReaderSettingsImportSummary {
        guard !plan.isEmpty else { throw ReaderSettingsImportError.emptyFile }
        let settings = GlobalSettings.shared
        // Before anything is written: a font that will not install fails the import whole,
        // rather than leaving a setup that reads in a different face than it says.
        try installFonts(plan.fonts, into: settings)
        for item in plan.readerBackgrounds {
            settings.restoreSavedReaderBackground(
                id: item.background.id,
                name: item.background.name,
                colorHex: item.background.colorHex,
                textColorHex: item.background.textColorHex,
                isDark: item.background.isDark,
                imageData: item.imageData
            )
        }
        if let style = plan.commentBubbleStyle {
            settings.storeCommentBubbleCustomStyle(style)
        }
        try settings.writeReadingSettings(plan.readingSettings, origin: .userImport)
        if let behavior = plan.behavior {
            settings.applyReaderBehaviorSettings(behavior)
        }

        var summary = ReaderSettingsImportSummary()
        summary.appliedLayout = plan.layout != nil || plan.fullReadingSettings != nil
        summary.appliedChapterTitleStyle = plan.chapterTitleStyle != nil
        summary.appliedRegexHighlights = plan.regexHighlights != nil
        summary.appliedDialogueBubbleStyle = plan.dialogueBubbleStyle != nil
        summary.appliedBehavior = !(plan.behavior?.isEmpty ?? true)
        return summary
    }

    /// Adds each font the receiving library lacks. One it already holds under the same
    /// PostScript name is left as it is: `importUserFont` would replace it with an
    /// identical copy.
    private static func installFonts(
        _ fonts: [ReaderSettingsImportPlan.ImportedFont],
        into settings: GlobalSettings
    ) throws {
        let installed = Set(settings.userFonts.map(\.postScriptName))
        for font in fonts where !installed.contains(font.postScriptName) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("reader-settings-font-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    // A temporary copy left behind changes nothing the import did.
                    AppLogger.error("⟐ imported font temp copy not removed", error: error)
                }
            }
            let fileURL = directory
                .appendingPathComponent("font")
                .appendingPathExtension(font.fileExtension)
            try font.data.write(to: fileURL, options: .atomic)
            try settings.importUserFont(from: fileURL)
        }
    }
}

extension ReaderSettingsImportPlan {
    /// The plan as a reading setup: what 取代目前設定 writes live, and what
    /// 隨主題切換 stores on the imported theme. The one place a layout preset is
    /// translated into settings.
    var readingSettings: AppearanceThemeReadingSettings {
        if let fullReadingSettings { return fullReadingSettings }
        var reading = AppearanceThemeReadingSettings()
        if let preset = layout {
            // Native presets retain both page scopes and every margin. Older presets
            // and external theme packs still enter through the coordinate migration.
            // Normalized the way storing it normalizes, so the stored value compares
            // equal to what the reader ends up wearing.
            reading.barLayout = (preset.readerBarLayout
                ?? preset.readerOverlayLayout.map(ReaderBarLayoutMigration.snap))?
                .normalized(preservingVersion: false)
            reading.fontSize = preset.fontSize.map(Double.init)
            reading.isBold = preset.isBold
            reading.lineHeightMultiple = preset.lineHeightMultiple.map(Double.init)
            reading.letterSpacing = preset.letterSpacing.map(Double.init)
            reading.paragraphSpacingMultiplier = preset.paragraphSpacingMultiplier.map(Double.init)
            reading.pageMarginH = preset.pageMarginH.map(Double.init)
            reading.pageMarginV = preset.pageMarginV.map(Double.init)
            reading.pageMarginTop = (preset.pageMarginTop ?? preset.pageMarginV).map(Double.init)
            reading.pageMarginBottom = (preset.pageMarginBottom ?? preset.pageMarginV).map(Double.init)
            reading.scrollMode = preset.scrollMode
            // Scroll mode outranks the page animation, as in legado's `pageAnim`.
            if preset.scrollMode != true {
                reading.pageTurnStyle = preset.pageTurnStyle?.rawValue
            }
            // The preset's loose title fields are not carried: the renderer reads only
            // `ChapterTitleStyle`, and those keys survive solely as a one-time migration
            // source (`GlobalSettings.loadChapterTitleStyle`).
        }
        reading.chapterTitleStyle = chapterTitleStyle
        reading.regexHighlights = regexHighlights
        reading.dialogueBubbleStyle = dialogueBubbleStyle
        return reading
    }
}

enum ReaderOverlayLayoutPersistenceError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        localized("無法儲存頁首頁尾設定")
    }
}

/// The cheap main-actor value read a 匯出閱讀設定 archive is built from — values and
/// file locations, no encoding and no disk I/O here. `ReaderSettingsExportFile` does the
/// work off it, where a failure can surface instead of being swallowed.
struct ReaderSettingsExportInputs: Sendable {
    struct FontFile: Sendable {
        var postScriptName: String
        var url: URL
    }

    var layout: ReaderLayoutSnapshot
    var chapterTitleStyle: ChapterTitleStyle
    var regexHighlights: RegexHighlightConfiguration
    var readingSettings: AppearanceThemeReadingSettings?
    var behavior: ReaderBehaviorSettings?
    /// The saved backgrounds the setup names, with where each one's picture is.
    var readerBackgrounds: [ReaderCustomBackground] = []
    var readerBackgroundPictureURLs: [UUID: URL] = [:]
    var commentBubbleStyle: ReaderCommentBubbleCustomStyle?
    var fontFiles: [FontFile] = []

    func makeBundle() throws -> ReaderSettingsBundle {
        try makePackage().bundle
    }

    /// The bundle and the files it names, read from disk now.
    func makePackage() throws -> (bundle: ReaderSettingsBundle, attachments: [ReaderStylePackageAttachment]) {
        var attachments: [ReaderStylePackageAttachment] = []

        let backgrounds = try readerBackgrounds.map { background in
            var imageAttachmentID: String?
            if let url = readerBackgroundPictureURLs[background.id] {
                let id = "background.\(background.id.uuidString.lowercased())"
                attachments.append(ReaderStylePackageAttachment(
                    id: id,
                    fileExtension: url.pathExtension.lowercased(),
                    data: try Data(contentsOf: url)
                ))
                imageAttachmentID = id
            }
            return ReaderSettingsBundle.ReaderBackground(
                id: background.id,
                name: background.name,
                colorHex: background.colorHex,
                textColorHex: background.textColorHex,
                isDark: background.isDark,
                imageAttachmentID: imageAttachmentID
            )
        }

        let fonts = try fontFiles.enumerated().map { index, font in
            let id = "font.\(index)"
            attachments.append(ReaderStylePackageAttachment(
                id: id,
                fileExtension: font.url.pathExtension.lowercased(),
                data: try Data(contentsOf: font.url)
            ))
            return ReaderSettingsBundle.Font(postScriptName: font.postScriptName, attachmentID: id)
        }

        let bundle = ReaderSettingsBundle(
            layoutConfig: try ReaderLayoutPresetExporter.encode(layout),
            chapterTitleStyle: chapterTitleStyle,
            regexHighlights: regexHighlights,
            readingSettings: readingSettings,
            behavior: behavior,
            readerBackgrounds: backgrounds.isEmpty ? nil : backgrounds,
            commentBubbleStyle: commentBubbleStyle,
            fonts: fonts.isEmpty ? nil : fonts
        )
        return (bundle, attachments)
    }
}

@MainActor
enum ReaderSettingsExportSnapshot {
    static func make() -> ReaderSettingsExportInputs {
        let settings = GlobalSettings.shared
        let readerConfig = ReaderConfig.shared
        let style = readerConfig.chapterTitleStyle
        let snapshot = ReaderLayoutSnapshot(
            name: localized("閱讀設定"),
            fontSize: readerConfig.fontSize,
            isBold: readerConfig.readerFontBold,
            lineHeightMultiple: readerConfig.lineHeightMultiple,
            letterSpacing: readerConfig.letterSpacing,
            paragraphSpacingMultiplier: readerConfig.paragraphSpacingMultiplier,
            pageMarginH: readerConfig.pageMarginH,
            pageMarginV: readerConfig.pageMarginV,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap,
            titleVisible: style.visible,
            titleSize: style.size,
            titleTopSpacing: style.topSpacing,
            titleBottomSpacing: style.bottomSpacing,
            pageTurnStyle: settings.pageTurnStyle,
            scrollMode: settings.scrollMode,
            // Rendered out of the bar layout rather than read from the stored
            // free-position one, which no longer reflects what the reader draws.
            readerOverlayLayout: ReaderBarLayoutMigration.freePositionLayout(
                from: settings.readerBarLayout
            ),
            pageMarginTop: readerConfig.pageMarginTop,
            pageMarginBottom: readerConfig.pageMarginBottom,
            readerBarLayout: settings.readerBarLayout
        )
        let reading = settings.currentReadingSettingsSnapshot()

        var inputs = ReaderSettingsExportInputs(
            layout: snapshot,
            chapterTitleStyle: style,
            regexHighlights: settings.regexHighlightConfiguration,
            readingSettings: reading,
            behavior: settings.currentReaderBehaviorSettings
        )

        // The saved backgrounds the setup wears: the reader's own pick and the two
        // 綁定閱讀主題 picks, each once.
        var backgroundIDs: [UUID] = []
        if let raw = reading.readerBackgroundID, let id = UUID(uuidString: raw) {
            backgroundIDs.append(id)
        }
        for raw in [reading.boundLightReaderTheme, reading.boundDarkReaderTheme] {
            if let raw, case .custom(let id) = ReaderBoundTheme(storageValue: raw) {
                backgroundIDs.append(id)
            }
        }
        var seenBackgrounds: Set<UUID> = []
        for id in backgroundIDs where seenBackgrounds.insert(id).inserted {
            guard let background = settings.readerCustomBackground(id: id) else { continue }
            inputs.readerBackgrounds.append(background)
            guard let fileName = background.imageFileName, !fileName.isEmpty else { continue }
            do {
                inputs.readerBackgroundPictureURLs[id] = try ReaderCustomBackgroundStorageManager.shared
                    .fileURL(fileName: fileName)
            } catch {
                AppLogger.error("⟐ reading settings export: background picture unreachable", error: error, context: [
                    "name": background.name,
                ])
            }
        }

        if reading.commentBubble?.presetMode == ReaderCommentBubblePresetMode.custom.rawValue,
           let id = reading.commentBubble?.customStyleID {
            inputs.commentBubbleStyle = settings.commentBubbleCustomStyles.first { $0.id == id }
        }

        // Only imported fonts travel; a system face is on every device already.
        for name in ReaderStyleFontReferences.postScriptNames(in: reading) {
            guard let font = settings.userFonts.first(where: { $0.postScriptName == name }) else { continue }
            do {
                inputs.fontFiles.append(.init(
                    postScriptName: name,
                    url: try UserFontStorageManager.shared.fileURL(for: font)
                ))
            } catch {
                AppLogger.error("⟐ reading settings export: font file unreachable", error: error, context: [
                    "font": name,
                ])
            }
        }
        return inputs
    }
}
