import CoreGraphics
import Foundation
import UIKit

// MARK: - Weight

/// Font weight for the in-content chapter title. Maps to a `UIFont.Weight`.
/// Kept as a small closed set (not a raw float) so the picker and presets stay
/// legible; the renderer synthesises the weight for fonts without a native face.
enum ChapterTitleWeight: String, Codable, CaseIterable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold

    var uiFontWeight: UIFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// Localization key for the picker label.
    var localizedNameKey: String {
        switch self {
        case .light: return "字重・細體"
        case .regular: return "字重・常規"
        case .medium: return "字重・中黑"
        case .semibold: return "字重・半粗"
        case .bold: return "字重・粗體"
        }
    }
}

// MARK: - Alignment

/// Horizontal alignment for the chapter title. Named left/center/right rather
/// than leading/trailing on purpose: this only drives horizontal (LTR) layout.
/// Vertical-CJK titles keep their existing centred behaviour and never read this.
enum ChapterTitleAlignment: String, Codable, CaseIterable, Sendable {
    case left
    case center
    case right

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    var systemImageName: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var localizedNameKey: String {
        switch self {
        case .left: return "對齊・靠左"
        case .center: return "對齊・置中"
        case .right: return "對齊・靠右"
        }
    }
}

// MARK: - Style

/// A complete description of how the in-content chapter title is typeset.
///
/// Modelled as one value type (rather than a handful of loose `GlobalSettings`
/// fields) so that presets, "my presets", and file import/export are all just
/// storage of this struct. Only the paged/scroll TXT and online builders honour
/// the full set; the EPUB `<h1>` path (`NodeAttributedStringRenderer`) reads
/// only `visible`/`size`/`bottomSpacing`, matching its previous behaviour.
struct ChapterTitleStyle: Codable, Equatable, Sendable {
    /// "顯示標題": whether the in-content title is drawn at all.
    var visible: Bool
    /// Absolute point size of the chapter *name* (the larger, lower line).
    var size: CGFloat
    /// Space above the title block, in points.
    var topSpacing: CGFloat
    /// Space between the title block and the body ("與正文間距"), in points.
    var bottomSpacing: CGFloat
    var weight: ChapterTitleWeight
    var alignment: ChapterTitleAlignment
    /// When true, both segments use the reader's selected body font and the
    /// per-segment PostScript overrides below are ignored.
    var followsBodyFont: Bool
    /// When true and a "第X章"-style prefix is detected, the title is drawn as
    /// two lines (small number line + large name line).
    var splitEnabled: Bool
    /// Size of the chapter *number* line relative to `size` (e.g. 0.55).
    var numberRelativeSize: CGFloat
    /// PostScript name for the number line; `nil` follows the reader font.
    var numberFontPostScript: String?
    /// PostScript name for the name line; `nil` follows the reader font.
    var nameFontPostScript: String?
    /// Advanced CSS: when on, the title is rendered from the HTML/CSS template
    /// below via the shared HTML engine (borders, dividers, diamond frames, …)
    /// instead of the plain two-line CoreText layout.
    var advancedCSSEnabled: Bool
    /// HTML/CSS template for light appearance. Placeholders: `{number}` `{name}`.
    var lightTemplate: String
    /// HTML/CSS template for dark appearance.
    var darkTemplate: String

    static let sizeRange: ClosedRange<CGFloat> = 14...40
    static let topSpacingRange: ClosedRange<CGFloat> = 0...100
    static let bottomSpacingRange: ClosedRange<CGFloat> = 0...100
    static let numberRelativeSizeRange: ClosedRange<CGFloat> = 0.3...1.0

