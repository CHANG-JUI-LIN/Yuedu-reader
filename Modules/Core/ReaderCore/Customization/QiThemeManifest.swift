import Foundation

/// Decodable mirror of QiReader's `.qitheme` / `.qipreset` JSON, reverse-engineered from
/// three real packages (`古风`, `山风-与花同月`, `自制- 江湖侠客`).
///
/// Two rules govern everything in this file:
///
/// 1. **Every field is optional.** Comparing the key sets of the three samples, only
///    `id` and `name` appear in all of them; `cardBackground`, `splashEnabled`,
///    `selectedTabIcons`, `readerToolbarIconSize` and a dozen others appear in one and
///    not the others. A required field here would reject a perfectly good pack.
/// 2. **Nothing is interpreted here.** These types carry QiReader's vocabulary verbatim —
///    including Simplified-Chinese enum raw values like `"滑动"` — and `QiThemeImporter`
///    owns every translation into ours. Keeping the two apart is what makes the alias
///    tables testable and stops their vocabulary leaking into our models.
enum QiTheme {}

// MARK: - App-level manifest (`<UUID>/manifest.json`)

struct QiThemeManifest: Decodable, Sendable {
    var id: String?
    var name: String?
    var isBuiltIn: Bool?

    // Colors
    var accentColorHex: String?
    var darkAccentColorHex: String?
    var primaryTextColorHex: String?
    var secondaryTextColorHex: String?
    var tertiaryTextColorHex: String?
    var darkPrimaryTextColorHex: String?
    var darkSecondaryTextColorHex: String?
    var darkTertiaryTextColorHex: String?

    // Backgrounds
    var defaultBackground: QiThemeBackground?
    /// Keyed by QiReader tab name (`search`, `settings`, …).
    var tabBackgrounds: [String: QiThemeBackground]?

    // Tab bar
    var tabIcons: [String: QiThemeIcon]?
    var selectedTabIcons: [String: QiThemeIcon]?
    var tabIconSize: Double?
    var hideTabText: Bool?

    // Covers & splash
    var coverImageFiles: [String]?
    var forceDefaultCover: Bool?
    var coverCornerRadius: Double?
    var splashEnabled: Bool?
    var splashImageFiles: [String]?

    // Font
    var fontFamily: String?
    var fontFiles: [String]?

    // Interface effects
    var enableFrostedGlass: Bool?
    var disableGlassEffect: Bool?
    var frostedGlassOpacity: Double?
    var transparentModeOpacity: Double?
    var glowIntensity: Double?

    // Bookshelf
    var bookshelfGridColumnCount: Int?
    var bookshelfHeaderStyle: String?
    var bookshelfListCardHeight: Double?
    var bookshelfShowsTags: Bool?
    var bookshelfTagTextColorMode: String?
    var bookshelfTagCustomTextColorHex: String?

    // Reader chrome
    var readerBottomToolbarStyle: String?
    var readerToolbarIconSize: Double?
    var readerToolbarCardsFollowAppearance: Bool?
    var progressBarsFollowAppearance: Bool?

    /// Nine-slice card artwork. Decoded so the importer can *report* it as unmapped;
    /// we have no app-level card background to put it in.
    var cardBackground: QiThemeCardBackground?
}

/// A page background. Field-for-field the same eight values as our own
/// `AppearancePageBackgroundConfig`, which is why this half maps losslessly.
struct QiThemeBackground: Decodable, Sendable {
    var lightPrimaryColorHex: String?
    var lightSecondaryColorHex: String?
    var darkPrimaryColorHex: String?
    var darkSecondaryColorHex: String?
    var backgroundImageFile: String?
    var darkBackgroundImageFile: String?
    var backgroundImageOpacity: Double?
    var darkBackgroundImageOpacity: Double?
}

struct QiThemeIcon: Decodable, Sendable {
    /// Only `"custom"` has been observed; anything else has no artwork to import.
    var type: String?
    var imageFileName: String?
}

struct QiThemeCardBackground: Decodable, Sendable {
    var isEnabled: Bool?
    var backgroundImageFile: String?
    var darkBackgroundImageFile: String?
    var backgroundOpacity: Double?
    var cornerRadius: Double?
    /// `"stretch"` or `"nineSlice"`.
    var lightImageMode: String?
    var darkImageMode: String?
    var lightBackgroundColorHex: String?
    var darkBackgroundColorHex: String?
    var lightBorderColorHex: String?
    var darkBorderColorHex: String?
    var borderWidth: Double?
    var borderOpacity: Double?
    var lightLayout: QiThemeCardLayout?
    var darkLayout: QiThemeCardLayout?
}

