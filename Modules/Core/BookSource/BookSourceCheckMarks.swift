import Foundation

/// What one finished 書源驗證 writes onto its source, as Legado's `CheckSourceService` does:
/// the groups naming what failed (搜索失效, 发现正文失效, 校验超时, …) and a `// Error:` line at
/// the top of the comment. Every check first removes the invalid groups and the error line an
/// earlier check left (`removeInvalidGroups`, `removeErrorComment`), so a source that passes
/// now loses them.
///
/// The group names are Legado's own strings, not localized: they are source data, a source
/// exported to Legado carries them, and Legado's next check removes them by those names.
struct BookSourceCheckMarks: Equatable, Sendable {
    /// Groups this check found the source earns, in the order Legado adds them.
    var addGroups: [String] = []
    /// Tags this check clears because the rule they name is there now (搜索链接规则为空,
    /// 发现规则为空). Invalid groups are cleared whatever this holds.
    var removeGroups: [String] = []
    /// The `// Error:` reason for a failed source; nil for one that passed.
    var errorReason: String?
    /// Legado's `CheckSource.wSourceComment`: whether the comment is touched at all.
    var writesComment = true

    enum Group {
        static let searchURLEmpty = "搜索链接规则为空"
        static let exploreRuleEmpty = "发现规则为空"
        static let searchFailed = "搜索失效"
        static let discoveryFailed = "发现失效"
        static let timeout = "校验超时"
        static let jsError = "js失效"
        static let siteError = "网站失效"
        static let domainUnreachable = "域名失效"

        static func tocFailed(_ track: ValidationTrack) -> String { "\(track.legadoPrefix)目录失效" }
        static func contentFailed(_ track: ValidationTrack) -> String { "\(track.legadoPrefix)正文失效" }
    }

    /// Legado's `AppPattern.splitGroupRegex`.
    static let groupSeparators = CharacterSet(charactersIn: ",;，；")
    static let errorCommentPrefix = "// Error: "

    /// Legado's `BookSource.getInvalidGroupNames`: groups holding 失效, and 校验超时.
    static func isInvalidGroup(_ group: String) -> Bool {
        group.contains("失效") || group == Group.timeout
    }

    static func groups(in field: String) -> [String] {
        field.components(separatedBy: groupSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The two tracks of Legado's check: a search result's `checkBook`, and a discovery result's.
enum ValidationTrack: Hashable, Sendable {
    case search, discovery

    var legadoPrefix: String {
        switch self {
        case .search: return "搜索"
        case .discovery: return "发现"
        }
    }
}

extension BookSource {
    /// Applies a check's marks the way Legado's `addGroup` / `removeGroup` / `addErrorComment`
    /// do. Two differences, both to the comment: Legado rejoins the paragraphs it keeps with a
    /// single newline, which merged a source author's paragraphs on every check, and here they
    /// keep their blank line; and a comment left as it was is not rewritten.
    /// - Returns: whether the source changed.
    @discardableResult
    mutating func applyCheckMarks(_ marks: BookSourceCheckMarks) -> Bool {
        var groups = BookSourceCheckMarks.groups(in: bookSourceGroup)
        let before = groups
        groups.removeAll { BookSourceCheckMarks.isInvalidGroup($0) || marks.removeGroups.contains($0) }
        for group in marks.addGroups where !groups.contains(group) {
            groups.append(group)
        }
        var changed = false
        if groups != before {
            bookSourceGroup = groups.joined(separator: ",")
            changed = true
        }
        guard marks.writesComment else { return changed }
        let kept = bookSourceComment.components(separatedBy: "\n\n")
            .filter { !$0.hasPrefix(BookSourceCheckMarks.errorCommentPrefix) }
            .joined(separator: "\n\n")
        var comment = kept
        if let reason = marks.errorReason {
            let line = BookSourceCheckMarks.errorCommentPrefix + reason
            comment = kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? line
                : line + "\n\n" + kept
        }
        if comment != bookSourceComment {
            bookSourceComment = comment
            changed = true
        }
        return changed
    }
}
