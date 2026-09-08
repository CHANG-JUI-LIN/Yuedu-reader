import Foundation
import UIKit

extension AppearanceCustomizationBundle {
    /// Builds a bundle from already-translated parts rather than from a live snapshot.
    ///
    /// `QiThemeImportService` uses this so a foreign pack lands through the *same*
    /// `importAppearanceCustomization` path as one of our own bundles — including the
    /// ordering that path is careful about (themes before live page backgrounds, reader
    /// background mode last). Re-implementing that ordering in the Qi importer is exactly
    /// the second apply route this codebase keeps warning about.
    init(
        themes: [AppearanceThemeExportFile],
        pageBackgrounds: [String: PageBackgroundPayload]?,
        tabIcons: [TabIcon]?,
        launchImageLight: ImagePayload?,
        launchImageDark: ImagePayload?,
        readerBackground: ReaderBackground?
    ) {
        self.format = Self.formatIdentifier
        self.version = 1
        self.themes = themes
        self.pageBackgrounds = pageBackgrounds
        self.tabIcons = tabIcons
        self.launchImageLight = launchImageLight
        self.launchImageDark = launchImageDark
        self.readerBackground = readerBackground
        self.regexHighlightConfiguration = nil
        self.readerStyleAssetIDs = nil
        self.legacyDialogueHex = nil
    }
}

/// Applies a parsed QiReader `.qitheme` pack.
///
/// Lives in the app target because it has to touch app-level stores (`GlobalSettings`,
/// tab icons, fonts, covers) alongside `ReaderSettingsImportService`. It owns no parsing
/// and no storage of its own: `QiThemeImporter` understands the file, the existing import
/// functions do the writing, and this type only sequences them and reports what happened.
@MainActor
enum QiThemeImportService {
    struct Outcome {
        var appearance = AppearanceImportSummary()
        var reader: ReaderSettingsImportSummary?
        var installedFontName: String?
        var importedCoverCount = 0
        var notes: [String] = []

        /// One message covering both halves plus every lossy conversion, so the user can
        /// see what did and did not come across without opening a log.
        var localizedDescription: String {
            var parts: [String] = []
            if !appearance.isEmpty {
                parts.append(appearance.localizedDescription)
            }
            if let reader, !reader.isEmpty {
                parts.append(reader.localizedDescription)
            }
            if importedCoverCount > 0 {
                parts.append(String(
                    format: localized("已新增 %d 張預設封面（原有的封面仍保留）。"),
                    importedCoverCount
                ))
            }
            if let installedFontName {
                parts.append(String(format: localized("已安裝字型「%@」。"), installedFontName))
            }
            if parts.isEmpty {
                parts.append(localized("這個檔案沒有可匯入的內容。"))
            }
            guard !notes.isEmpty else { return parts.joined(separator: "\n") }
            return parts.joined(separator: "\n")
                + "\n\n"
                + localized("以下項目未完全套用：")
                + "\n"
                + notes.map { "• \($0)" }.joined(separator: "\n")
        }
    }

    static func load(_ data: Data) async throws -> QiThemeImport {
        try await QiThemeImporter.parse(data)
    }

