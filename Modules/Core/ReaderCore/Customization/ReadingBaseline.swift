import Foundation
import YueduCoreTextTypography

/// 排版基準: the typesetting a kind of book starts from — what a setting left on 自動 wears.
///
/// Not a style the reader picks: it follows the book. Chinese, English, Japanese and
/// Korean prose differ in indent, line height and paragraph spacing, so one set of
/// numbers cannot be right for all of them (Technotes/ReadingStyles-2026-10-07-design.md §5).
enum ReadingBaseline: String, Codable, CaseIterable, Sendable {
    case chinese
    case english
    case japaneseHorizontal
    case japaneseVertical
    case korean

    var titleKey: String {
        switch self {
        case .chinese: return "ReadingBaseline.Chinese"
        case .english: return "ReadingBaseline.English"
        case .japaneseHorizontal: return "ReadingBaseline.JapaneseHorizontal"
        case .japaneseVertical: return "ReadingBaseline.JapaneseVertical"
        case .korean: return "ReadingBaseline.Korean"
        }
    }

    /// The rows a baseline speaks for, and so the rows that can be left on 自動.
    static let items: Set<ReadingSettingsScopeItem> = [
        .font, .fontSize, .bold, .lineSpacing, .letterSpacing, .paragraphSpacing,
        .firstLineIndent, .textAlignment, .pageMargins,
    ]

    /// Every row in `items`, filled in.
    ///
    /// The font is the default one in every baseline: a named face would take an EPUB's
    /// embedded fonts away from every book of a fresh install. A reading style names faces;
    /// a baseline does not.
    ///
    /// `.chinese` is the reader's defaults from before baselines existed, so a Chinese
    /// book on 自動 is set exactly as every book was.
    var values: AppearanceThemeReadingSettings {
        var reading = AppearanceThemeReadingSettings()
        reading.fontPostScript = ""
        reading.isBold = false
        reading.letterSpacing = 0
        reading.textAlignment = ReaderBodyTextAlignment.justified.rawValue
        switch self {
        case .chinese:
            reading.fontSize = 18
            reading.lineHeightMultiple = 1.65
            reading.paragraphSpacingMultiplier = 0.8
            reading.firstLineIndent = 2
            reading.setMargins(horizontal: 24, vertical: 16)
        case .english:
            // Latin lines carry their own leading in ascenders and descenders, and a
            // paragraph is told apart by its gap, not by an indent.
            reading.fontSize = 18
            reading.lineHeightMultiple = 1.45
            reading.paragraphSpacingMultiplier = 0.7
            reading.firstLineIndent = 0
            reading.setMargins(horizontal: 28, vertical: 16)
        case .japaneseHorizontal:
            // jlreq: line gap between half and a full character; paragraphs are told
            // apart by a one-character indent, with no gap between them.
            reading.fontSize = 17
            reading.lineHeightMultiple = 1.75
            reading.paragraphSpacingMultiplier = 0.3
            reading.firstLineIndent = 1
            reading.setMargins(horizontal: 24, vertical: 16)
        case .japaneseVertical:
            reading.fontSize = 17
            reading.lineHeightMultiple = 1.75
            reading.paragraphSpacingMultiplier = 0.3
            reading.firstLineIndent = 1
            reading.setMargins(horizontal: 24, vertical: 24)
        case .korean:
            // klreq's body example is 160%; Hangul prose indents one character.
            reading.fontSize = 17
            reading.lineHeightMultiple = 1.7
            reading.paragraphSpacingMultiplier = 0.6
            reading.firstLineIndent = 1
            reading.setMargins(horizontal: 24, vertical: 16)
        }
        return reading
    }

    /// This kind of book read the other way: 直排 and 橫排 Japanese have a baseline each,
    /// every other kind has one.
    func oriented(vertical: Bool) -> ReadingBaseline {
        switch self {
        case .japaneseHorizontal, .japaneseVertical: return vertical ? .japaneseVertical : .japaneseHorizontal
        case .chinese, .english, .korean: return self
        }
    }

    /// The baseline the interface language implies, for when no book is open.
    static var interfaceDefault: ReadingBaseline {
        baseline(for: CJKTypographyStyleResolver.interfaceStyle,
                 isWestern: Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true,
                 isVertical: false)
    }

    static func baseline(for style: CJKTypographyStyle, isWestern: Bool, isVertical: Bool) -> ReadingBaseline {
        if isWestern { return .english }
        switch style {
        case .japanese: return isVertical ? .japaneseVertical : .japaneseHorizontal
        case .korean: return .korean
        default: return .chinese
        }
    }

    /// The baseline of a book, from text that shows its language: its title and chapter
    /// titles, which the reader has before it lays anything out.
    ///
    /// Shares `CJKTypographyStyle.detect` with the punctuation and font decisions, so a
    /// book is never Japanese for one and Chinese for the other when its text can tell.
    /// `decided` is what the book's own chapters already settled this session and wins;
    /// text that shows no script falls to the interface language.
    static func resolve(
        sample: String,
        decided: CJKTypographyStyle?,
        isVertical: Bool
    ) -> ReadingBaseline {
        if let decided {
            return baseline(for: decided, isWestern: false, isVertical: isVertical)
        }
        if let detected = CJKTypographyStyle.detect(in: sample) {
            return baseline(for: detected, isWestern: false, isVertical: isVertical)
        }
        if isWestern(sample) { return .english }
        return baseline(for: CJKTypographyStyleResolver.interfaceStyle,
                        isWestern: Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true,
                        isVertical: isVertical)
    }

    /// Latin letters and no Han, kana or Hangul to speak of.
    static func isWestern(_ sample: String) -> Bool {
        var latin = 0
        var cjk = 0
        for scalar in sample.unicodeScalars.prefix(CJKTypographyStyle.sampleLength) {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF: cjk += 1
            default: break
            }
        }
        return latin >= 5 && latin > cjk * 4
    }
}

extension AppearanceThemeReadingSettings {
    mutating func setMargins(horizontal: Double, vertical: Double) {
        pageMarginH = horizontal
        pageMarginV = vertical
        pageMarginTop = vertical
        pageMarginBottom = vertical
    }

    /// 自動 per row, merged row by row: `other`'s rows replace this value's, the rest stay.
    func mergedAutomaticItems(with other: [String: Bool]?) -> [String: Bool]? {
        guard let other else { return automaticItems }
        return (automaticItems ?? [:]).merging(other) { _, new in new }
    }

    /// A row that carries values and says nothing about 自動 is the values': a theme
    /// pack, a `.qitheme`, a backup or a sync record written before 自動 existed means
    /// "wear these", and must win over a shared setup that leaves the row on 自動.
    func withImpliedExplicitRows() -> Self {
        var result = self
        var flags = automaticItems ?? [:]
        var withoutFlags = self
        withoutFlags.automaticItems = nil
        for item in withoutFlags.items where ReadingBaseline.items.contains(item) {
            if flags[item.rawValue] == nil { flags[item.rawValue] = false }
        }
        result.automaticItems = flags.isEmpty ? nil : flags
        return result
    }

    /// The rows left on 自動.
    var automaticRows: Set<ReadingSettingsScopeItem> {
        Set((automaticItems ?? [:]).compactMap { $1 ? ReadingSettingsScopeItem(rawValue: $0) : nil })
    }
}