struct QiThemeCardLayout: Decodable, Sendable {
    var opacity: Double?
    var sliceInsets: QiThemeInsets?
    var contentInsets: QiThemeInsets?
}

/// Pixel insets on the source artwork.
struct QiThemeInsets: Decodable, Sendable {
    var top: Double?
    var left: Double?
    var bottom: Double?
    var right: Double?
}

// MARK: - `reader_themes/manifest.json`

struct QiReaderThemeIndex: Decodable, Sendable {
    var formatVersion: Int?
    var bindings: [QiReaderThemeBinding]?
}

struct QiReaderThemeBinding: Decodable, Sendable {
    var presetFile: String?
    /// `"light"` or `"dark"` — which appearance slot the preset was bound to.
    var slot: String?
}

// MARK: - `.qipreset` manifest

struct QiPresetManifest: Decodable, Sendable {
    var formatVersion: Int?
    /// Filename inside the preset's own `assets/` directory.
    var backgroundAssetFileName: String?
    var preset: QiPreset?
    var chapterTitleStylePackage: QiChapterTitleStylePackage?
}

/// The reading-page settings. Note the `…Raw` fields hold **Simplified Chinese** display
/// strings as their serialized form (`"滑动"`, `"两端对齐"`, `"经典"`); our own enums use
/// Traditional or English raw values, so these can never be fed to `init(rawValue:)`.
struct QiPreset: Decodable, Sendable {
    var id: String?
    var name: String?
    var isBuiltIn: Bool?
    var isDark: Bool?

    var backgroundColorHex: String?
    var textColorHex: String?

    var fontFamily: String?
    var fontSize: Double?
    var fontWeightRaw: Double?
    var isBold: Bool?

    var lineSpacing: Double?
    var paragraphSpacing: Double?
    var paragraphSeparatorLines: Int?
    var letterSpacing: Double?
    var textIndent: Double?

    var leftPageMargin: Double?
    var rightPageMargin: Double?
    var topInsetExtra: Double?
    var bottomInsetExtra: Double?

    var textAlignmentRaw: String?
    var verticalJustify: Bool?
    var pageModeRaw: String?
    var layoutTemplateRaw: String?

    var textUnderlineEnabled: Bool?
    var textUnderlineModeRaw: String?
    var textUnderlinePatternRaw: String?
    var textUnderlineOffsetPt: Double?
    var textUnderlineThicknessPt: Double?
    var textUnderlineUsesTextColor: Bool?

    var widgetUseCustomFont: Bool?

    /// Base64-wrapped JSON blobs. `QiThemeImporter` decodes them through
    /// `QiThemeValue.decodeBase64JSON`; they are `String` here because that is
    /// genuinely how the file stores them.
    var layoutWidgetsData: String?
    var commentBubbleStyleData: String?
    var chapterTitleConfigData: String?
    var chapterTitleConfigDarkData: String?
}

// MARK: - Chapter title

struct QiChapterTitleStylePackage: Decodable, Sendable {
    var version: Int?
    var name: String?
    var light: QiChapterTitleVariant?
    var dark: QiChapterTitleVariant?
    var assets: [QiChapterTitleAsset]?
}

struct QiChapterTitleVariant: Decodable, Sendable {
    var isEnabled: Bool?
    var alignment: String?
    var assetIds: [String]?
    var topSpacing: Double?
    var bottomSpacing: Double?
    var chapterNameFont: String?
    var chapterNumberFont: String?
    var chapterNumberRegex: String?
    var fontSize: Double?
    /// `"light"`/`"regular"`/`"medium"`/`"semibold"`/`"bold"` — the same raw values our
    /// `ChapterTitleWeight` uses, so this one maps straight across.
    var fontWeight: String?
    var htmlHeight: Double?
    var htmlTemplate: String?
    var maxLines: Int?
    var showChapterName: Bool?
    var showFullTitle: Bool?
    var useCustomFont: Bool?
    var useHTMLMode: Bool?
    /// The visual designer's project, itself a JSON *string*.
    var designerProjectJSON: String?
}

struct QiChapterTitleAsset: Decodable, Sendable {
    var id: String?
    var fileName: String?
    var mimeType: String?
    /// Base64 image bytes, inlined in the manifest rather than stored as an archive entry.
    var data: String?
}

