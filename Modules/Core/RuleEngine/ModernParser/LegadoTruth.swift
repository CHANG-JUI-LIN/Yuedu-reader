import Foundation

/// Legado's `String?.isTrue(nullIsTrue)` (`StringExtensions.kt`): what a rule's text means as a
/// flag. Blank or `"null"` is `nullIsTrue`; otherwise everything but `false` / `no` / `not` /
/// `0` / `0.0` (any case, surrounding whitespace ignored) is true.
///
/// A rule's flag is whatever text it reads, not a literal boolean: 过期杂志's `isVolume` is
/// `.catalog-section-title@text`, true because the heading has text (「专题」). Reading only
/// `true` / `1` / `yes` as true took every such heading for a chapter.
enum LegadoTruth {
    static func isTrue(_ value: String?, nullIsTrue: Bool = false) -> Bool {
        // Kotlin's `trim()` drops every char <= U+0020, newlines included.
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, value != "null" else {
            return nullIsTrue
        }
        return !falsy.contains(trimmed.lowercased())
    }

    private static let falsy: Set<String> = ["false", "no", "not", "0", "0.0"]
}
