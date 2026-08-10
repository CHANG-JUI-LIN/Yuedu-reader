import Foundation

struct LegadoSourceLocation: Equatable {
    let utf16Offset: Int
    let line: Int
    let column: Int
}

struct LegadoSourceEdit: Equatable {
    let original: LegadoSourceLocation
    let normalized: LegadoSourceLocation
    let originalText: String
    let replacementText: String
}

struct LegadoNormalizedSource: Equatable {
    let source: String
    let edits: [LegadoSourceEdit]
}

/// Normalizes the small set of verified Rhino/JavaScriptCore syntax differences.
/// The lexer intentionally emits tokens only for executable code, so source text in
/// comments and literals can never be rewritten by a compatibility rule.
enum LegadoRhinoNormalizer {
    private struct Token {
        let text: String
        let range: NSRange
    }

    private struct PendingEdit {
        let range: NSRange
        let replacement: String
    }

    static func normalize(_ source: String) -> LegadoNormalizedSource {
        let tokens = lex(source)
        var pending: [PendingEdit] = []

        // Rhino treats a `result` lexical declaration like the mutable rule global.
        for index in tokens.indices where tokens[index].text == "let" || tokens[index].text == "const" {
            guard tokens.indices.contains(index + 1), tokens[index + 1].text == "result" else { continue }
            pending.append(PendingEdit(range: tokens[index].range, replacement: "var"))
        }

        // A parameter redeclared in a function's top-level body is accepted by Rhino
        // but is an early SyntaxError in JavaScriptCore. Rewrite only the declaration
        // keyword; nested functions and nested blocks retain native lexical semantics.
        var index = 0
        while index < tokens.count {
            guard tokens[index].text == "function",
                  let openParams = nextToken("(", after: index, in: tokens),
                  let closeParams = matching(open: "(", close: ")", at: openParams, in: tokens),
                  let openBody = nextToken("{", after: closeParams, in: tokens),
                  let closeBody = matching(open: "{", close: "}", at: openBody, in: tokens) else {
                index += 1
                continue
            }
            let parameters = Set(tokens[(openParams + 1)..<closeParams].compactMap { token in
                isIdentifier(token.text) ? token.text : nil
            })
            var braceDepth = 0
            var cursor = openBody + 1
            while cursor < closeBody {
                let token = tokens[cursor]
                if token.text == "{" { braceDepth += 1 }
                if token.text == "}" { braceDepth = max(0, braceDepth - 1) }
                if braceDepth == 0,
                   (token.text == "let" || token.text == "const"),
                   tokens.indices.contains(cursor + 1),
                   parameters.contains(tokens[cursor + 1].text) {
                    pending.append(PendingEdit(range: token.range, replacement: "var"))
                }
                cursor += 1
            }
            // Keep walking through the body so a nested function is normalized
            // against its own parameter list as an independent scope.
            index += 1
        }

        // JavaScriptCore requires parentheses around a destructured sole arrow
        // parameter. Match tokens instead of source text so literals are untouched.
        for open in tokens.indices where tokens[open].text == "[" {
            guard open > 0,
                  tokens[open - 1].text == "(" || tokens[open - 1].text == ",",
                  let close = matching(open: "[", close: "]", at: open, in: tokens),
                  tokens.indices.contains(close + 1), tokens[close + 1].text == "=>",
                  !tokens[(open + 1)..<close].contains(where: { $0.text == "[" || $0.text == "]" }) else { continue }
            pending.append(PendingEdit(range: NSRange(location: tokens[open].range.location, length: 0), replacement: "("))
            pending.append(PendingEdit(range: NSRange(location: NSMaxRange(tokens[close].range), length: 0), replacement: ")"))
        }

        // Coalesce duplicate edits (a parameter named result matches two contracts).
        var seen = Set<String>()
        pending = pending.filter {
            seen.insert("\($0.range.location):\($0.range.length):\($0.replacement)").inserted
        }.sorted { lhs, rhs in
            lhs.range.location == rhs.range.location
                ? lhs.range.length > rhs.range.length
                : lhs.range.location < rhs.range.location
        }

        let originalNSString = source as NSString
        let mutable = NSMutableString(string: source)
        var delta = 0
        var edits: [LegadoSourceEdit] = []
        for edit in pending {
            let normalizedOffset = edit.range.location + delta
            let originalText = originalNSString.substring(with: edit.range)
            edits.append(LegadoSourceEdit(
                original: location(in: source, utf16Offset: edit.range.location),
                normalized: location(in: mutable as String, utf16Offset: normalizedOffset),
                originalText: originalText,
                replacementText: edit.replacement
            ))
            let adjusted = NSRange(location: normalizedOffset, length: edit.range.length)
            mutable.replaceCharacters(in: adjusted, with: edit.replacement)
            delta += (edit.replacement as NSString).length - edit.range.length
        }
        return LegadoNormalizedSource(source: mutable as String, edits: edits)
    }