// MARK: - Chapter title designer project (`designerProjectJSON`)

struct QiDesignerProject: Decodable, Sendable {
    var schemaVersion: Int?
    var canvas: QiDesignerCanvas?
    var elements: [QiDesignerElement]?
}

struct QiDesignerCanvas: Decodable, Sendable {
    var height: Double?
    var css: [String: String]?
}

/// One absolutely-positioned element. `css` holds percentage geometry (`left`, `top`,
/// `width`, `height`), `z-index`, `transform: rotate(…)`, and text styling — the same
/// information our `ChapterTitleLayer` carries as typed fields.
struct QiDesignerElement: Decodable, Sendable {
    /// `"chapterNumber"`, `"chapterName"`, `"image"`.
    var type: String?
    var id: String?
    var content: String?
    var assetId: String?
    var locked: Bool?
    var visible: Bool?
    var css: [String: String]?
}

// MARK: - Comment bubble (`commentBubbleStyleData`)

struct QiBubbleStyle: Decodable, Sendable {
    var id: String?
    var name: String?
    var backgroundSVGData: String?
    var svgSizeMultiplier: Double?
    var svgFontScale: Double?
    var svgFixedWidth: Double?
    var svgFixedHeight: Double?
    var fillColorHex: String?
    /// `"AUTO"` means "follow the reading theme".
    var textColorHex: String?
    var cornerRadiusFraction: Double?
    var opacity: Double?
    var showLabel: Bool?
}

// MARK: - Reader overlay widgets (`layoutWidgetsData`)

struct QiLayoutWidget: Decodable, Sendable {
    var id: String?
    /// Simplified-Chinese widget name, e.g. `"章节名"`, `"本章进度(文字)"`.
    var item: String?
    var xPercent: Double?
    var yPercent: Double?
    var fontSize: Double?
    var opacity: Double?
    var customColorHex: String?
    /// `"左对齐"` / `"居中"` / `"右对齐"`.
    var textAlignment: String?
    /// `"仅首页"` / `"仅正文页"` — maps onto our `ReaderOverlayPageScope`.
    var pageScope: String?
}

// MARK: - Shared value parsing

enum QiThemeValue {
    /// Parses `"A1B4AA"` / `"#A1B4AA"` into our `0xRRGGBB` `UInt32`. Returns nil rather
    /// than a black fallback so a missing colour stays distinguishable from a real one.
    static func hex(_ string: String?) -> UInt32? {
        guard var text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") { text.removeFirst() }
        // 8-digit values are RRGGBBAA in this format; we keep only the colour.
        if text.count == 8 { text = String(text.prefix(6)) }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return value & 0xFFFFFF
    }

    /// `"24.9%"` → `0.249`. Percentages are how the designer stores every position and
    /// size, matching our normalized `0...1` rects.
    static func percentFraction(_ string: String?) -> Double? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasSuffix("%"),
              let value = Double(text.dropLast()) else {
            return nil
        }
        return value / 100
    }

    /// `"22px"` / `"22"` → `22`.
    static func pixels(_ string: String?) -> Double? {
        guard var text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix("px") { text.removeLast(2) }
        return Double(text.trimmingCharacters(in: .whitespaces))
    }

    /// `"rotate(12deg)"` → `12`. Any other transform (translate, scale, matrix) has no
    /// equivalent on our layers, so it yields nil and the caller records a note.
    static func rotationDegrees(_ string: String?) -> Double? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let open = text.firstIndex(of: "("),
              text.hasPrefix("rotate"),
              text.hasSuffix(")") else {
            return nil
        }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let digits = inner.replacingOccurrences(of: "deg", with: "")
        return Double(digits.trimmingCharacters(in: .whitespaces))
    }

    /// `"#RRGGBB"` in a CSS declaration.
    static func cssColor(_ string: String?) -> UInt32? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard text.hasPrefix("#") else { return nil }
        return hex(text)
    }

    /// Decodes one of the base64-wrapped JSON blobs (`layoutWidgetsData`,
    /// `commentBubbleStyleData`, …). Throws rather than returning nil so a corrupt blob
    /// is reported instead of silently importing as "this pack had no bubble".
    static func decodeBase64JSON<T: Decodable>(_ type: T.Type, from base64: String) throws -> T {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw QiThemeImportError.malformedNestedPayload
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
