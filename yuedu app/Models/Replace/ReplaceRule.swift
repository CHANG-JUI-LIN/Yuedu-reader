import Foundation

/// A user-configurable global replace rule.
/// Rules are applied to chapter content after the book-source's own
/// `##` replacement rules, providing a user-level ad-filter / content-cleaner.
struct ReplaceRule: Identifiable, Codable {
    var id: String = UUID().uuidString

    /// Display name shown in the list.
    var name: String

    /// Regex or literal pattern to match.
    var pattern: String

    /// Replacement string.  Use `$1`, `$2` etc. for capture-group references.
    var replacement: String = ""

    /// Whether `pattern` is treated as a regular expression.
    var isRegex: Bool = true

    /// Whether this rule is active.
    var enabled: Bool = true

    /// Scope: `"global"` applies to every book; a book-source URL restricts to that source only.
    var scope: String = "global"

    /// Priority ordering — lower number runs first.
    var sortOrder: Int = 0
}
