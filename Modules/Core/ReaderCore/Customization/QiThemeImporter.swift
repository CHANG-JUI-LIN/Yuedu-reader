import CoreGraphics
import Foundation
import ImageIO
import ReadiumZIPFoundation

enum QiThemeImportError: Error, LocalizedError, Equatable {
    case notAQiTheme
    case malformedArchive
    case malformedNestedPayload
    case tooManyFiles(Int)
    case expandedDataTooLarge(Int)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .notAQiTheme:
            return localized("這不是可讀取的 QiReader 外觀包。")
        case .malformedArchive, .malformedNestedPayload:
            return localized("外觀包內容損毀，無法讀取。")
        case .tooManyFiles, .expandedDataTooLarge:
            return localized("外觀包過大，無法安全解壓。")
        case .unsafePath:
            return localized("外觀包含有不安全的檔案路徑，已停止匯入。")
        }
    }
}

/// Everything one `.qitheme` could be translated into, expressed purely in our own
/// models. Assembling and *applying* it is the app target's job (`QiThemeImportService`);
/// this type is the boundary between "understood the foreign file" and "changed the app".
struct QiThemeImport: Sendable {
    struct ImageFile: Sendable {
        var data: Data
        var fileName: String
    }

    struct TabIconImport: Sendable {
        /// Our `RootTabItem` id.
        var tabID: String
        var image: ImageFile
    }

    struct FontImport: Sendable {
        var data: Data
        var originalFileName: String
        /// The manifest's `fontFamily`. Only a hint: the real PostScript name is read
        /// from the TTF at install time, because that is what selection keys on.
        var declaredPostScriptName: String?
    }

    struct InterfaceEffects: Sendable {
        var frostedGlass: Bool?
        var glassTransparency: Double?
        var glowIntensity: Double?
    }

    struct BookshelfSettings: Sendable {
        var gridColumnCount: Int?
        var coverCornerRadius: Double?
        var forceDefaultCover: Bool?
    }

    struct BubbleImport: Sendable {
        var style: ReaderCommentBubbleCustomStyle
        var scale: Double?
        var textScale: Double?
    }

    var name: String
    var themeFile: AppearanceThemeExportFile?
    var pageBackgrounds: [String: AppearanceThemeExportFile.PageBackgroundPayload] = [:]
    var tabIcons: [TabIconImport] = []
    var tabIconSize: Double?
    var hidesTabLabels: Bool?
    var defaultCovers: [ImageFile] = []
    var launchImage: ImageFile?
    var launchEnabled: Bool?
    var font: FontImport?
    var effects = InterfaceEffects()
    var bookshelf = BookshelfSettings()
    var readerInterface: AppearanceReaderInterface?
    /// legado `readConfig.json` bytes, so the layout half goes through the app's one
    /// layout parser instead of a second one written for QiReader.
    var layoutConfig: Data?
    var chapterTitleStyle: ChapterTitleStyle?
    var overlayLayout: ReaderOverlayLayout?
    var bubble: BubbleImport?
    var readerBackground: ImageFile?
    /// Card artwork geometry; the image *bytes* travel beside it because the file
    /// names are only known once the app target has stored them.
    var cardBackground: AppearanceCardBackground?
    var cardBackgroundImage: ImageFile?
    var darkCardBackgroundImage: ImageFile?
    /// The reading page's font family, as declared by the preset. Compared against the
    /// bundled font before that font is adopted as the reader font.
    var readerFontFamilyHint: String?
    /// What the pack asked for but we could not reproduce. Reported to the user.
    var notes: [String] = []
}

/// Reads QiReader's `.qitheme` appearance packs and translates them into our models.
///
/// Follows the same shape as the app's other third-party compatibility layers
/// (`ReaderLayoutPresetImporter` for legado, `LottieTitleTemplateImporter` for Bodymovin,
/// `DialogueBubbleScriptImporter` for bubble scripts): convert to native models here, and
/// let the existing apply paths do the writing. Nothing in this file changes app state
/// except the style-asset store, which has to mint IDs for chapter-title artwork before
/// the layers referencing them can be built.
enum QiThemeImporter {
    /// `.qitheme` archives seen in the wild hold ~23 entries; the reader preset adds a
    /// handful more. Generous, but still bounded.
    static let maximumFileCount = 512
    /// Matches `ReaderStylePackage`. The largest real pack expands to ~33MB, almost all
    /// of it one 24MB font.
    static let maximumExpandedBytes = 100 * 1_024 * 1_024

    // MARK: - Detection