    /// Neutral starting templates (light/dark) — identical to the 簡約置中
    /// built-in, used when advanced CSS is switched on before a preset is chosen.
    static let defaultLightTemplate = "<div style=\"text-align:center\"><div style=\"font-size:0.55em;letter-spacing:2px;color:#8A8A8E\">{number}</div><div style=\"font-size:1em;font-weight:700;color:#1C1C1E;margin-top:0.2em\">{name}</div></div>"
    static let defaultDarkTemplate = "<div style=\"text-align:center\"><div style=\"font-size:0.55em;letter-spacing:2px;color:#8E8E93\">{number}</div><div style=\"font-size:1em;font-weight:700;color:#F2F2F7;margin-top:0.2em\">{name}</div></div>"

    /// Official default. `visible/size/topSpacing/bottomSpacing` match the
    /// legacy loose-field defaults so migration is a no-op for those; the new
    /// fields default to the centred, split, reader-font look the picture shows.
    static let `default` = ChapterTitleStyle(
        visible: true,
        size: 28,
        topSpacing: 10,
        bottomSpacing: 20,
        weight: .bold,
        alignment: .center,
        followsBodyFont: true,
        // Off by default: an untouched install renders the title exactly as
        // before (single line). Two-line split is opt-in on the settings page.
        splitEnabled: false,
        numberRelativeSize: 0.55,
        numberFontPostScript: nil,
        nameFontPostScript: nil,
        advancedCSSEnabled: false,
        lightTemplate: ChapterTitleStyle.defaultLightTemplate,
        darkTemplate: ChapterTitleStyle.defaultDarkTemplate
    )

    /// Clamp every numeric field into its valid range. Applied on decode and on
    /// preset/import apply so a malformed file can't poison layout.
    func sanitized() -> ChapterTitleStyle {
        var copy = self
        copy.size = ChapterTitleStyle.clamp(size, to: ChapterTitleStyle.sizeRange, fallback: 28)
        copy.topSpacing = ChapterTitleStyle.clamp(topSpacing, to: ChapterTitleStyle.topSpacingRange, fallback: 10)
        copy.bottomSpacing = ChapterTitleStyle.clamp(bottomSpacing, to: ChapterTitleStyle.bottomSpacingRange, fallback: 20)
        copy.numberRelativeSize = ChapterTitleStyle.clamp(
            numberRelativeSize,
            to: ChapterTitleStyle.numberRelativeSizeRange,
            fallback: 0.55
        )
        return copy
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Effective PostScript name for a segment, honouring the follow-body toggle.
    /// `nil` means "use the reader's selected font (or system font)".
    func numberFontName() -> String? { followsBodyFont ? nil : numberFontPostScript }
    func nameFontName() -> String? { followsBodyFont ? nil : nameFontPostScript }
}

extension ChapterTitleStyle {
    /// Backwards-compatible constructor from the legacy loose GlobalSettings
    /// fields. Used once during migration when no `chapterTitleStyle` JSON exists.
    /// Carries over the four legacy values; every new field (weight, alignment,
    /// split, fonts) takes its `default`. Note: because `default.splitEnabled`
    /// is true, existing TXT/online titles with a "第X章" prefix begin rendering
    /// as two lines after this migration — an intended visual upgrade.
    init(legacyVisible: Bool, legacySize: CGFloat, legacyTopSpacing: CGFloat, legacyBottomSpacing: CGFloat) {
        self = ChapterTitleStyle.default
        self.visible = legacyVisible
        self.size = legacySize
        self.topSpacing = legacyTopSpacing
        self.bottomSpacing = legacyBottomSpacing
    }
}

// MARK: - Splitter

/// Splits a raw chapter title into an optional number segment ("第一章") and a
/// name segment ("初入江湖") using a built-in rule — deliberately *not* a
/// user-editable regex (the editable-regex UI is a later milestone).
///
/// Guards the real cases seen in TXT / web-novel tables of contents:
/// "第1章 xxx" / "第一章：xxx" / "第十回 xxx". Titles with no such prefix
/// ("序"、"楔子"、"番外"、"後記") or a bare prefix with no name ("第一章") fall
/// back to a single line — so no spurious empty second line appears.
/// Delete/replace this when the editable-regex feature lands.
enum ChapterTitleSplitter {
    // 第 + (CJK/Arabic numerals) + chapter unit. Anchored at start.
    private static let prefixRegex = try! NSRegularExpression(
        pattern: "^第[0-9０-９〇零一二三四五六七八九十百千兩两廿卅]+[章節节回卷話话集部篇折]",
        options: []
    )