    private static func location(in source: String, utf16Offset: Int) -> LegadoSourceLocation {
        let prefix = (source as NSString).substring(to: min(utf16Offset, (source as NSString).length))
        let lines = prefix.components(separatedBy: "\n")
        return LegadoSourceLocation(
            utf16Offset: utf16Offset,
            line: lines.count,
            column: ((lines.last as NSString?)?.length ?? 0) + 1
        )
    }

    private static func nextToken(_ text: String, after index: Int, in tokens: [Token]) -> Int? {
        guard index + 1 < tokens.count else { return nil }
        return ((index + 1)..<tokens.count).first { tokens[$0].text == text }
    }

    private static func matching(open: String, close: String, at index: Int, in tokens: [Token]) -> Int? {
        var depth = 0
        for cursor in index..<tokens.count {
            if tokens[cursor].text == open { depth += 1 }
            if tokens[cursor].text == close {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_$")).contains(first) else { return false }
        return text.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0)
        }
    }

    private static func lex(_ source: String) -> [Token] {
        let text = source as NSString
        let length = text.length
        var tokens: [Token] = []
        var i = 0
        var canStartRegex = true

        func unit(_ offset: Int) -> unichar { text.character(at: offset) }
        func isWord(_ value: unichar) -> Bool {
            value == 36 || value == 95 || (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || value > 127
        }
        func isWhitespaceOrNewline(_ value: unichar) -> Bool {
            guard let scalar = UnicodeScalar(value) else {
                // NSString exposes UTF-16 code units. A non-BMP character arrives
                // here as two surrogate units, neither of which is a scalar alone.
                return false
            }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        func append(_ start: Int, _ end: Int) {
            let value = text.substring(with: NSRange(location: start, length: end - start))
            tokens.append(Token(text: value, range: NSRange(location: start, length: end - start)))
            canStartRegex = ["(", "[", "{", ",", ";", ":", "=", "=>", "return", "case"].contains(value)
        }
        func skipQuoted(_ quote: unichar) {
            i += 1
            while i < length {
                if unit(i) == 92 { i = min(length, i + 2); continue }
                if unit(i) == quote { i += 1; return }
                i += 1
            }
        }

        while i < length {
            let c = unit(i)
            let n = i + 1 < length ? unit(i + 1) : 0
            if isWhitespaceOrNewline(c) { i += 1; continue }
            if c == 47 && n == 47 {
                i += 2; while i < length && unit(i) != 10 && unit(i) != 13 { i += 1 }; continue
            }
            if c == 47 && n == 42 {
                i += 2; while i + 1 < length && !(unit(i) == 42 && unit(i + 1) == 47) { i += 1 }; i = min(length, i + 2); continue
            }
            if c == 39 || c == 34 || c == 96 { skipQuoted(c); canStartRegex = false; continue }
            if c == 47 && canStartRegex {
                i += 1
                var inClass = false
                while i < length {
                    if unit(i) == 92 { i = min(length, i + 2); continue }
                    if unit(i) == 91 { inClass = true }
                    if unit(i) == 93 { inClass = false }
                    if unit(i) == 47 && !inClass { i += 1; while i < length && isWord(unit(i)) { i += 1 }; break }
                    i += 1
                }
                canStartRegex = false
                continue
            }
            if isWord(c) {
                let start = i; i += 1; while i < length && isWord(unit(i)) { i += 1 }; append(start, i); continue
            }
            let start = i
            if c == 61 && n == 62 { i += 2 } else { i += 1 }
            append(start, i)
        }
        return tokens
    }
}
