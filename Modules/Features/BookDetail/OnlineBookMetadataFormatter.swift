import Foundation

enum OnlineBookMetadataFormatter {
    private static let tagSeparators = CharacterSet(
        charactersIn: ",，|｜、/／;；\t\n "
    )

    private static let unitOnlyWordCounts: Set<String> = [
        "字", "字數", "字数", "萬字", "万字", "千字", "百萬字", "百万字"
    ]

    static func tags(detailKind: String?, fallbackKind: String) -> [String] {
        var seen = Set<String>()
        return [detailKind ?? "", fallbackKind]
            .flatMap { $0.components(separatedBy: tagSeparators) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tag in
                !tag.isEmpty && tag.count <= 10 && !tag.contains("作者")
                    && !tag.contains("字") && seen.insert(tag).inserted
            }
            .prefix(6)
            .map { $0 }
    }

    static func wordCount(detailValue: String?, fallbackValue: String) -> String {
        let detail = detailValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isMeaningfulWordCount(detail) {
            return detail
        }
        // A stale Legado selector followed by a suffix replacement (for example
        // `##$##字`) can return only the unit. Keep the discover/search value for
        // that exact parse-failure shape. This can be removed once the parser
        // distinguishes an empty extraction from a legitimate replacement result.
        return fallbackValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMeaningfulWordCount(_ value: String) -> Bool {
        !value.isEmpty && !unitOnlyWordCounts.contains(value)
    }

    /// The word count as a reader says it (maintainer, 2026-11-12: 「不要準確字數，我要用萬」): the
    /// source's count, in whatever unit it came, in the app language's own large unit with at
    /// most one decimal — 「373.6萬字」. A text that names no count is shown as it is while it is
    /// short enough to be one (「連載中」 is not, but costs nothing); a long one is dropped.
    static func roundedWordCount(_ raw: String, locale: Locale) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let count = characterCount(in: text) else { return text.count <= 12 ? text : nil }
        return String(format: localized("約 %@ 字"), compactCount(count, locale: locale))
    }

    /// 「373.6萬」, 「1.2億」, 「8000」: the language's compact notation, one decimal at most.
    static func compactCount(_ count: Double, locale: Locale) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    /// The count a source's text names, in characters: the number before 字, times its unit
    /// (億, 萬, 千); or the whole text when it is a number alone. Not any number in it: a source
    /// can put a date beside the count.
    static func characterCount(in text: String) -> Double? {
        let counted = text.firstMatch(of: /([0-9][0-9,]*(?:\.[0-9]+)?)\s*([億亿萬万千kKwW])?\s*字/)
            ?? text.wholeMatch(of: /([0-9][0-9,]*(?:\.[0-9]+)?)\s*([億亿萬万千kKwW])?/)
        guard let counted, let number = Double(counted.1.replacingOccurrences(of: ",", with: "")), number > 0 else {
            return nil
        }
        let scale: Double = switch counted.2.map(String.init) {
        case "億", "亿": 100_000_000
        case "萬", "万", "w", "W": 10_000
        case "千", "k", "K": 1_000
        default: 1
        }
        return number * scale
    }
}
