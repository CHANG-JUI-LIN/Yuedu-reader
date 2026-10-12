import Foundation

// Schema of Reeden's `.red` app-theme packs, as observed in the packs this layer was built
// against (2026-10-11: 薄绿 - 维尼, 铭 - 粉色小窝, 山风 - 春水漾, 周一 - 米蓝, Fish·莞洣,
// 甜菜小月 - 汀花雨细). Reeden publishes no format document; every field is optional so a
// pack written by a newer Reeden still decodes, and unknown keys are ignored.
//
// Container: the 4 bytes `RED` + version, then the payload.
// - version 0x04: a plain ZIP. `theme.json` at its root names everything else by id —
//   `cover_gallery/<id>/`, `navbar_pack/<id>/`, `custom_splash/<id>/`,
//   `reader_schema/<id>/` — and the light/dark app backgrounds sit at the fixed paths
//   `light/theme_bg.img` and `dark/theme_bg.img`. Image references inside the JSON
//   (`backgroundImage`, `backgroundImageUrl`) are the uppercase MD5 of the file's bytes,
//   not paths.
// - version 0x10: a 4-byte big-endian length, a plaintext JSON header, then an
//   AES-GCM-encrypted manifest (`containerMode: "reedenPrivate"`). The key is Reeden's
//   own; such packs are recognised only so the user is told what they are.

struct ReedenThemeFile: Decodable {
    var name: String?
    var light: ReedenThemeVariant?
    var dark: ReedenThemeVariant?
}

/// One appearance of an app theme. Colours are `#AARRGGBB`.
struct ReedenThemeVariant: Decodable {
    var enabled: Bool?
    var author: String?
    var description: String?

    var primaryColor: String?
    var accentColor: String?
    var backgroundColor: String?
    var foregroundColor: String?
    var mutedForegroundColor: String?
    var cardColor: String?
    var cardForegroundColor: String?
    var mutedColor: String?
    var borderColor: String?
    var dividerColor: String?
    var popoverColor: String?
    var dialogBackgroundColor: String?
    var dialogBackgroundBlur: Double?
    var popoverBackgroundBlur: Double?
    var inputBackgroundColor: String?
    var inputBorderColor: String?
    var searchFieldBackgroundColor: String?
    var searchFieldBorder: Bool?
    var tabBackgroundColor: String?
    var tabBorder: Bool?
    var shelfColor: String?
    var switchBorder: Bool?
    var themeEffectType: String?
    var audiobookSkinId: String?

    var backgroundImage: String?
    var backgroundImageFit: String?
    var bookshelfCarouselImageUrls: [String]?

    var cardBorder: Bool?
    var cardRadius: Double?
    var cardShadow: Double?
    var cardBackgroundImage: String?
    var cardBackgroundImageFit: String?
    var cardBackgroundImageCenterSlice: ReedenRect?
    var cardBackgroundImageContentSlice: ReedenRect?

    var coverGalleryId: String?
    var navbarPackId: String?
    var customSplashId: String?
    var readerColorSchemaId: String?
}

/// Pixel rectangle on the source image, as edges (`right`/`bottom` are coordinates, not
/// insets).
struct ReedenRect: Decodable {
    var left: Double?
    var top: Double?
    var right: Double?
    var bottom: Double?
}

struct ReedenSplashMeta: Decodable {
    var assetType: String?
    var enabled: Bool?
}

/// `reader_schema/<id>/schema.json`: the reading page's colours, background and layout.
struct ReedenReaderSchema: Decodable {
    var name: String?
    var backgroundColor: String?
    var textColor: String?
    var primaryColor: String?
    var backgroundImageUrl: String?
    var backgroundImageOpacity: Double?
    var backgroundImageFit: String?
    var backgroundImageBlur: Double?
    /// A JSON *string*. Each level nests the previous colour schemas, each with its own
    /// `layoutConfig` string — stale history. Only this outermost level is current.
    var layoutConfig: String?
    var boundHighlightRules: [ReedenBoundHighlightRule]?
    var boundTitleStyle: ReedenTitleStyle?
    var themeMode: String?
}

/// The outermost `layoutConfig`. Lengths are Flutter logical pixels (Reeden is a Flutter
/// app); see `ReedenThemeImporter.layoutConfig` for how they are carried over.
struct ReedenLayoutConfig: Decodable {
    var fontSize: Double?
    var lineSpacing: Double?
    var paragraphSpacing: Double?
    var letterSpacing: Double?
    var paragraphIndent: String?
    var contentAlign: String?
    var titleAlign: String?
    var titleFontSizeDiff: Double?
    var txtTitleFontSizeDiff: Double?
    var titleBoldEnabled: Bool?
    var titleMarginTop: Double?
    var titlePaddingBottom: Double?
    var fontBold: Double?
    var textFontWeight: Double?
    var paddingLeft: Double?
    var paddingRight: Double?
    var fontFamily: String?
    var titleFontFamily: String?
    var turnPageType: String?
    var writingMode: String?
    var pageFrameStyle: String?
}

struct ReedenBoundHighlightRule: Decodable {
    var id: String?
    var rule: ReedenHighlightRule?
}

struct ReedenHighlightRule: Decodable {
    var name: String?
    var keyword: String?
    var isRegex: Bool?
    var isMultiline: Bool?
    var target: String?
    var titleOnly: Bool?
    var enabled: Bool?
    var styleMode: String?
    var styleCssText: String?
    var backgroundImageData: String?
    /// The folder the rule sits in on Reeden's 高亮 page; a standalone pack's name.
    var groupName: String?
}

struct ReedenTitleStyle: Decodable {
    var id: String?
    var name: String?
    var layout: String?
    var containerCss: String?
    var numberCss: String?
    var titleCss: String?
}

enum ReedenValue {
    /// Reeden writes `#AARRGGBB` (Flutter's `Color.value`) and, in places, plain
    /// `#RRGGBB`. Returns the RGB part and the alpha as `0...1`.
    ///
    /// Not `QiThemeValue.hex`: QiReader's 8-digit values are `RRGGBBAA`, the other way
    /// round, so reusing it would read Reeden's alpha byte as red.
    static func color(_ string: String?) -> (rgb: UInt32, alpha: Double)? {
        guard var text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard let value = UInt32(text, radix: 16) else { return nil }
        switch text.count {
        case 6:
            return (value & 0xFFFFFF, 1)
        case 8:
            return (value & 0xFFFFFF, Double(value >> 24) / 255)
        default:
            return nil
        }
    }

    static func rgb(_ string: String?) -> UInt32? {
        color(string)?.rgb
    }
}
