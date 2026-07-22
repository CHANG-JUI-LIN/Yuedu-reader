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
}