    private static let leadingSeparators = CharacterSet(charactersIn: " \u{3000}:：.。、·．-—－_|｜　~～")
        .union(.whitespacesAndNewlines)

    static func split(_ rawTitle: String) -> (number: String?, name: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (nil, rawTitle) }

        let full = title as NSString
        guard let match = prefixRegex.firstMatch(
            in: title,
            options: [.anchored],
            range: NSRange(location: 0, length: full.length)
        ) else {
            return (nil, title)
        }

        let number = full.substring(with: match.range)
        var rest = full.substring(from: match.range.length)
        while let first = rest.unicodeScalars.first, leadingSeparators.contains(first) {
            rest.removeFirst()
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bare "第一章" with no name → keep it as one line.
        guard !rest.isEmpty else { return (nil, title) }
        return (number, rest)
    }
}

// MARK: - Preset

/// A named chapter-title style. Both the built-in presets (defined in code) and
/// the user's "my presets" (persisted JSON) share this shape, so the picker and
/// import/export treat them uniformly.
struct ChapterTitleStylePreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// For built-ins this is a localization key; for user presets it's the raw
    /// user-entered name.
    var name: String
    var style: ChapterTitleStyle
    /// Built-ins are code-defined and not deletable; user presets are.
    var isBuiltin: Bool

    init(id: String = UUID().uuidString, name: String, style: ChapterTitleStyle, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.style = style
        self.isBuiltin = isBuiltin
    }
}