    static func hasQiThemeExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "qitheme"
    }

    // MARK: - Parsing

    static func parse(_ archiveData: Data) async throws -> QiThemeImport {
        guard archiveData.count <= maximumExpandedBytes else {
            throw QiThemeImportError.expandedDataTooLarge(archiveData.count)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("qitheme-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let archiveURL = staging.appendingPathComponent("source.qitheme", isDirectory: false)
        try archiveData.write(to: archiveURL, options: .atomic)

        let contentRoot = staging.appendingPathComponent("contents", isDirectory: true)
        let paths = try await extractArchive(at: archiveURL, into: contentRoot)

        // The whole pack lives under a single UUID-named directory; a `manifest.json` at
        // the archive root means this is some other format (ours, for one).
        guard let packRoot = singleTopLevelDirectory(in: paths) else {
            throw QiThemeImportError.notAQiTheme
        }
        let rootURL = contentRoot.appendingPathComponent(packRoot, isDirectory: true)
        let manifestURL = rootURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw QiThemeImportError.notAQiTheme
        }
        guard let manifest = try? JSONDecoder().decode(QiThemeManifest.self, from: manifestData),
              manifest.id != nil, manifest.name != nil else {
            throw QiThemeImportError.notAQiTheme
        }

        var notes: [String] = []
        var result = QiThemeImport(
            name: manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? localized("QiReader 外觀包")
        )

        applyAppearance(manifest, rootURL: rootURL, into: &result, notes: &notes)
        await applyReaderPreset(rootURL: rootURL, into: &result, notes: &notes)

        result.notes = notes
        return result
    }

    // MARK: - App-level appearance

    private static func applyAppearance(
        _ manifest: QiThemeManifest,
        rootURL: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) {
        // Page backgrounds — the one part that is field-for-field identical to ours.
        var backgrounds: [String: AppearanceThemeExportFile.PageBackgroundPayload] = [:]
        if let global = manifest.defaultBackground {
            backgrounds[AppearancePageBackgroundScope.global.rawValue] =
                backgroundPayload(global, rootURL: rootURL)
        }
        for (tab, background) in manifest.tabBackgrounds ?? [:] {
            guard let scope = AppearancePageBackgroundScope(rawValue: tab) else {
                notes.append(String(format: localized("背景「%@」在本 App 沒有對應的頁面，已略過。"), tab))
                continue
            }
            backgrounds[scope.rawValue] = backgroundPayload(background, rootURL: rootURL)
        }
        result.pageBackgrounds = backgrounds

        // Colors. The accent and the three text levels map; the five surface colours do
        // not, so they stay at our defaults rather than being guessed from a gradient.
        let accent = QiThemeValue.hex(manifest.accentColorHex)
        result.themeFile = AppearanceThemeExportFile(
            format: AppearanceThemeExportFile.formatIdentifier,
            version: 1,
            name: result.name,
            backgroundHex: 0xF4F5F7,
            textHex: 0x333333,
            barHex: 0xFFFFFF,
            accentHex: accent ?? 0x007AFF,
            dialogueHex: 0xD8E9FB,
            pageBackgrounds: backgrounds.isEmpty ? nil : backgrounds,
            textPrimaryHex: QiThemeValue.hex(manifest.primaryTextColorHex),
            textSecondaryHex: QiThemeValue.hex(manifest.secondaryTextColorHex),
            textTertiaryHex: QiThemeValue.hex(manifest.tertiaryTextColorHex),
            darkTextPrimaryHex: QiThemeValue.hex(manifest.darkPrimaryTextColorHex),
            darkTextSecondaryHex: QiThemeValue.hex(manifest.darkSecondaryTextColorHex),
            darkTextTertiaryHex: QiThemeValue.hex(manifest.darkTertiaryTextColorHex)
        )

        // The trio is all-or-nothing: one custom level against two system ones reads as a
        // bug, so a partial set is reported rather than half-applied.
        appendPartialTextColorNote(manifest, to: &notes)
        if manifest.darkAccentColorHex != nil {
            // A hand-authored dark palette is all-or-nothing here: supplying only the accent
            // would force us to invent background/bar/text/dialogue and freeze them, which
            // reads worse than the app's own contrast-tuned derivation from the light accent.
            notes.append(localized("深色強調色未套用：本 App 的深色配色由淺色自動推導。"))
        }

        // Tab bar icons. Our second axis is light/dark, not normal/selected.
        for (tab, icon) in manifest.tabIcons ?? [:] {
            guard let tabID = tabIdentifier(for: tab) else {
                notes.append(String(format: localized("分頁圖示「%@」在本 App 沒有對應的分頁，已略過。"), tab))
                continue
            }
            guard icon.type?.lowercased() == "custom",
                  let file = icon.imageFileName,
                  let image = imageFile(at: file, rootURL: rootURL) else {
                continue
            }
            result.tabIcons.append(QiThemeImport.TabIconImport(tabID: tabID, image: image))
        }
        if manifest.selectedTabIcons?.isEmpty == false {
            notes.append(localized("選中狀態的分頁圖示未套用：本 App 的分頁圖示分淺色／深色，沒有選中態。"))
        }
        result.tabIconSize = manifest.tabIconSize
        result.hidesTabLabels = manifest.hideTabText

        // Covers & splash.
        result.defaultCovers = (manifest.coverImageFiles ?? []).compactMap {
            imageFile(at: $0, rootURL: rootURL)
        }
        if let splash = manifest.splashImageFiles, !splash.isEmpty {
            result.launchImage = imageFile(at: splash[0], rootURL: rootURL)
            if splash.count > 1 {
                notes.append(String(
                    format: localized("啟動圖有 %d 張，本 App 每種外觀只支援一張，已使用第一張。"),
                    splash.count
                ))
            }
        }
        result.launchEnabled = manifest.splashEnabled

        // Font.
        if let fontFile = manifest.fontFiles?.first,
           let url = try? ReaderStylePackage.containedURL(for: fontFile, under: rootURL),
           let data = try? Data(contentsOf: url) {
            result.font = QiThemeImport.FontImport(
                data: data,
                originalFileName: (fontFile as NSString).lastPathComponent,
                declaredPostScriptName: manifest.fontFamily
            )
        }

        // Interface effects. They have two opacity knobs where we have one.
        if let disabled = manifest.disableGlassEffect, disabled {
            result.effects.frostedGlass = false
        } else if let enabled = manifest.enableFrostedGlass {
            result.effects.frostedGlass = enabled
        }
        // Theirs is an *opacity*; ours is a *transparency* (`fill.opacity(1 - value)` in
        // `InterfaceEffects`), so assigning it straight across would invert the effect.
        if let opacity = manifest.frostedGlassOpacity ?? manifest.transparentModeOpacity {
            result.effects.glassTransparency = min(max(1 - opacity, 0), 1)
        }
        if manifest.frostedGlassOpacity != nil, manifest.transparentModeOpacity != nil {
            notes.append(localized("毛玻璃透明度與透明模式透明度合併為一個設定，已採用毛玻璃的值。"))
        }
        result.effects.glowIntensity = manifest.glowIntensity

        // Bookshelf.
        result.bookshelf.gridColumnCount = manifest.bookshelfGridColumnCount
        result.bookshelf.coverCornerRadius = manifest.coverCornerRadius
        result.bookshelf.forceDefaultCover = manifest.forceDefaultCover

        if let style = manifest.readerBottomToolbarStyle,
           let interface = AppearanceReaderInterface(rawValue: style) {
            result.readerInterface = interface
        }

        applyCardBackground(manifest, rootURL: rootURL, into: &result, notes: &notes)

        appendUnmappedAppearanceNotes(manifest, to: &notes)
    }

    private static func appendPartialTextColorNote(
        _ manifest: QiThemeManifest,
        to notes: inout [String]
    ) {
        let light = [manifest.primaryTextColorHex, manifest.secondaryTextColorHex,
                     manifest.tertiaryTextColorHex].compactMap { QiThemeValue.hex($0) }
        let dark = [manifest.darkPrimaryTextColorHex, manifest.darkSecondaryTextColorHex,
                    manifest.darkTertiaryTextColorHex].compactMap { QiThemeValue.hex($0) }
        guard (light.count > 0 && light.count < 3) || (dark.count > 0 && dark.count < 3) else {
            return
        }
        notes.append(localized("全域文字顏色需要主要／次要／第三階三個都提供才會套用，這個外觀包只給了一部分。"))
    }

    /// Card artwork. Their slice insets are pixels on the source image; ours are
    /// fractions of it, because the image store downsamples large art — so the source
    /// dimensions are read here, where the original file is still on disk.
    private static func applyCardBackground(
        _ manifest: QiThemeManifest,
        rootURL: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) {
        guard let card = manifest.cardBackground, card.isEnabled != false else { return }
        result.cardBackgroundImage = imageFile(at: card.backgroundImageFile, rootURL: rootURL)
        result.darkCardBackgroundImage = imageFile(at: card.darkBackgroundImageFile, rootURL: rootURL)

        let lightSize = result.cardBackgroundImage.flatMap { pixelSize(of: $0.data) }
        let darkSize = result.darkCardBackgroundImage.flatMap { pixelSize(of: $0.data) }
        let opacity = card.backgroundOpacity ?? 1

        result.cardBackground = AppearanceCardBackground(
            isEnabled: true,
            light: cardLayer(
                mode: card.lightImageMode,
                layout: card.lightLayout,
                imageSize: lightSize,
                fillHex: QiThemeValue.hex(card.lightBackgroundColorHex),
                borderHex: QiThemeValue.hex(card.lightBorderColorHex),
                card: card,
                opacity: opacity
            ),
            dark: cardLayer(
                mode: card.darkImageMode,
                layout: card.darkLayout,
                imageSize: darkSize,
                fillHex: QiThemeValue.hex(card.darkBackgroundColorHex),
                borderHex: QiThemeValue.hex(card.darkBorderColorHex),
                card: card,
                opacity: opacity
            )
        )

        if card.cornerRadius != nil {
            notes.append(localized("卡片背景的圓角未套用：卡片外框由本 App 自己的版面決定。"))
        }
        if card.lightLayout?.contentInsets != nil || card.darkLayout?.contentInsets != nil {
            notes.append(localized("卡片背景的內容內距沒有對應設定，已略過。"))
        }
    }

    private static func cardLayer(
        mode: String?,
        layout: QiThemeCardLayout?,
        imageSize: CGSize?,
        fillHex: UInt32?,
        borderHex: UInt32?,
        card: QiThemeCardBackground,
        opacity: Double
    ) -> AppearanceCardBackgroundLayer {
        let insets = layout?.sliceInsets
        let width = imageSize?.width ?? 0
        let height = imageSize?.height ?? 0
        func fraction(_ value: Double?, over dimension: CGFloat) -> Double {
            guard let value, dimension > 0 else { return 0 }
            return value / Double(dimension)
        }
        return AppearanceCardBackgroundLayer(
            mode: mode == "nineSlice" ? .nineSlice : .stretch,
            sliceTop: fraction(insets?.top, over: height),
            sliceLeft: fraction(insets?.left, over: width),
            sliceBottom: fraction(insets?.bottom, over: height),
            sliceRight: fraction(insets?.right, over: width),
            imageOpacity: (layout?.opacity ?? 1) * opacity,
            fillHex: fillHex,
            borderHex: borderHex,
            borderWidth: card.borderWidth ?? 0,
            borderOpacity: card.borderOpacity ?? 1
        )
    }

    /// Header-only read, so a large PNG is never decoded just to learn its size.
    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The manifest keys that have no destination in this app at all. Listed explicitly so
    /// the user sees exactly what did not come across, rather than wondering why the pack
    /// "looks different here".
    private static func appendUnmappedAppearanceNotes(
        _ manifest: QiThemeManifest,
        to notes: inout [String]
    ) {
        var unmapped: [String] = []
        if manifest.bookshelfHeaderStyle != nil { unmapped.append(localized("書架標題樣式")) }
        if manifest.bookshelfListCardHeight != nil { unmapped.append(localized("書架列表卡片高度")) }
        if manifest.bookshelfShowsTags != nil { unmapped.append(localized("書架標籤顯示")) }
        if manifest.bookshelfTagTextColorMode != nil || manifest.bookshelfTagCustomTextColorHex != nil {
            unmapped.append(localized("書架標籤配色"))
        }
        if manifest.readerToolbarIconSize != nil { unmapped.append(localized("閱讀工具列圖示大小")) }
        if manifest.progressBarsFollowAppearance != nil { unmapped.append(localized("進度條跟隨外觀")) }
        if manifest.readerToolbarCardsFollowAppearance != nil {
            unmapped.append(localized("閱讀工具列卡片跟隨外觀"))
        }
        guard !unmapped.isEmpty else { return }
        notes.append(String(
            format: localized("以下項目本 App 沒有對應設定，已略過：%@"),
            unmapped.joined(separator: localized("、"))
        ))
    }

    private static func backgroundPayload(
        _ background: QiThemeBackground,
        rootURL: URL
    ) -> AppearanceThemeExportFile.PageBackgroundPayload {
        AppearanceThemeExportFile.PageBackgroundPayload(
            lightPrimaryHex: QiThemeValue.hex(background.lightPrimaryColorHex),
            lightSecondaryHex: QiThemeValue.hex(background.lightSecondaryColorHex),
            darkPrimaryHex: QiThemeValue.hex(background.darkPrimaryColorHex),
            darkSecondaryHex: QiThemeValue.hex(background.darkSecondaryColorHex),
            lightImage: imagePayload(at: background.backgroundImageFile, rootURL: rootURL),
            darkImage: imagePayload(at: background.darkBackgroundImageFile, rootURL: rootURL),
            lightImageOpacity: background.backgroundImageOpacity,
            darkImageOpacity: background.darkBackgroundImageOpacity
        )
    }

    /// QiReader's tab names against ours. `stats` and `fileManager` are tabs they have and
    /// we do not, so those icons have nowhere to go.
    static func tabIdentifier(for qiTab: String) -> String? {
        switch qiTab {
        case "bookshelf": return "bookshelf"
        case "explore": return "explore"
        case "search": return "search"
        case "settings": return "settings"
        default: return nil
        }
    }

    // MARK: - Reader preset

    private static func applyReaderPreset(
        rootURL: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) async {
        let indexURL = rootURL
            .appendingPathComponent("reader_themes", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard let indexData = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(QiReaderThemeIndex.self, from: indexData),
              let binding = index.bindings?.first,
              let presetFile = binding.presetFile else {
            return
        }
        if (index.bindings?.count ?? 0) > 1 {
            notes.append(String(
                format: localized("外觀包含有 %d 組閱讀主題，本 App 一次只套用一組，已使用第一組。"),
                index.bindings?.count ?? 0
            ))
        }

        let presetPath = "reader_themes/\(presetFile)"
        guard let presetURL = try? ReaderStylePackage.containedURL(for: presetPath, under: rootURL),
              FileManager.default.fileExists(atPath: presetURL.path) else {
            return
        }

        // `.qipreset` is itself a zip; unpack it beside the outer one.
        let presetRoot = rootURL.appendingPathComponent("__preset", isDirectory: true)
        guard let presetPaths = try? await extractArchive(at: presetURL, into: presetRoot),
              let presetDir = singleTopLevelDirectory(in: presetPaths) else {
            notes.append(localized("閱讀主題內容損毀，只匯入了外觀部分。"))
            return
        }
        let presetContentURL = presetRoot.appendingPathComponent(presetDir, isDirectory: true)
        guard let manifestData = try? Data(
            contentsOf: presetContentURL.appendingPathComponent("manifest.json", isDirectory: false)
        ),
        let presetManifest = try? JSONDecoder().decode(QiPresetManifest.self, from: manifestData) else {
            notes.append(localized("閱讀主題內容損毀，只匯入了外觀部分。"))
            return
        }

        if let backgroundFile = presetManifest.backgroundAssetFileName {
            result.readerBackground = imageFile(at: "assets/\(backgroundFile)", rootURL: presetContentURL)
        }

        guard let preset = presetManifest.preset else { return }

        result.readerFontFamilyHint = preset.fontFamily
        result.overlayLayout = overlayLayout(from: preset, notes: &notes)
        result.layoutConfig = layoutConfig(
            from: preset,
            overlayLayout: result.overlayLayout,
            notes: &notes
        )
        result.bubble = bubbleImport(from: preset, notes: &notes)

        if let package = presetManifest.chapterTitleStylePackage {
            result.chapterTitleStyle = await chapterTitleStyle(from: package, notes: &notes)
        }

        if let template = preset.layoutTemplateRaw,
           result.readerInterface == nil,
           let interface = readerInterface(forTemplate: template) {
            result.readerInterface = interface
        }
    }

    /// QiReader serializes its reading-page enums as Simplified-Chinese display strings.
    /// Ours are Traditional (`PageTurnStyle`) or English (`AppearanceReaderInterface`), so
    /// every one of these needs an explicit alias — `init(rawValue:)` would silently fail.
    static func readerInterface(forTemplate raw: String) -> AppearanceReaderInterface? {
        switch raw {
        case "经典", "經典": return .classic
        case "现代", "現代": return .modern
        default: return nil
        }
    }

    /// legado's `pageAnim`. Scroll mode is its own value there and outranks the animation,
    /// matching `ReaderLayoutPresetExporter.pageAnim(for:)`.
    static func pageAnim(forPageMode raw: String?) -> Int? {
        switch raw {
        case "滑动", "滑動": return 0
        case "覆盖", "覆蓋", "覆盖翻页", "覆蓋翻頁": return 1
        case "仿真", "仿真翻页", "仿真翻書": return 2
        case "滚动", "捲動", "上下滚动": return 3
        case "无", "無", "无动画", "無動畫": return -1
        default: return nil
        }
    }

    private static func layoutConfig(
        from preset: QiPreset,
        overlayLayout: ReaderOverlayLayout?,
        notes: inout [String]
    ) -> Data? {
        var config = QiTranslatedReadConfig()
        config.name = preset.name
        config.textSize = preset.fontSize
        config.textBold = preset.isBold.map { $0 ? 1 : 0 }
        config.lineSpacingExtra = preset.lineSpacing
        config.paragraphSpacing = preset.paragraphSpacing
        config.letterSpacing = preset.letterSpacing
        config.paddingLeft = preset.leftPageMargin
        config.paddingRight = preset.rightPageMargin
        config.pageAnim = pageAnim(forPageMode: preset.pageModeRaw)
        config.readerOverlayLayout = overlayLayout

        if let left = preset.leftPageMargin, let right = preset.rightPageMargin, left != right {
            notes.append(localized("左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。"))
        }
        if preset.fontWeightRaw != nil, preset.isBold != true {
            notes.append(localized("字重是連續數值，本 App 只有粗體開關，已略過。"))
        }
        if preset.textIndent != nil {
            notes.append(localized("首行縮排固定為兩字元，無法調整，已略過。"))
        }
        if preset.textAlignmentRaw != nil {
            notes.append(localized("正文對齊方式固定為兩端對齊，已略過。"))
        }
        if preset.paragraphSeparatorLines != nil {
            notes.append(localized("段間空行數沒有對應設定，已略過。"))
        }
        if preset.pageModeRaw != nil, config.pageAnim == nil {
            notes.append(String(
                format: localized("翻頁方式「%@」無法辨識，已保留原本設定。"),
                preset.pageModeRaw ?? ""
            ))
        }

        guard config.hasAnyValue else { return nil }
        return try? JSONEncoder().encode(config)
    }

    // MARK: - Reader overlay widgets

    private static func overlayLayout(
        from preset: QiPreset,
        notes: inout [String]
    ) -> ReaderOverlayLayout? {
        guard let encoded = preset.layoutWidgetsData,
              let widgets = try? QiThemeValue.decodeBase64JSON([QiLayoutWidget].self, from: encoded),
              !widgets.isEmpty else {
            return nil
        }

        var opening: [ReaderOverlayComponent] = []
        var body: [ReaderOverlayComponent] = []
        var unknown: [String] = []

        for widget in widgets {
            guard let item = widget.item, let kind = overlayKind(for: item) else {
                if let item = widget.item { unknown.append(item) }
                continue
            }
            let component = ReaderOverlayComponent(
                id: UUID(),
                kind: kind,
                position: ReaderOverlayNormalizedPoint(
                    x: widget.xPercent ?? 0.5,
                    y: widget.yPercent ?? 0.5
                ).clamped,
                style: ReaderOverlayComponentStyle(
                    font: ReaderOverlayFontReference(
                        kind: preset.widgetUseCustomFont == true ? .reader : .system
                    ),
                    fontSize: widget.fontSize ?? ReaderOverlayComponentStyle.defaultFontSize,
                    fontWeight: .regular,
                    color: overlayColor(widget.customColorHex),
                    opacity: widget.opacity ?? ReaderOverlayComponentStyle.defaultOpacity
                ),
                configuration: ReaderOverlayComponentConfiguration()
            ).normalized

            switch widget.pageScope {
            case "仅首页", "僅首頁":
                opening.append(component)
            case "仅正文页", "僅正文頁":
                body.append(component)
            default:
                opening.append(component)
                body.append(component)
            }
        }

        if !unknown.isEmpty {
            notes.append(String(
                format: localized("以下頁首頁尾元件無法辨識，已略過：%@"),
                unknown.joined(separator: localized("、"))
            ))
        }
        guard !opening.isEmpty || !body.isEmpty else { return nil }

        return ReaderOverlayLayout(
            components: body,
            chapterOpeningComponents: opening,
            contentReservations: ReaderOverlayContentReservations(
                top: preset.topInsetExtra ?? 0,
                bottom: preset.bottomInsetExtra ?? 0
            ).normalized
        )
    }

    private static func overlayColor(_ hex: String?) -> ReaderOverlayColorReference {
        guard let rgb = QiThemeValue.hex(hex) else {
            return ReaderOverlayColorReference(source: .readerText)
        }
        // Our reference stores RGBA; QiReader's is RGB, so it is fully opaque.
        return ReaderOverlayColorReference(source: .custom, hexRGBA: (rgb << 8) | 0xFF)
    }

    /// Widget names we can map with confidence. Anything else is dropped *and named* in a
    /// note rather than guessed at — a wrong guess puts the wrong reading out on the page.
    static func overlayKind(for item: String) -> ReaderOverlayComponentKind? {
        switch item {
        case "书名", "書名": return .bookTitle
        case "章节名", "章節名": return .chapterTitle
        case "本章进度(文字)", "本章進度(文字)", "本章进度", "本章進度": return .chapterPage
        case "总进度(文字)", "總進度(文字)", "总进度", "總進度": return .totalProgressText
        case "进度条", "進度條": return .progressBar
        case "时间", "時間": return .currentTime
        case "日期": return .currentDate
        case "星期": return .weekday
        case "电量", "電量": return .battery
        case "阅读时长", "閱讀時長": return .readingDuration
        case "剩余时间", "剩餘時間": return .remainingTime
        default: return nil
        }
    }

    // MARK: - Comment bubble

    private static func bubbleImport(
        from preset: QiPreset,
        notes: inout [String]
    ) -> QiThemeImport.BubbleImport? {
        guard let encoded = preset.commentBubbleStyleData,
              let style = try? QiThemeValue.decodeBase64JSON(QiBubbleStyle.self, from: encoded),
              let svg = style.backgroundSVGData?.trimmingCharacters(in: .whitespacesAndNewlines),
              !svg.isEmpty else {
            return nil
        }
        // Only meaningful for templates that actually carry the placeholder; a raster
        // bubble has no text node to colour.
        let usesColorTemplate = svg.contains("${color}") || svg.contains("${Color}")
        let fill = QiThemeValue.hex(style.fillColorHex).map { String(format: "#%06X", $0) }

        let imported = ReaderCommentBubbleCustomStyle(
            name: style.name?.nilIfEmpty ?? localized("自訂 SVG"),
            svg: svg,
            sizeScale: style.svgSizeMultiplier,
            dayEmphasisColor: usesColorTemplate ? fill : nil,
            dayNormalColor: usesColorTemplate ? fill : nil,
            nightEmphasisColor: usesColorTemplate ? fill : nil,
            nightNormalColor: usesColorTemplate ? fill : nil
        )

        if style.showLabel == false {
            notes.append(localized("段評氣泡設定為不顯示數字，已照原樣匯入（氣泡只顯示圖案）。"))
        }
        if style.cornerRadiusFraction != nil || style.opacity != nil
            || style.svgFixedWidth != nil || style.svgFixedHeight != nil {
            notes.append(localized("段評氣泡的圓角、透明度與固定尺寸沒有對應設定，已略過。"))
        }

        return QiThemeImport.BubbleImport(
            style: imported,
            scale: style.svgSizeMultiplier,
            textScale: style.svgFontScale
        )
    }

    // MARK: - Chapter title

    private static func chapterTitleStyle(
        from package: QiChapterTitleStylePackage,
        notes: inout [String]
    ) async -> ChapterTitleStyle? {
        guard let light = package.light ?? package.dark else { return nil }

        var style = ChapterTitleStyle.default
        style.visible = light.isEnabled ?? true
        if let size = light.fontSize { style.size = CGFloat(size) }
        if let top = light.topSpacing { style.topSpacing = CGFloat(top) }
        if let bottom = light.bottomSpacing { style.bottomSpacing = CGFloat(bottom) }
        if let weight = light.fontWeight, let mapped = ChapterTitleWeight(rawValue: weight) {
            style.weight = mapped
        }
        if let alignment = light.alignment, let mapped = ChapterTitleAlignment(rawValue: alignment) {
            style.alignment = mapped
        }
        style.followsBodyFont = !(light.useCustomFont ?? false)
        style.nameFontPostScript = light.chapterNameFont?.nilIfEmpty
        style.numberFontPostScript = light.chapterNumberFont?.nilIfEmpty
        style.splitEnabled = light.showChapterName ?? style.splitEnabled

        guard light.useHTMLMode == true else {
            appendChapterTitleGapNotes(light, to: &notes)
            return style.sanitized()
        }

        // Import the artwork first: layers reference our asset IDs, so the store has to
        // mint them before the design can be assembled.
        var assetIDs: [String: UUID] = [:]
        for asset in package.assets ?? [] {
            guard let id = asset.id,
                  let base64 = asset.data,
                  let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                continue
            }
            let name = asset.fileName ?? "\(id).png"
            if let stored = try? await ReaderStyleAssetStore.shared.importImage(
                data: bytes,
                suggestedName: name
            ) {
                assetIDs[id] = stored.id
            }
        }

        let lightProject = designerProject(light)
        let darkProject = package.dark.flatMap(designerProject)

        guard let lightProject, let elements = lightProject.elements, !elements.isEmpty else {
            appendChapterTitleGapNotes(light, to: &notes)
            return style.sanitized()
        }

        let lightElements = sortedByDepth(elements)
        let darkElements = sortedByDepth(darkProject?.elements ?? [])
        var darkCursor: [String: Int] = [:]

        var layers: [ChapterTitleLayer] = []
        for element in lightElements {
            guard let layer = chapterTitleLayer(
                from: element,
                variant: light,
                assetIDs: assetIDs
            ) else { continue }

            // Pair the dark variant by element type and order of appearance. Their two
            // variants are authored independently and can differ in structure — the sample
            // pack has five light elements and three dark ones — so anything unpaired keeps
            // the light styling rather than inventing one.
            var paired = layer
            let type = element.type ?? ""
            let ordinal = darkCursor[type, default: 0]
            let candidates = darkElements.filter { ($0.type ?? "") == type }
            if ordinal < candidates.count {
                darkCursor[type] = ordinal + 1
                if let darkVariant = package.dark {
                    paired.darkStyle = layerStyle(
                        from: candidates[ordinal],
                        variant: darkVariant,
                        assetIDs: assetIDs
                    )
                }
            }
            layers.append(paired)
        }

        guard !layers.isEmpty else {
            appendChapterTitleGapNotes(light, to: &notes)
            return style.sanitized()
        }

        let lightCount = lightElements.count
        let darkCount = darkElements.count
        if darkCount > 0, darkCount != lightCount {
            notes.append(String(
                format: localized("章節標題的淺色版有 %d 個圖層、深色版有 %d 個，已以淺色版為準，配不到的圖層沿用淺色樣式。"),
                lightCount,
                darkCount
            ))
        }
        if let lightHeight = lightProject.canvas?.height,
           let darkHeight = darkProject?.canvas?.height,
           lightHeight != darkHeight {
            notes.append(String(
                format: localized("章節標題的淺色與深色畫布高度不同（%d／%d），已採用淺色版的高度。"),
                Int(lightHeight),
                Int(darkHeight)
            ))
        }

        style.advancedCSSEnabled = true
        style.design = ChapterTitleDesign(
            canvasHeight: lightProject.canvas?.height ?? light.htmlHeight
                ?? ChapterTitleDesign.defaultCanvasHeight,
            layers: layers
        )
        appendChapterTitleGapNotes(light, to: &notes)
        return style.sanitized()
    }

    private static func appendChapterTitleGapNotes(
        _ variant: QiChapterTitleVariant,
        to notes: inout [String]
    ) {
        var unmapped: [String] = []
        if variant.maxLines != nil { unmapped.append(localized("標題最大行數")) }
        if variant.showFullTitle != nil { unmapped.append(localized("顯示完整標題")) }
        if variant.chapterNumberRegex != nil { unmapped.append(localized("章節序號比對規則")) }
        guard !unmapped.isEmpty else { return }
        notes.append(String(
            format: localized("章節標題的下列設定沒有對應項目，已略過：%@"),
            unmapped.joined(separator: localized("、"))
        ))
    }

    private static func designerProject(_ variant: QiChapterTitleVariant) -> QiDesignerProject? {
        guard let json = variant.designerProjectJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(QiDesignerProject.self, from: data)
    }

    /// Paint order. Their canvas is absolutely positioned with an explicit `z-index`;
    /// ours is the array order, so the sort is what preserves the stacking.
    private static func sortedByDepth(_ elements: [QiDesignerElement]) -> [QiDesignerElement] {
        elements.enumerated()
            .sorted { lhs, rhs in
                let lz = Int(lhs.element.css?["z-index"] ?? "") ?? 0
                let rz = Int(rhs.element.css?["z-index"] ?? "") ?? 0
                return lz == rz ? lhs.offset < rhs.offset : lz < rz
            }
            .map(\.element)
    }

    private static func chapterTitleLayer(
        from element: QiDesignerElement,
        variant: QiChapterTitleVariant,
        assetIDs: [String: UUID]
    ) -> ChapterTitleLayer? {
        let css = element.css ?? [:]
        let kind: ChapterTitleLayerKind
        let content: ChapterTitleLayerContent
        switch element.type {
        case "chapterNumber":
            kind = .chapterNumber
            content = .dynamic(.number)
        case "chapterName":
            kind = .chapterName
            content = .dynamic(.name)
        case "image":
            kind = .image
            guard let assetKey = element.assetId, let id = assetIDs[assetKey] else { return nil }
            content = .image(id)
        default:
            return nil
        }

        let width = QiThemeValue.percentFraction(css["width"]) ?? 0.5
        let height = QiThemeValue.percentFraction(css["height"])
            ?? autoHeightFraction(css: css, variant: variant)
        let style = layerStyle(from: element, variant: variant, assetIDs: assetIDs)

        return ChapterTitleLayer(
            id: UUID(),
            name: element.id ?? kind.rawValue,
            kind: kind,
            frame: ReaderStyleNormalizedRect(
                x: QiThemeValue.percentFraction(css["left"]) ?? 0,
                y: QiThemeValue.percentFraction(css["top"]) ?? 0,
                width: width,
                height: height
            ),
            rotation: ReaderStyleRotation(
                degrees: QiThemeValue.rotationDegrees(css["transform"]) ?? 0
            ),
            isVisible: element.visible ?? true,
            isLocked: element.locked ?? false,
            content: content,
            lightStyle: style,
            darkStyle: style
        )
    }

    /// Their text elements use `height: auto`; our rects need a real height. Deriving it
    /// from the declared font size and line height keeps the text box the size the author
    /// actually sees, instead of a fixed guess.
    private static func autoHeightFraction(
        css: [String: String],
        variant: QiChapterTitleVariant
    ) -> Double {
        let fontSize = QiThemeValue.pixels(css["font-size"]) ?? 22
        let lineHeight = Double(css["line-height"] ?? "") ?? 1.35
        let canvasHeight = variant.htmlHeight ?? ChapterTitleDesign.defaultCanvasHeight
        guard canvasHeight > 0 else { return 0.2 }
        return min(1, (fontSize * lineHeight) / canvasHeight)
    }

    private static func layerStyle(
        from element: QiDesignerElement,
        variant: QiChapterTitleVariant,
        assetIDs: [String: UUID]
    ) -> ChapterTitleLayerStyle {
        let css = element.css ?? [:]
        let alignment = ChapterTitleAlignment(rawValue: css["text-align"] ?? "") ?? .center

        var presentation: ReaderStyleImagePresentation?
        if element.type == "image",
           let assetKey = element.assetId,
           let id = assetIDs[assetKey] {
            presentation = ReaderStyleImagePresentation(
                assetID: id,
                contentMode: css["object-fit"] == "contain" ? .fit : .fill,
                opacity: Double(css["opacity"] ?? "") ?? 1
            )
        }

        return ChapterTitleLayerStyle(
            ruleStyle: ReaderStyleRuleStyle(
                text: ReaderStyleTextStyle(
                    colorHex: QiThemeValue.cssColor(css["color"]),
                    fontPostScriptName: resolvedFontName(css["font-family"], variant: variant),
                    fontSize: QiThemeValue.pixels(css["font-size"]),
                    fontWeight: Int(css["font-weight"] ?? ""),
                    italic: css["font-style"] == "italic",
                    letterSpacing: QiThemeValue.pixels(css["letter-spacing"]),
                    lineHeight: Double(css["line-height"] ?? ""),
                    underline: css["text-decoration-line"] == "underline"
                )
            ),
            textAlignment: alignment,
            imagePresentation: presentation
        )
    }

    /// Their templates reference two placeholder families — `章节名字体` / `章节数字体` —
    /// that stand for the variant's configured fonts rather than naming a real face.
    private static func resolvedFontName(
        _ cssFamily: String?,
        variant: QiChapterTitleVariant
    ) -> String? {
        guard let family = cssFamily?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        switch family {
        case "章节名字体", "章節名字體": return variant.chapterNameFont?.nilIfEmpty
        case "章节数字体", "章節數字體": return variant.chapterNumberFont?.nilIfEmpty
        default: return family
        }
    }

    // MARK: - Archive plumbing

    /// Extracts `archiveURL` into `contentRoot`, applying the same path, count and size
    /// checks `ReaderStylePackage` applies to our own archives — reusing its validators
    /// rather than growing a second, drifting copy.
    private static func extractArchive(at archiveURL: URL, into contentRoot: URL) async throws -> [String] {
        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw QiThemeImportError.malformedArchive
        }

        let entries: [Entry]
        do {
            entries = try await archive.entries()
        } catch {
            throw QiThemeImportError.malformedArchive
        }
        guard entries.count <= maximumFileCount else {
            throw QiThemeImportError.tooManyFiles(entries.count)
        }
        let paths = entries.map(repairedPath)
        do {
            try ReaderStylePackage.validateEntryPaths(paths)
        } catch {
            throw QiThemeImportError.unsafePath(paths.first ?? "")
        }

        var expandedBytes: UInt64 = 0
        for entry in entries {
            guard entry.type != .symlink else {
                throw QiThemeImportError.unsafePath(entry.path)
            }
            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            expandedBytes = sum
            guard !overflow, expandedBytes <= UInt64(maximumExpandedBytes) else {
                throw QiThemeImportError.expandedDataTooLarge(
                    expandedBytes > UInt64(Int.max) ? Int.max : Int(expandedBytes)
                )
            }
        }

        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        var written: [String] = []
        for (entry, path) in zip(entries, paths) {
            let destination: URL
            do {
                destination = try ReaderStylePackage.containedURL(for: path, under: contentRoot)
            } catch {
                throw QiThemeImportError.unsafePath(path)
            }
            guard entry.type == .file else { continue }
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                _ = try await archive.extract(entry, to: destination)
            } catch {
                // One unreadable entry (an odd encoding, a truncated member) should cost
                // that asset, not the whole pack — the manifest is what decides validity.
                AppLogger.parse("⟐ qitheme extract skipped", context: ["path": path])
                continue
            }
            written.append(path)
        }
        return written
    }

    /// QiReader writes CJK entry names as raw UTF-8 bytes but leaves the archive's UTF-8
    /// flag clear, so a spec-compliant reader decodes them as CP437 and the extracted file
    /// lands under mojibake like `µ▒çµûçµÿÄµ£¥Σ╜ô.ttf` — which the manifest's real path
    /// (`fonts/汇文明朝体.ttf`) then never matches. Every pack tested does this, and it is
    /// why the bundled font silently failed to install.
    ///
    /// Reading the raw bytes as UTF-8 repairs it. `path(using:)` returns an empty string
    /// when the bytes are not valid UTF-8 — which is exactly the case where the library's
    /// CP437 reading is the correct one — so preferring UTF-8 only when it decodes is safe
    /// for genuinely CP437-named archives.
    private static func repairedPath(_ entry: Entry) -> String {
        let utf8Path = entry.path(using: .utf8)
        return utf8Path.isEmpty ? entry.path : utf8Path
    }

    /// The pack's single UUID-named root. Returns nil when the archive has content at its
    /// root or several top-level directories, which is what separates a `.qitheme` from
    /// every other archive the picker can hand us.
    private static func singleTopLevelDirectory(in paths: [String]) -> String? {
        var roots: Set<String> = []
        for path in paths {
            guard let first = path.split(separator: "/", omittingEmptySubsequences: true).first else {
                continue
            }
            // A file sitting at the archive root is disqualifying.
            guard path.contains("/") else { return nil }
            roots.insert(String(first))
        }
        guard roots.count == 1, let root = roots.first else { return nil }
        return root
    }

    private static func imageFile(at relativePath: String?, rootURL: URL) -> QiThemeImport.ImageFile? {
        guard let relativePath, !relativePath.isEmpty,
              let url = try? ReaderStylePackage.containedURL(for: relativePath, under: rootURL),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        return QiThemeImport.ImageFile(data: data, fileName: (relativePath as NSString).lastPathComponent)
    }

    private static func imagePayload(
        at relativePath: String?,
        rootURL: URL
    ) -> AppearanceThemeExportFile.ImagePayload? {
        guard let file = imageFile(at: relativePath, rootURL: rootURL) else { return nil }
        return AppearanceThemeExportFile.ImagePayload(
            fileExtension: (file.fileName as NSString).pathExtension,
            base64: file.data.base64EncodedString()
        )
    }
}