    /// - Parameter includeOverlayLayout: false when the user declined to have their
    ///   hand-placed header/footer widgets replaced. Everything else still applies.
    @discardableResult
    static func apply(
        _ theme: QiThemeImport,
        includeOverlayLayout: Bool
    ) async throws -> Outcome {
        var theme = theme
        let settings = GlobalSettings.shared
        var outcome = Outcome()
        outcome.notes = theme.notes

        // 1. Everything the pack changes about the *look* becomes this theme's extras,
        //    so selecting another theme — 默認 included — puts the user's own settings
        //    back. Each asset is written through its storage manager directly rather
        //    than through the `GlobalSettings` mutators: those apply the value as they
        //    store it, which would land the pack's font and icons *before*
        //    `synchronizeAppearanceThemeExtras` captured what the user had.
        var extras = AppearanceThemeExtras()
        extras.tabIcons = storeTabIcons(theme)
        extras.tabIconSize = theme.tabIconSize.map(GlobalSettings.sanitizedRootTabIconSize)
        extras.hidesTabLabels = theme.hidesTabLabels
        extras.launchImageEnabled = theme.launchEnabled
        if let launch = theme.launchImage,
           let name = try? LaunchImageStorageManager.shared.importImage(
               data: launch.data,
               scheme: .light
           ) {
            // QiReader's splash is not per-appearance, so one file serves both slots.
            extras.launchImageLightFileName = name
            extras.launchImageDarkFileName = name
        }
        extras.defaultCoverLightFileNames = storeDefaultCovers(theme, outcome: &outcome)
        extras.forceDefaultCover = theme.bookshelf.forceDefaultCover
        extras.frostedGlass = theme.effects.frostedGlass
        extras.glassTransparency = theme.effects.glassTransparency
        extras.glowIntensity = theme.effects.glowIntensity
        extras.bookshelfGridColumnCount = theme.bookshelf.gridColumnCount
        extras.bookshelfCoverCornerRadius = theme.bookshelf.coverCornerRadius
        extras.readerInterface = theme.readerInterface?.rawValue
        extras.cardBackground = storeCardBackground(theme)

        if let font = theme.font {
            outcome.installedFontName = installFont(
                font,
                readerFontFamilyHint: theme.readerFontFamilyHint,
                settings: settings,
                outcome: &outcome,
                selectedPostScriptName: &extras.globalFontPostScript
            )
            if outcome.installedFontName == nil {
                outcome.notes.append(localized("外觀包附帶的字型無法安裝，已略過。"))
            }
        }

        // 2. Import the theme carrying those extras. Appending it selects it, and the
        //    selection is what captures the baseline and applies the extras.
        var themeFile = theme.themeFile
        themeFile?.extras = extras
        let bundle = AppearanceCustomizationBundle(
            themes: themeFile.map { [$0] } ?? [],
            pageBackgrounds: theme.pageBackgrounds.isEmpty ? nil : theme.pageBackgrounds,
            tabIcons: nil,
            launchImageLight: nil,
            launchImageDark: nil,
            readerBackground: readerBackgroundPayload(theme)
        )
        do {
            let encoded = try JSONEncoder().encode(bundle)
            outcome.appearance = try settings.importAppearanceCustomization(from: encoded)
        } catch {
            AppLogger.parse("⟐ qitheme appearance apply failed", context: ["error": "\(error)"])
            outcome.notes.append(localized("外觀部分套用失敗，其餘項目仍已匯入。"))
        }

        // 4b. Chapter-title faces the pack named but did not bundle. Runs *after* the font
        //     install above, so a title font that ships inside the pack is not flagged.
        substituteMissingChapterTitleFonts(&theme, outcome: &outcome)

        // 5. Reader half, through the one reader-settings apply path.
        outcome.reader = try applyReaderSettings(
            theme,
            includeOverlayLayout: includeOverlayLayout,
            outcome: &outcome
        )

        // 6. Comment bubble.
        if let bubble = theme.bubble {
            settings.upsertCommentBubbleCustomStyle(bubble.style)
            settings.commentBubbleFollowsSourceSVG = false
            if let scale = bubble.scale { settings.commentBubbleScale = scale }
            if let textScale = bubble.textScale { settings.commentBubbleTextScale = textScale }
        }

        return outcome
    }

    // MARK: - Pieces