extension ChapterTitleStylePreset {
    /// Built-in presets. All six are HTML/CSS-template styles (advanced CSS on),
    /// shown in the picker only while 高級 CSS 樣式 is enabled. Each carries a
    /// light and a dark template; every CSS property used here (per-side border,
    /// padding, margin, letter-spacing, font-weight) is verified supported by
    /// the shared IR engine. Ornament rows use ◆/◇/─ literal characters because
    /// the engine has no pseudo-elements.
    static let builtins: [ChapterTitleStylePreset] = [
        cssPreset(
            id: "builtin.css.centered",
            name: "預設・簡約置中",
            size: 28, top: 16, bottom: 24,
            light: ChapterTitleStyle.defaultLightTemplate,
            dark: ChapterTitleStyle.defaultDarkTemplate
        ),
        cssPreset(
            id: "builtin.css.ink",
            name: "預設・水墨留白",
            size: 30, top: 28, bottom: 36,
            light: "<div style=\"text-align:center\"><div style=\"font-size:0.5em;letter-spacing:6px;color:#9A9AA0\">{number}</div><div style=\"font-size:1em;font-weight:300;letter-spacing:8px;color:#2C2C2E;margin-top:0.55em\">{name}</div><div style=\"font-size:0.35em;color:#C9C9CE;margin-top:0.7em\">────</div></div>",
            dark: "<div style=\"text-align:center\"><div style=\"font-size:0.5em;letter-spacing:6px;color:#7C7C82\">{number}</div><div style=\"font-size:1em;font-weight:300;letter-spacing:8px;color:#E5E5EA;margin-top:0.55em\">{name}</div><div style=\"font-size:0.35em;color:#48484A;margin-top:0.7em\">────</div></div>"
        ),
        cssPreset(
            id: "builtin.css.quote",
            name: "預設・豎線引用",
            size: 26, top: 16, bottom: 24,
            light: "<div style=\"text-align:left;border-left:3px solid #C7C7CC;padding-left:14px\"><div style=\"font-size:0.55em;letter-spacing:4px;color:#8A8A8E\">{number}</div><div style=\"font-size:1em;font-weight:600;color:#1C1C1E;margin-top:0.25em\">{name}</div></div>",
            dark: "<div style=\"text-align:left;border-left:3px solid #48484A;padding-left:14px\"><div style=\"font-size:0.55em;letter-spacing:4px;color:#8E8E93\">{number}</div><div style=\"font-size:1em;font-weight:600;color:#F2F2F7;margin-top:0.25em\">{name}</div></div>"
        ),
        cssPreset(
            id: "builtin.css.divider",
            name: "預設・上下分隔",
            size: 26, top: 20, bottom: 28,
            light: "<div style=\"text-align:center;border-top:1px solid #D1D1D6;border-bottom:1px solid #D1D1D6;padding-top:0.6em;padding-bottom:0.6em\"><div style=\"font-size:0.55em;letter-spacing:3px;color:#8A8A8E\">{number}</div><div style=\"font-size:1em;font-weight:700;color:#1C1C1E;margin-top:0.2em\">{name}</div></div>",
            dark: "<div style=\"text-align:center;border-top:1px solid #3A3A3C;border-bottom:1px solid #3A3A3C;padding-top:0.6em;padding-bottom:0.6em\"><div style=\"font-size:0.55em;letter-spacing:3px;color:#8E8E93\">{number}</div><div style=\"font-size:1em;font-weight:700;color:#F2F2F7;margin-top:0.2em\">{name}</div></div>"
        ),
        cssPreset(
            id: "builtin.css.right",
            name: "預設・右對齊",
            size: 28, top: 16, bottom: 24,
            light: "<div style=\"text-align:right\"><div style=\"font-size:1em;font-weight:700;color:#1C1C1E\">{name}</div><div style=\"font-size:0.55em;letter-spacing:3px;color:#8A8A8E;margin-top:0.35em\">{number}</div></div>",
            dark: "<div style=\"text-align:right\"><div style=\"font-size:1em;font-weight:700;color:#F2F2F7\">{name}</div><div style=\"font-size:0.55em;letter-spacing:3px;color:#8E8E93;margin-top:0.35em\">{number}</div></div>"
        ),
        cssPreset(
            id: "builtin.css.diamond",
            name: "預設・菱形裝飾",
            size: 27, top: 24, bottom: 32,
            light: "<div style=\"text-align:center\"><div style=\"font-size:0.45em;letter-spacing:2px;color:#B4B4BA\">── ◆ ──</div><div style=\"font-size:0.55em;letter-spacing:3px;color:#8A8A8E;margin-top:0.6em\">{number}</div><div style=\"font-size:1em;font-weight:600;color:#1C1C1E;margin-top:0.25em\">{name}</div><div style=\"font-size:0.45em;letter-spacing:2px;color:#B4B4BA;margin-top:0.6em\">── ◇ ──</div></div>",
            dark: "<div style=\"text-align:center\"><div style=\"font-size:0.45em;letter-spacing:2px;color:#5A5A5E\">── ◆ ──</div><div style=\"font-size:0.55em;letter-spacing:3px;color:#8E8E93;margin-top:0.6em\">{number}</div><div style=\"font-size:1em;font-weight:600;color:#F2F2F7;margin-top:0.25em\">{name}</div><div style=\"font-size:0.45em;letter-spacing:2px;color:#5A5A5E;margin-top:0.6em\">── ◇ ──</div></div>"
        ),
    ]

    private static func cssPreset(
        id: String,
        name: String,
        size: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        light: String,
        dark: String
    ) -> ChapterTitleStylePreset {
        var style = ChapterTitleStyle.default
        style.size = size
        style.topSpacing = top
        style.bottomSpacing = bottom
        style.advancedCSSEnabled = true
        style.lightTemplate = light
        style.darkTemplate = dark
        return ChapterTitleStylePreset(id: id, name: name, style: style, isBuiltin: true)
    }
}