/// legado's `readConfig.json` keys, populated from a QiReader preset. Deliberately the
/// same shape `ReaderLayoutPresetExporter` writes, so the translated preset goes through
/// `ReaderLayoutPresetImporter` — the app's single layout parser — instead of a second one.
///
/// Absent values are *omitted*, not encoded as null: `ReaderLayoutPresetImporter` gates on
/// the set of keys present, so emitting a key we have no value for would make an empty
/// preset look recognized and reset the reader's type size.
private struct QiTranslatedReadConfig: Encodable {
    var name: String?
    var textSize: Double?
    var textBold: Int?
    var lineSpacingExtra: Double?
    var paragraphSpacing: Double?
    var letterSpacing: Double?
    var paddingLeft: Double?
    var paddingRight: Double?
    var pageAnim: Int?
    var readerOverlayLayout: ReaderOverlayLayout?

    var hasAnyValue: Bool {
        textSize != nil || textBold != nil || lineSpacingExtra != nil
            || paragraphSpacing != nil || letterSpacing != nil
            || paddingLeft != nil || paddingRight != nil || pageAnim != nil
            || readerOverlayLayout != nil
    }

    private enum CodingKeys: String, CodingKey {
        case name, textSize, textBold, lineSpacingExtra, paragraphSpacing
        case letterSpacing, paddingLeft, paddingRight, pageAnim, readerOverlayLayout
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(textSize, forKey: .textSize)
        try container.encodeIfPresent(textBold, forKey: .textBold)
        try container.encodeIfPresent(lineSpacingExtra, forKey: .lineSpacingExtra)
        try container.encodeIfPresent(paragraphSpacing, forKey: .paragraphSpacing)
        try container.encodeIfPresent(letterSpacing, forKey: .letterSpacing)
        try container.encodeIfPresent(paddingLeft, forKey: .paddingLeft)
        try container.encodeIfPresent(paddingRight, forKey: .paddingRight)
        try container.encodeIfPresent(pageAnim, forKey: .pageAnim)
        try container.encodeIfPresent(readerOverlayLayout, forKey: .readerOverlayLayout)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