    private static func applyReaderSettings(
        _ theme: QiThemeImport,
        includeOverlayLayout: Bool,
        outcome: inout Outcome
    ) throws -> ReaderSettingsImportSummary? {
        var layout: ReaderLayoutPreset?
        if let config = theme.layoutConfig {
            do {
                layout = try ReaderLayoutPresetImporter.decode(data: config)
            } catch {
                AppLogger.parse("⟐ qitheme layout decode failed", context: ["error": "\(error)"])
                outcome.notes.append(localized("排版參數無法讀取，其餘項目仍已匯入。"))
            }
        }
        if !includeOverlayLayout, let existing = layout, existing.readerOverlayLayout != nil {
            layout = ReaderLayoutPreset(
                name: existing.name,
                fontSize: existing.fontSize,
                isBold: existing.isBold,
                lineHeightMultiple: existing.lineHeightMultiple,
                letterSpacing: existing.letterSpacing,
                paragraphSpacingMultiplier: existing.paragraphSpacingMultiplier,
                pageMarginH: existing.pageMarginH,
                pageMarginV: existing.pageMarginV,
                footerBottomPadding: existing.footerBottomPadding,
                footerTextGap: existing.footerTextGap,
                titleVisible: existing.titleVisible,
                titleSize: existing.titleSize,
                titleTopSpacing: existing.titleTopSpacing,
                titleBottomSpacing: existing.titleBottomSpacing,
                pageTurnStyle: existing.pageTurnStyle,
                scrollMode: existing.scrollMode,
                readerOverlayLayout: nil
            )
            outcome.notes.append(localized("已略過外觀包的頁首頁尾版面，保留原本的設定。"))
        }
        let plan = ReaderSettingsImportPlan(
            layout: layout,
            chapterTitleStyle: theme.chapterTitleStyle,
            regexHighlights: nil,
            dialogueBubbleStyle: nil,
            contentName: theme.name
        )
        guard !plan.isEmpty else { return nil }
        return try ReaderSettingsImportService.apply(plan)
    }

    /// Stores each tab icon and returns the `"<tab>.<slot>"` map the extras carry.
    /// One artwork per tab, written to both slots: QiReader has no light/dark split,
    /// and leaving dark on the default SF Symbol looks like a half-applied theme.
    private static func storeTabIcons(_ theme: QiThemeImport) -> [String: String]? {
        var icons: [String: String] = [:]
        for icon in theme.tabIcons {
            guard let tab = RootTabItem(rawValue: icon.tabID) else { continue }
            for slot in RootTabIconSlot.allCases {
                guard let asset = try? RootTabIconStorageManager.shared.importIcon(
                    data: icon.image.data,
                    originalFileName: icon.image.fileName,
                    tab: tab,
                    slot: slot
                ) else { continue }
                icons["\(tab.rawValue).\(slot.rawValue)"] = asset.fileName
            }
        }
        return icons.isEmpty ? nil : icons
    }

    private static func storeDefaultCovers(
        _ theme: QiThemeImport,
        outcome: inout Outcome
    ) -> [String]? {
        var names: [String] = []
        for cover in theme.defaultCovers {
            guard let name = try? DefaultCoverStorageManager.shared.importImage(
                data: cover.data,
                scheme: .light
            ) else { continue }
            names.append(name)
        }
        outcome.importedCoverCount = names.count
        return names.isEmpty ? nil : names
    }

    private static func storeCardBackground(_ theme: QiThemeImport) -> AppearanceCardBackground? {
        guard let card = theme.cardBackground else { return nil }
        var light = card.light
        var dark = card.dark
        if let data = theme.cardBackgroundImage?.data,
           let name = try? AppearanceCardBackgroundImageStore.shared.importImage(data: data) {
            light.imageFileName = name
        }
        if let data = theme.darkCardBackgroundImage?.data,
           let name = try? AppearanceCardBackgroundImageStore.shared.importImage(data: data) {
            dark.imageFileName = name
        }
        let resolved = AppearanceCardBackground(isEnabled: card.isEnabled, light: light, dark: dark)
        return resolved.isEmpty ? nil : resolved
    }

