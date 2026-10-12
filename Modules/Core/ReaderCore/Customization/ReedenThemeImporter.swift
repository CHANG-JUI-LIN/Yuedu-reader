import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Reads Reeden's `.red` app-theme packs and translates them into the same `QiThemeImport`
/// value the QiReader layer produces, so `QiThemeImportService.apply` stays the one path that
/// changes the app. The archive plumbing, image loading and the legado layout bridge are
/// `QiThemeImporter`'s; this file only knows Reeden's layout of them.
///
/// The format is described in `ReedenThemeManifest.swift`.
enum ReedenThemeImporter {
    static func hasRedExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "red"
    }

    // MARK: - Container

    private static let magic = Data("RED".utf8)
    private static let zipVersion: UInt8 = 0x04
    private static let encryptedVersion: UInt8 = 0x10

    /// True when `data` starts with Reeden's container header, of either version.
    static func isReedenContainer(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(3) == magic
    }

    /// The ZIP payload of a plain pack. Throws `.encryptedReedenTheme` for an encrypted
    /// pack — detected from its plaintext header, never guessed from "not a ZIP" — and
    /// `.notAReedenTheme` for anything else.
    static func zipPayload(of data: Data) throws -> Data {
        guard isReedenContainer(data) else { throw QiThemeImportError.notAReedenTheme }
        let bytes = [UInt8](data.prefix(8))
        switch bytes[3] {
        case zipVersion:
            let payload = data.dropFirst(4)
            // A ZIP local file header.
            guard payload.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
                throw QiThemeImportError.notAReedenTheme
            }
            return Data(payload)
        case encryptedVersion:
            if isEncryptedHeader(data) { throw QiThemeImportError.encryptedReedenTheme }
            throw QiThemeImportError.notAReedenTheme
        default:
            throw QiThemeImportError.notAReedenTheme
        }
    }

    /// `RED` 0x10, a big-endian UInt32 length, then that many bytes of JSON naming the
    /// container mode.
    private static func isEncryptedHeader(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let lengthBytes = [UInt8](data[data.startIndex + 4 ..< data.startIndex + 8])
        let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        let start = data.startIndex + 8
        guard length > 0, length <= 64 * 1_024, data.count >= 8 + length,
              let header = try? JSONSerialization.jsonObject(
                  with: data[start ..< start + length]
              ) as? [String: Any] else {
            return false
        }
        return header["containerMode"] as? String == "reedenPrivate"
            || (header["algorithm"] as? String)?.lowercased().hasPrefix("aes") == true
    }

    // MARK: - Parsing

    static func parse(_ data: Data) async throws -> QiThemeImport {
        let zip = try zipPayload(of: data)
        guard zip.count <= QiThemeImporter.maximumExpandedBytes else {
            throw QiThemeImportError.expandedDataTooLarge(zip.count)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("red-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archiveURL = staging.appendingPathComponent("source.zip", isDirectory: false)
        try zip.write(to: archiveURL, options: .atomic)

        let root = staging.appendingPathComponent("contents", isDirectory: true)
        _ = try await QiThemeImporter.extractArchive(at: archiveURL, into: root)

        let manifestURL = root.appendingPathComponent("theme.json", isDirectory: false)
        let manifestData: Data
        let file: ReedenThemeFile
        do {
            manifestData = try Data(contentsOf: manifestURL)
            file = try JSONDecoder().decode(ReedenThemeFile.self, from: manifestData)
        } catch {
            AppLogger.parse("⟐ red theme.json unreadable", error: error)
            throw QiThemeImportError.notAReedenTheme
        }
        guard let light = file.light else { throw QiThemeImportError.notAReedenTheme }
        // `enabled: false` is Reeden's "no dark version": its colours are leftovers, not a
        // palette, so the app derives dark from the light one as for any other theme.
        let dark = file.dark.flatMap { $0.enabled == false ? nil : $0 }

        var notes: [String] = []
        var result = QiThemeImport(
            name: file.name?.trimmedNonEmpty ?? localized("Reeden 主題包")
        )
        applyColors(light: light, dark: dark, into: &result, notes: &notes)
        applyPageBackground(light: light, dark: dark, root: root, into: &result)
        applyCards(light: light, dark: dark, root: root, into: &result)
        await applyTabIcons(light: light, dark: dark, root: root, into: &result, notes: &notes)
        applyCovers(light: light, dark: dark, root: root, into: &result)
        applySplash(light: light, dark: dark, root: root, into: &result, notes: &notes)
        await applyReaderSchemas(light: light, dark: dark, root: root, into: &result, notes: &notes)
        appendUnmappedAppearanceNotes(light: light, dark: dark, to: &notes)

        result.notes = notes
        return result
    }

    // MARK: - Colours

    private struct Palette {
        var background: UInt32
        var text: UInt32
        var bar: UInt32
        var accent: UInt32
        var dialogue: UInt32
        /// Some source colour carried transparency the palette cannot hold.
        var droppedAlpha: Bool
    }

    /// Reeden's shadcn-style roles against our five. `primaryColor` is what Reeden fills
    /// buttons and selections with, so it is our accent; the bar takes the tab bar's own
    /// colour, then the card surface.
    private static func palette(_ variant: ReedenThemeVariant, fallback: Palette?) -> Palette? {
        let background = ReedenValue.color(variant.backgroundColor)
        let text = ReedenValue.color(variant.foregroundColor)
        let accent = ReedenValue.color(variant.primaryColor) ?? ReedenValue.color(variant.accentColor)
        let bar = ReedenValue.color(variant.tabBackgroundColor) ?? ReedenValue.color(variant.cardColor)
        let dialogue = ReedenValue.color(variant.mutedColor) ?? ReedenValue.color(variant.cardColor)
        guard background != nil || text != nil || accent != nil else { return fallback }
        let sources = [background, text, accent, bar, dialogue].compactMap { $0 }
        let resolvedBackground = background?.rgb ?? fallback?.background ?? 0xF4F5F7
        return Palette(
            background: resolvedBackground,
            text: text?.rgb ?? fallback?.text ?? 0x333333,
            bar: bar?.rgb ?? resolvedBackground,
            accent: accent?.rgb ?? fallback?.accent ?? 0x007AFF,
            dialogue: dialogue?.rgb ?? resolvedBackground,
            droppedAlpha: sources.contains { $0.alpha < 1 }
        )
    }

    private static func applyColors(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) {
        let lightPalette = palette(light, fallback: nil) ?? Palette(
            background: 0xF4F5F7, text: 0x333333, bar: 0xFFFFFF,
            accent: 0x007AFF, dialogue: 0xD8E9FB, droppedAlpha: false
        )
        let darkPalette = dark.flatMap { palette($0, fallback: nil) }

        result.themeFile = AppearanceThemeExportFile(
            format: AppearanceThemeExportFile.formatIdentifier,
            version: 1,
            name: result.name,
            backgroundHex: lightPalette.background,
            textHex: lightPalette.text,
            barHex: lightPalette.bar,
            accentHex: lightPalette.accent,
            dialogueHex: lightPalette.dialogue,
            pageBackgrounds: nil,
            darkBackgroundHex: darkPalette?.background,
            darkTextHex: darkPalette?.text,
            darkBarHex: darkPalette?.bar,
            darkAccentHex: darkPalette?.accent,
            darkDialogueHex: darkPalette?.dialogue
        )

        if lightPalette.droppedAlpha || darkPalette?.droppedAlpha == true {
            notes.append(localized("主題顏色的透明度沒有對應設定，已以不透明顏色套用。"))
        }
        // Reeden has two text levels (foreground / muted foreground); ours are three, and
        // a partial trio is not applied (see `AppearanceCustomTheme.textColors`).
        if light.foregroundColor != nil || light.mutedForegroundColor != nil {
            notes.append(localized("全域文字顏色需要主要／次要／第三階三個都提供才會套用，這個外觀包只給了一部分。"))
        }
    }

    // MARK: - Page background

    private static func applyPageBackground(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport
    ) {
        let lightImage = light.backgroundImage == nil
            ? nil : QiThemeImporter.imagePayload(at: "light/theme_bg.img", rootURL: root)
        let darkImage = dark?.backgroundImage == nil
            ? nil : QiThemeImporter.imagePayload(at: "dark/theme_bg.img", rootURL: root)
        guard lightImage != nil || darkImage != nil else { return }
        let payload = AppearanceThemeExportFile.PageBackgroundPayload(
            lightPrimaryHex: ReedenValue.rgb(light.backgroundColor),
            lightSecondaryHex: nil,
            darkPrimaryHex: dark.flatMap { ReedenValue.rgb($0.backgroundColor) },
            darkSecondaryHex: nil,
            lightImage: lightImage.map(normalizedExtension),
            darkImage: darkImage.map(normalizedExtension),
            lightImageOpacity: nil,
            darkImageOpacity: nil
        )
        let key = AppearancePageBackgroundScope.global.rawValue
        result.pageBackgrounds[key] = payload
        result.themeFile?.pageBackgrounds = [key: payload]
    }

    /// Reeden names every picture `.img`; the stores key the file type off the extension,
    /// so the real one is read from the bytes.
    private static func normalizedExtension(
        _ payload: AppearanceThemeExportFile.ImagePayload
    ) -> AppearanceThemeExportFile.ImagePayload {
        guard let data = Data(base64Encoded: payload.base64) else { return payload }
        var copy = payload
        copy.fileExtension = imageExtension(of: data) ?? payload.fileExtension
        return copy
    }

    private static func imageFile(at path: String, root: URL) -> QiThemeImport.ImageFile? {
        guard var file = QiThemeImporter.imageFile(at: path, rootURL: root) else { return nil }
        if (file.fileName as NSString).pathExtension.lowercased() == "img",
           let ext = imageExtension(of: file.data) {
            file.fileName = ((file.fileName as NSString).deletingPathExtension as NSString)
                .appendingPathExtension(ext) ?? file.fileName
        }
        return file
    }

    static func imageExtension(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if head.count >= 12, head[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], head[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return nil
    }

    // MARK: - Cards

    private static func applyCards(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport
    ) {
        let lightImage = light.cardBackgroundImage == nil
            ? nil : imageFile(at: "light/card_bg.img", root: root)
        let darkImage = dark?.cardBackgroundImage == nil
            ? nil : imageFile(at: "dark/card_bg.img", root: root)
        let lightLayer = cardLayer(light, image: lightImage)
        let darkLayer = dark.map { cardLayer($0, image: darkImage) } ?? AppearanceCardBackgroundLayer()
        let card = AppearanceCardBackground(isEnabled: true, light: lightLayer, dark: darkLayer)
        guard !card.isEmpty else { return }
        result.cardBackground = card
        result.cardBackgroundImage = lightImage
        result.darkCardBackgroundImage = darkImage
    }

    /// `cardColor` is the card surface, often translucent over the page artwork
    /// (粉色小窝 `#9FFFECEF`): the layer's fill opacity is the one place that alpha can go.
    private static func cardLayer(
        _ variant: ReedenThemeVariant,
        image: QiThemeImport.ImageFile?
    ) -> AppearanceCardBackgroundLayer {
        let fill = ReedenValue.color(variant.cardColor)
        let border = variant.cardBorder == true ? ReedenValue.color(variant.borderColor) : nil

        var mode = AppearanceCardBackgroundLayer.Mode.stretch
        var insets = (top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
        if let image, variant.cardBackgroundImageFit == "nineSlice",
           let center = variant.cardBackgroundImageCenterSlice,
           let size = QiThemeImporter.pixelSize(of: image.data) {
            // Reeden stores the stretchable centre as a rectangle; ours are the caps
            // around it, as fractions of the image.
            mode = .nineSlice
            let width = Double(size.width)
            let height = Double(size.height)
            insets = (
                top: (center.top ?? 0) / height,
                left: (center.left ?? 0) / width,
                bottom: max(0, height - (center.bottom ?? height)) / height,
                right: max(0, width - (center.right ?? width)) / width
            )
        }
        return AppearanceCardBackgroundLayer(
            mode: mode,
            sliceTop: insets.top,
            sliceLeft: insets.left,
            sliceBottom: insets.bottom,
            sliceRight: insets.right,
            fillHex: fill?.rgb,
            fillOpacity: fill?.alpha ?? 1,
            borderHex: border?.rgb,
            borderWidth: border == nil ? 0 : 1,
            borderOpacity: border?.alpha ?? 1
        )
    }

    // MARK: - Tab icons

    /// Reeden's six tabs against our five (decided 2026-10-11): 首頁 is the discovery page,
    /// so it lands on 探索; 功能 on RSS. 筆記 and 統計 have no tab here, and 搜索 keeps its
    /// system icon because no Reeden tab is a search page.
    static func tabIdentifier(for reedenTab: String) -> String? {
        switch reedenTab {
        case "bookshelf": return "bookshelf"
        case "home": return "explore"
        case "feature": return "rss"
        case "settings": return "settings"
        default: return nil
        }
    }

    private static func applyTabIcons(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) async {
        guard let lightPack = light.navbarPackId else { return }
        var skipped: Set<String> = []
        var hasSelected = false
        result.tabIcons = await tabIcons(
            pack: lightPack, root: root, skipped: &skipped, hasSelected: &hasSelected
        )
        if let darkPack = dark?.navbarPackId, darkPack != lightPack {
            result.darkTabIcons = await tabIcons(
                pack: darkPack, root: root, skipped: &skipped, hasSelected: &hasSelected
            )
        }
        for tab in skipped.sorted() {
            notes.append(String(format: localized("分頁圖示「%@」在本 App 沒有對應的分頁，已略過。"), tab))
        }
        if hasSelected {
            notes.append(localized("選中狀態的分頁圖示未套用：本 App 的分頁圖示分淺色／深色，沒有選中態。"))
        }
    }

    private static func tabIcons(
        pack: String,
        root: URL,
        skipped: inout Set<String>,
        hasSelected: inout Bool
    ) async -> [QiThemeImport.TabIconImport] {
        let directory = "navbar_pack/\(pack)"
        guard let directoryURL = try? ReaderStylePackage.containedURL(for: directory, under: root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        var icons: [QiThemeImport.TabIconImport] = []
        for name in names.sorted() {
            let base = (name as NSString).deletingPathExtension
            if base.hasSuffix("_selected") {
                hasSelected = true
                continue
            }
            guard base.hasSuffix("_normal") else { continue }
            let tab = String(base.dropLast("_normal".count))
            guard let tabID = tabIdentifier(for: tab) else {
                skipped.insert(tab)
                continue
            }
            guard let image = await tabIconImage(at: "\(directory)/\(name)", root: root) else { continue }
            icons.append(QiThemeImport.TabIconImport(tabID: tabID, image: image))
        }
        return icons
    }

    /// The tab-icon store decodes with `UIImage(data:)`, which cannot read SVG — and
    /// 粉色小窝's icons are SVG. They go through the app's existing SVG rasterizer.
    private static func tabIconImage(at path: String, root: URL) async -> QiThemeImport.ImageFile? {
        guard (path as NSString).pathExtension.lowercased() == "svg" else {
            return imageFile(at: path, root: root)
        }
        guard let url = try? ReaderStylePackage.containedURL(for: path, under: root),
              let svg = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let rasterizer = await SVGWebViewRasterizer.shared
        let size = await rasterizer.resolveSVGSize(
            styleWidth: nil, styleHeight: nil, svgString: svg, renderWidth: 180
        )
        guard let image = await rasterizer.render(svgString: svg, size: size),
              let png = image.pngData() else {
            AppLogger.parse("⟐ red tab icon SVG did not rasterize", context: ["path": path])
            return nil
        }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return QiThemeImport.ImageFile(data: png, fileName: "\(name).png")
    }

    // MARK: - Covers & splash

    private static func applyCovers(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport
    ) {
        if let gallery = light.coverGalleryId {
            result.defaultCovers = covers(gallery: gallery, root: root)
        }
        if let gallery = dark?.coverGalleryId, gallery != light.coverGalleryId {
            result.darkDefaultCovers = covers(gallery: gallery, root: root)
        }
    }

    /// `1.jpg`, `2.jpg` … in their numeric order, beside a `meta.json`.
    private static func covers(gallery: String, root: URL) -> [QiThemeImport.ImageFile] {
        let directory = "cover_gallery/\(gallery)"
        guard let directoryURL = try? ReaderStylePackage.containedURL(for: directory, under: root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        return names
            .filter { ($0 as NSString).pathExtension.lowercased() != "json" }
            .sorted { lhs, rhs in
                let l = Int((lhs as NSString).deletingPathExtension) ?? .max
                let r = Int((rhs as NSString).deletingPathExtension) ?? .max
                return l == r ? lhs < rhs : l < r
            }
            .compactMap { imageFile(at: "\(directory)/\($0)", root: root) }
    }

    private static func applySplash(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) {
        guard let lightID = light.customSplashId else { return }
        let lightSplash = splash(id: lightID, root: root, notes: &notes)
        result.launchImage = lightSplash?.image
        result.launchEnabled = lightSplash?.enabled
        if let darkID = dark?.customSplashId, darkID != lightID {
            result.darkLaunchImage = splash(id: darkID, root: root, notes: &notes)?.image
        }
    }

    private static func splash(
        id: String,
        root: URL,
        notes: inout [String]
    ) -> (image: QiThemeImport.ImageFile, enabled: Bool?)? {
        let directory = "custom_splash/\(id)"
        guard let directoryURL = try? ReaderStylePackage.containedURL(for: directory, under: root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return nil
        }
        let meta = (try? Data(contentsOf: directoryURL.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(ReedenSplashMeta.self, from: $0) }
        if let type = meta?.assetType, type != "image" {
            notes.append(localized("啟動畫面不是圖片（例如影片），本 App 只支援圖片，已略過。"))
            return nil
        }
        guard let asset = names.first(where: { ($0 as NSString).deletingPathExtension == "asset" }),
              let image = imageFile(at: "\(directory)/\(asset)", root: root) else {
            return nil
        }
        return (image, meta?.enabled)
    }

    // MARK: - Reading page

    private static func applyReaderSchemas(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        root: URL,
        into result: inout QiThemeImport,
        notes: inout [String]
    ) async {
        guard let lightID = light.readerColorSchemaId,
              let lightSchema = readerSchema(id: lightID, root: root) else {
            return
        }
        result.readerBackground = lightSchema.backgroundImageUrl == nil
            ? nil : imageFile(at: "reader_schema/\(lightID)/bg.img", root: root)
        result.readerBackgroundColorHex = ReedenValue.rgb(lightSchema.backgroundColor)
        result.readerTextColorHex = ReedenValue.rgb(lightSchema.textColor)
        var adjusted = isAdjustedPicture(lightSchema)
        var darkSchema: ReedenReaderSchema?

        if let darkID = dark?.readerColorSchemaId, darkID != lightID,
           let schema = readerSchema(id: darkID, root: root) {
            darkSchema = schema
            result.darkReaderBackground = schema.backgroundImageUrl == nil
                ? nil : imageFile(at: "reader_schema/\(darkID)/bg.img", root: root)
            result.darkReaderBackgroundColorHex = ReedenValue.rgb(schema.backgroundColor)
            result.darkReaderTextColorHex = ReedenValue.rgb(schema.textColor)
            adjusted = adjusted || isAdjustedPicture(schema)
        }
        if adjusted {
            notes.append(localized("閱讀背景圖的透明度與模糊沒有對應設定，已以原圖套用。"))
        }

        // The layout is the light schema's: Reeden keeps one layout per theme and repeats
        // it in each schema.
        guard let configText = lightSchema.layoutConfig,
              let configData = configText.data(using: .utf8) else {
            return
        }
        let config: ReedenLayoutConfig
        do {
            config = try JSONDecoder().decode(ReedenLayoutConfig.self, from: configData)
        } catch {
            AppLogger.parse("⟐ red layoutConfig unreadable", error: error)
            notes.append(localized("排版參數無法讀取，其餘項目仍已匯入。"))
            return
        }
        result.layoutConfig = layoutConfig(config, name: lightSchema.name, notes: &notes)
        var title = chapterTitleStyle(config)
        if let bound = lightSchema.boundTitleStyle {
            title = chapterTitleStyle(
                bound,
                base: title ?? .default,
                bodySize: config.fontSize,
                light: lightSchema,
                dark: darkSchema,
                notes: &notes
            ) ?? title
        }
        result.chapterTitleStyle = title
        result.highlightRules = await highlightRules(
            (lightSchema.boundHighlightRules ?? []).compactMap(\.rule),
            light: lightSchema,
            dark: darkSchema,
            bodySize: config.fontSize,
            assetStore: .shared,
            notes: &notes
        )

        if config.fontFamily != nil || config.titleFontFamily != nil {
            notes.append(localized("主題包只記錄了 Reeden 字型庫的編號，沒有附帶字型檔，正文與標題仍使用原本的字型。"))
        }
    }

    private static func readerSchema(id: String, root: URL) -> ReedenReaderSchema? {
        let path = "reader_schema/\(id)/schema.json"
        guard let url = try? ReaderStylePackage.containedURL(for: path, under: root) else { return nil }
        do {
            return try JSONDecoder().decode(ReedenReaderSchema.self, from: Data(contentsOf: url))
        } catch {
            AppLogger.parse("⟐ red reader schema unreadable", error: error, context: ["path": path])
            return nil
        }
    }

    private static func isAdjustedPicture(_ schema: ReedenReaderSchema) -> Bool {
        guard schema.backgroundImageUrl != nil else { return false }
        return (schema.backgroundImageOpacity ?? 1) < 1 || (schema.backgroundImageBlur ?? 0) > 0
    }

    /// Reeden's turn types against legado's `pageAnim`. Only values seen in real packs are
    /// listed; anything else is named in a note rather than guessed. `none` has no
    /// `pageAnim`: the layout parser reads legado's values only, and legado has no "no
    /// animation" (see `ReaderLayoutPresetExporter.pageAnim`), so it is reported instead.
    static func pageAnim(forTurnPageType raw: String?) -> Int? {
        switch raw {
        case "simulation": return 2
        case "cover": return 1
        default: return nil
        }
    }

    /// Into legado's `readConfig.json` shape, so `ReaderLayoutPresetImporter` — the app's one
    /// layout parser — reads it.
    ///
    /// Reeden documents no units. Its lengths are taken as points: Reeden is a Flutter app,
    /// whose logical pixels are iOS points, and the values only make sense that way —
    /// `lineSpacing` 10–16 beside a `fontSize` of 15–19.6 is an added gap, not a multiple.
    /// Negative values (dragged past the edge in Reeden's margin editor) are clamped to 0.
    static func layoutConfig(
        _ config: ReedenLayoutConfig,
        name: String?,
        notes: inout [String]
    ) -> Data? {
        var translated = QiTranslatedReadConfig()
        translated.name = name
        translated.textSize = config.fontSize
        translated.lineSpacingExtra = config.lineSpacing.map { max(0, $0) }
        translated.paragraphSpacing = config.paragraphSpacing.map { max(0, $0) }
        translated.letterSpacing = config.letterSpacing
        translated.paddingLeft = config.paddingLeft.map { max(0, $0) }
        translated.paddingRight = config.paddingRight.map { max(0, $0) }
        translated.pageAnim = pageAnim(forTurnPageType: config.turnPageType)

        if let left = config.paddingLeft, let right = config.paddingRight, abs(left - right) >= 1 {
            notes.append(localized("左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。"))
        }
        if let indent = config.paragraphIndent, indent != "defaults", indent != "double" {
            notes.append(localized("首行縮排固定為兩字元，無法調整，已略過。"))
        }
        if let align = config.contentAlign, align != "defaults" {
            notes.append(localized("正文對齊方式固定為兩端對齊，已略過。"))
        }
        if config.turnPageType == "none" {
            notes.append(localized("主題設定的「無動畫」翻頁無法隨排版匯入，已保留原本的翻頁方式。"))
        } else if let type = config.turnPageType, translated.pageAnim == nil {
            notes.append(String(format: localized("翻頁方式「%@」無法辨識，已保留原本設定。"), type))
        }

        guard translated.hasAnyValue else { return nil }
        do {
            return try JSONEncoder().encode(translated)
        } catch {
            AppLogger.parse("⟐ red layout encode failed", error: error)
            return nil
        }
    }

    /// The generated chapter title's plain settings. `txtTitleFontSizeDiff` is the title's
    /// size above the body for TXT and online books — the books whose titles we generate.
    static func chapterTitleStyle(_ config: ReedenLayoutConfig) -> ChapterTitleStyle? {
        var style = ChapterTitleStyle.default
        var changed = false
        if let align = config.titleAlign, let mapped = ChapterTitleAlignment(rawValue: align) {
            style.alignment = mapped
            changed = true
        }
        if let top = config.titleMarginTop {
            style.topSpacing = CGFloat(max(0, top))
            changed = true
        }
        if let bottom = config.titlePaddingBottom {
            style.bottomSpacing = CGFloat(max(0, bottom))
            changed = true
        }
        if let body = config.fontSize, let diff = config.txtTitleFontSizeDiff {
            style.size = CGFloat(body + diff)
            changed = true
        }
        if config.titleBoldEnabled == true {
            style.weight = .bold
            changed = true
        }
        return changed ? style.sanitized() : nil
    }

    // MARK: - Reeden CSS

    /// Reeden's style CSS refers to the reading schema's colours by placeholder, and names
    /// fonts from its own font store (`"reeden-font:<id>"`), which never travel with a pack.
    static func resolvedCSS(
        _ css: String,
        schema: ReedenReaderSchema,
        bodySize: Double?,
        convertsEm: Bool
    ) -> [(name: String, value: String)] {
        var source = css
        let colors: [(String, String?)] = [
            ("{primaryColor}", schema.primaryColor),
            ("{textColor}", schema.textColor),
            ("{backgroundColor}", schema.backgroundColor),
        ]
        for (placeholder, color) in colors {
            let rgb = ReedenValue.rgb(color).map { String(format: "#%06X", $0) } ?? "inherit"
            source = source.replacingOccurrences(of: placeholder, with: rgb)
        }
        var declarations: [(name: String, value: String)] = []
        for raw in source.split(separator: ";") {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = raw[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            declarations.append((name, value))
        }
        guard convertsEm, let bodySize else { return declarations }
        // CSS `em`: a `font-size` is relative to the paragraph (the body size); every other
        // length is relative to the element's own size. Reeden's frames rely on it — their
        // padding is the artwork's content window measured in the rule's font size.
        let elementSize: Double = {
            guard let raw = declarations.last(where: { $0.name == "font-size" })?.value else { return bodySize }
            let pixels = emToPixels(raw, bodySize: bodySize)
            guard pixels.hasSuffix("px"), let size = Double(pixels.dropLast(2)) else { return bodySize }
            return size
        }()
        return declarations.map { declaration in
            let base = declaration.name == "font-size" ? bodySize : elementSize
            return (declaration.name, emToPixels(declaration.value, bodySize: base))
        }
    }

    /// `0.9688em` → `14.53px` against `bodySize`, the size `em` refers to. The
    /// regex-highlight codec takes absolute lengths only.
    private static func emToPixels(_ value: String, bodySize: Double) -> String {
        value.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let text = String(token)
            guard text.hasSuffix("em"), !text.hasSuffix("rem"),
                  let number = Double(text.dropLast(2)) else { return text }
            return String(format: "%.2fpx", number * bodySize)
        }.joined(separator: " ")
    }

    private static func isReedenFont(_ value: String) -> Bool {
        value.contains("reeden-font:")
    }

    // MARK: - Highlight rules

    /// A rule's style is CSS; the parts the regex-highlight codec reads are kept and the rest
    /// is named in a note. Artwork travels in `backgroundImageData` and is stored as a style
    /// asset, its nine-slice frame carried over. Rules that depend on what cannot be
    /// reproduced — floated drop caps, title-only matching — are skipped whole rather than
    /// imported half-drawn.
    static func highlightRules(
        _ source: [ReedenHighlightRule],
        light: ReedenReaderSchema,
        dark: ReedenReaderSchema?,
        bodySize: Double?,
        assetStore: ReaderStyleAssetStore,
        notes: inout [String]
    ) async -> [RegexHighlightRule] {
        var rules: [RegexHighlightRule] = []
        var skipped: [String] = []
        var unreadableArtwork: [String] = []
        var dropped: Set<String> = []
        for rule in source {
            let name = rule.name?.trimmedNonEmpty ?? localized("高亮規則")
            let css = rule.styleCssText ?? ""
            let titleOnly = rule.titleOnly == true || rule.target == "title"
            guard let keyword = rule.keyword, !keyword.isEmpty,
                  !css.contains("float:"), !titleOnly, (rule.styleMode ?? "advanced") == "advanced" else {
                skipped.append(name)
                continue
            }
            let pattern = rule.isRegex == false
                ? NSRegularExpression.escapedPattern(for: keyword)
                : keyword
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                AppLogger.parse("⟐ red highlight pattern invalid", error: error, context: ["rule": name])
                skipped.append(name)
                continue
            }
            var artwork: HighlightArtwork?
            if css.contains("background-image") {
                do {
                    artwork = try await highlightArtwork(rule, css: css, name: name, assetStore: assetStore)
                } catch {
                    AppLogger.parse("⟐ red highlight artwork unreadable", error: error, context: ["rule": name])
                    unreadableArtwork.append(name)
                    continue
                }
            }
            let lightStyle = highlightStyle(
                css, schema: light, bodySize: bodySize, artwork: artwork, dropped: &dropped
            )
            let darkStyle = dark.map {
                highlightStyle(css, schema: $0, bodySize: bodySize, artwork: artwork, dropped: &dropped)
            } ?? lightStyle
            rules.append(RegexHighlightRule(
                id: UUID().uuidString,
                name: name,
                pattern: pattern,
                isEnabled: rule.enabled ?? true,
                isBuiltIn: false,
                options: rule.isMultiline == true ? [] : [.doesNotCrossParagraph],
                lightStyle: lightStyle,
                darkStyle: darkStyle
            ))
        }
        if !skipped.isEmpty {
            notes.append(String(
                format: localized("下列高亮規則需要首字下沉或只套用於標題，本 App 無法重現，已略過：%@"),
                skipped.joined(separator: localized("、"))
            ))
        }
        if !unreadableArtwork.isEmpty {
            notes.append(String(
                format: localized("下列高亮規則的背景圖片無法讀取，已略過：%@"),
                unreadableArtwork.joined(separator: localized("、"))
            ))
        }
        if !dropped.isEmpty {
            notes.append(String(
                format: localized("高亮規則的下列樣式沒有對應設定，已略過：%@"),
                dropped.sorted().joined(separator: localized("、"))
            ))
        }
        return rules
    }

    struct HighlightArtwork: Equatable {
        var assetID: UUID
        var slices: ReaderStyleImageSlices?
    }

    enum HighlightArtworkError: Error {
        case missingImageData
        case notBase64
        case notAnImage
    }

    /// The rule's picture — base64 of a gzip member holding the image file — stored as a
    /// style asset, with its nine-slice frame as fractions of the picture's own size.
    private static func highlightArtwork(
        _ rule: ReedenHighlightRule,
        css: String,
        name: String,
        assetStore: ReaderStyleAssetStore
    ) async throws -> HighlightArtwork {
        guard let encoded = rule.backgroundImageData else { throw HighlightArtworkError.missingImageData }
        guard let packed = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw HighlightArtworkError.notBase64
        }
        let image = GzipDecoder.isGzip(packed)
            ? try GzipDecoder.decompress(packed, maximumBytes: ReaderStyleAssetStore.maximumInputBytes)
            : packed
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw HighlightArtworkError.notAnImage
        }
        let asset = try await assetStore.importImage(data: image, suggestedName: name)
        return HighlightArtwork(
            assetID: asset.id,
            slices: nineSlice(css, imageSize: CGSize(width: width, height: height))
        )
    }

    /// `reeden-background-nine-slice: x1 y1 x2 y2 / W H [/ content rect]` — the stretchable
    /// centre as a rectangle in a `W`×`H` picture. The `--reeden-…` custom property beside
    /// it in some packs is an editor leftover; only the unprefixed one is read.
    static func nineSlice(_ css: String, imageSize: CGSize) -> ReaderStyleImageSlices? {
        let declaration = css.split(separator: ";").compactMap { raw -> String? in
            guard let colon = raw.firstIndex(of: ":"),
                  raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    == "reeden-background-nine-slice" else { return nil }
            return String(raw[raw.index(after: colon)...])
        }.last
        guard let declaration else { return nil }
        let groups = declaration.split(separator: "/").map {
            $0.split(separator: " ").compactMap { Double($0) }
        }
        guard let centre = groups.first, centre.count == 4 else { return nil }
        var size = imageSize
        if groups.count > 1, groups[1].count == 2, groups[1][0] > 0, groups[1][1] > 0 {
            size = CGSize(width: groups[1][0], height: groups[1][1])
        }
        return ReaderStyleImageSlices(
            pixelsTop: centre[1],
            right: Double(size.width) - centre[2],
            bottom: Double(size.height) - centre[3],
            left: centre[0],
            of: size
        )
    }

    private static func highlightStyle(
        _ css: String,
        schema: ReedenReaderSchema,
        bodySize: Double?,
        artwork: HighlightArtwork?,
        dropped: inout Set<String>
    ) -> ReaderStyleRuleStyle {
        var declarations = resolvedCSS(css, schema: schema, bodySize: bodySize, convertsEm: true)
        // The weight was picked for the Reeden font named beside it; on our font it would
        // draw a different face (100 is hairline in the system font), so it goes with it.
        let usesReedenFont = declarations.contains { $0.name == "font-family" && isReedenFont($0.value) }
        declarations.removeAll { declaration in
            let unusable = (declaration.name == "font-family" && isReedenFont(declaration.value))
                || (usesReedenFont && declaration.name == "font-weight")
            if unusable { dropped.insert(declaration.name) }
            // Carried by `artwork` instead.
            return unusable || declaration.name.hasSuffix("reeden-background-nine-slice")
        }
        if let artwork {
            declarations = declarations.map { declaration in
                guard declaration.name == "background-image" else { return declaration }
                return (declaration.name, "url(yuedu-asset://\(artwork.assetID.uuidString.lowercased()))")
            }
            if let slices = artwork.slices {
                let values = [slices.top, slices.right, slices.bottom, slices.left]
                    .map { String(format: "%.4f%%", $0 * 100) }
                declarations.append(("-yuedu-background-slice", values.joined(separator: " ")))
            }
        }
        return ReaderStyleCSSCodec.decodeLeniently(declarations, context: .regexHighlight, dropped: &dropped)
    }

    // MARK: - Title style

    /// Reeden's title styles are CSS for a container, the chapter number and the title.
    /// They become our chapter-title HTML template, rendered by the same engine as the
    /// built-in CSS presets. The template's `em` is the title's root size, so the root is
    /// set to the body size Reeden's `em` refers to.
    static func chapterTitleStyle(
        _ bound: ReedenTitleStyle,
        base: ChapterTitleStyle,
        bodySize: Double?,
        light: ReedenReaderSchema,
        dark: ReedenReaderSchema?,
        notes: inout [String]
    ) -> ChapterTitleStyle? {
        guard bound.layout == "numberTitle" else {
            notes.append(String(
                format: localized("標題樣式「%@」的版型無法辨識，只套用了標題的對齊、大小與間距。"),
                bound.name ?? bound.layout ?? ""
            ))
            return nil
        }
        var dropped: Set<String> = []
        let alignment = base.alignment.rawValue
        let lightTemplate = titleTemplate(bound, schema: light, alignment: alignment, dropped: &dropped)
        let darkTemplate = dark.map {
            titleTemplate(bound, schema: $0, alignment: alignment, dropped: &dropped)
        } ?? lightTemplate

        var style = base
        style.advancedCSSEnabled = true
        style.lightTemplate = lightTemplate
        style.darkTemplate = darkTemplate
        if let bodySize { style.size = CGFloat(bodySize) }
        if !dropped.isEmpty {
            notes.append(String(
                format: localized("標題樣式的下列設定沒有對應項目，已略過：%@"),
                dropped.sorted().joined(separator: localized("、"))
            ))
        }
        return style.sanitized()
    }

    private static func titleTemplate(
        _ bound: ReedenTitleStyle,
        schema: ReedenReaderSchema,
        alignment: String,
        dropped: inout Set<String>
    ) -> String {
        func inline(_ css: String?) -> String {
            let declarations = resolvedCSS(css ?? "", schema: schema, bodySize: nil, convertsEm: false)
                .filter { declaration in
                    // Reeden-only properties, its font store, and `display` — the template's
                    // own structure decides block versus inline.
                    let unusable = declaration.name.hasPrefix("reeden-")
                        || declaration.name.hasPrefix("-webkit-")
                        || declaration.name == "display"
                        || (declaration.name == "font-family" && isReedenFont(declaration.value))
                    if unusable, declaration.name != "display" { dropped.insert(declaration.name) }
                    return !unusable
                }
            return declarations.map { "\($0.name):\($0.value)" }.joined(separator: ";")
                .replacingOccurrences(of: "\"", with: "'")
        }
        return "<div style=\"text-align:\(alignment);\(inline(bound.containerCss))\">"
            + "<div><span style=\"\(inline(bound.numberCss))\">{number}</span></div>"
            + "<div style=\"\(inline(bound.titleCss))\">{name}</div>"
            + "</div>"
    }

    // MARK: - Unmapped

    private static func appendUnmappedAppearanceNotes(
        light: ReedenThemeVariant,
        dark: ReedenThemeVariant?,
        to notes: inout [String]
    ) {
        let variants = [light] + (dark.map { [$0] } ?? [])
        func any(_ test: (ReedenThemeVariant) -> Bool) -> Bool { variants.contains(where: test) }

        var unmapped: [String] = []
        if any({ $0.bookshelfCarouselImageUrls?.isEmpty == false }) {
            unmapped.append(localized("書架輪播圖"))
        }
        if any({ $0.popoverColor != nil || $0.dialogBackgroundColor != nil
            || $0.dialogBackgroundBlur != nil || $0.popoverBackgroundBlur != nil }) {
            unmapped.append(localized("彈出視窗與對話框配色"))
        }
        if any({ $0.inputBackgroundColor != nil || $0.inputBorderColor != nil
            || $0.searchFieldBackgroundColor != nil || $0.searchFieldBorder != nil }) {
            unmapped.append(localized("輸入框與搜尋框配色"))
        }
        if any({ $0.shelfColor != nil }) { unmapped.append(localized("書架底色")) }
        if any({ $0.tabBorder != nil || $0.switchBorder != nil }) {
            unmapped.append(localized("分頁列與開關邊框"))
        }
        if any({ $0.cardShadow != nil || ($0.cardRadius ?? 0) > 0 }) {
            unmapped.append(localized("卡片圓角與陰影"))
        }
        if any({ ($0.themeEffectType ?? "none") != "none" }) { unmapped.append(localized("主題動態特效")) }
        if any({ ($0.audiobookSkinId ?? "follow") != "follow" }) { unmapped.append(localized("聽書介面樣式")) }
        guard !unmapped.isEmpty else { return }
        notes.append(String(
            format: localized("以下項目本 App 沒有對應設定，已略過：%@"),
            unmapped.joined(separator: localized("、"))
        ))
    }
}

/// Shared by the Reeden and highlight-pack importers.
extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
