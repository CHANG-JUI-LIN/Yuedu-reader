import Foundation

enum ReplaceSelectionDraft {
    static func makeRule(selectedText: String, scope: String) -> ReplaceRule? {
        let pattern = selectedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }

        let trimmedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReplaceRule(
            name: "",
            pattern: pattern,
            replacement: "",
            isRegex: false,
            enabled: true,
            scope: trimmedScope.isEmpty ? "global" : trimmedScope
        )
    }
}

enum ReplaceRuleScope {
    static func resolve(chapterURL: String, bookSourceURL: String) -> String {
        let source = bookSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? chapterURL : source
    }
}