    private static func installFont(
        _ font: QiThemeImport.FontImport,
        readerFontFamilyHint: String?,
        settings: GlobalSettings,
        outcome: inout Outcome,
        selectedPostScriptName: inout String?
    ) -> String? {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("qitheme-font-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard (try? FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }
        let fileURL = staging.appendingPathComponent(font.originalFileName, isDirectory: false)
        // Installed into the library but *not* selected — the theme's extras decide
        // when it is in use, so the baseline still captures the user's own choice.
        guard (try? font.data.write(to: fileURL, options: .atomic)) != nil,
              let info = try? settings.importUserFont(from: fileURL) else {
            return nil
        }
        selectedPostScriptName = info.postScriptName
        // The reading preset names its own face. When it is the one bundled here, adopt it
        // as the reader font too; when it names a font the pack did not ship, say so rather
        // than silently pointing the reader at the wrong face.
        let requested = readerFontFamilyHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty,
           requested.compare(info.postScriptName, options: .caseInsensitive) != .orderedSame,
           requested.compare(info.familyName, options: .caseInsensitive) != .orderedSame {
            outcome.notes.append(String(
                format: localized("閱讀字型「%@」未隨外觀包附帶，正文仍使用原本的字型。"),
                requested
            ))
        } else {
            settings.selectedReaderFontPostScript = info.postScriptName
        }
        return info.displayName
    }

    /// A chapter-title style can name faces the pack never shipped — 江湖侠客 asks for two
    /// (`YUWEIXSJ2019`, `KyoMadoka`) it does not include.
    ///
    /// Leaving the dead name in place is worse than clearing it: `UserReaderFontResolver`
    /// resolves `postScriptName ?? selectedPostScriptName`, so an *unavailable* name falls
    /// all the way through to `UIFont.systemFont` and never reaches the reader's own font —
    /// a 武俠 ink-painting title rendered in system sans. Clearing it lets the layer inherit
    /// the reader font, which for a pack like this is the serif it just installed: much
    /// closer to what the author drew the artwork around. The substitution is reported, so
    /// it is never a silent change of appearance.
    private static func substituteMissingChapterTitleFonts(
        _ theme: inout QiThemeImport,
        outcome: inout Outcome
    ) {
        guard var style = theme.chapterTitleStyle, !style.followsBodyFont else { return }
        func isMissing(_ name: String?) -> Bool {
            guard let name, !name.isEmpty else { return false }
            return UIFont(name: name, size: 12) == nil
        }

        var missing: Set<String> = []
        for name in [style.nameFontPostScript, style.numberFontPostScript] where isMissing(name) {
            missing.insert(name!)
        }
        for layer in style.design?.layers ?? [] {
            for name in [
                layer.lightStyle.ruleStyle.text.fontPostScriptName,
                layer.darkStyle.ruleStyle.text.fontPostScriptName,
            ] where isMissing(name) {
                missing.insert(name!)
            }
        }
        guard !missing.isEmpty else { return }

        if isMissing(style.nameFontPostScript) { style.nameFontPostScript = nil }
        if isMissing(style.numberFontPostScript) { style.numberFontPostScript = nil }
        if var design = style.design {
            for index in design.layers.indices {
                if isMissing(design.layers[index].lightStyle.ruleStyle.text.fontPostScriptName) {
                    design.layers[index].lightStyle.ruleStyle.text.fontPostScriptName = nil
                }
                if isMissing(design.layers[index].darkStyle.ruleStyle.text.fontPostScriptName) {
                    design.layers[index].darkStyle.ruleStyle.text.fontPostScriptName = nil
                }
            }
            style.design = design
        }
        theme.chapterTitleStyle = style.sanitized()

        outcome.notes.append(String(
            format: localized("章節標題使用的字型未隨外觀包附帶：%@，已改用閱讀字型顯示。"),
            missing.sorted().joined(separator: localized("、"))
        ))
    }

    private static func readerBackgroundPayload(
        _ theme: QiThemeImport
    ) -> AppearanceCustomizationBundle.ReaderBackground? {
        guard let image = theme.readerBackground, let payload = imagePayload(image) else { return nil }
        return AppearanceCustomizationBundle.ReaderBackground(
            mode: ReaderCustomBackgroundMode.image.rawValue,
            colorHex: nil,
            image: payload
        )
    }

    private static func imagePayload(
        _ file: QiThemeImport.ImageFile?
    ) -> AppearanceThemeExportFile.ImagePayload? {
        guard let file else { return nil }
        return AppearanceThemeExportFile.ImagePayload(
            fileExtension: (file.fileName as NSString).pathExtension,
            base64: file.data.base64EncodedString()
        )
    }
}
