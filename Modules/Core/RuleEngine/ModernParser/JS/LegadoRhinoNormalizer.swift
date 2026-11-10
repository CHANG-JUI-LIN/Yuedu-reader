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

    /// The function a direct `eval`'s argument passes through (below): JSCoreEngine's
    /// `__yueduRhinoSource`, or `__yueduRuleEval` for a rule script, whose eval'd code also
    /// shares its names with `Function` code (`LegadoRuleScope`).
    static let evalWrappers: Set<String> = ["__yueduRhinoSource", "__yueduRuleEval"]

    static func normalize(_ source: String, evalWrapper: String = "__yueduRhinoSource") -> LegadoNormalizedSource {
        let (tokens, formatCharacters) = lex(source)
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

        // Rhino has no temporal dead zone: `let key = java.encodeURI(key)` reads the `key` the
        // rule was given, and `let z = typeof z` is "undefined" (Rhino 1.8.1, Legado's scopes).
        // JavaScriptCore throws a ReferenceError at both. A `let` whose initializer reads its
        // own name, at the top level of a script or a function body, becomes `var`, which reads
        // the outer binding (a rule's injected global) or undefined, as Rhino does. A `let` in a
        // nested block is left alone: `var` would leave the block. 爱巴士 (YCK1330) searches
        // with `let key = java.encodeURI(key)`.
        let functionBraces = functionBodyBraces(in: tokens)
        var braceStack: [Bool] = []
        for index in tokens.indices {
            let text = tokens[index].text
            if text == "{" { braceStack.append(functionBraces.contains(index)); continue }
            if text == "}" { _ = braceStack.popLast(); continue }
            guard text == "let", braceStack.last ?? true,
                  index == 0 || tokens[index - 1].text != "." else { continue }
            if letReadsItsOwnName(at: index, in: tokens, source: source) {
                pending.append(PendingEdit(range: tokens[index].range, replacement: "var"))
            }
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

        // Rhino hands source JS a Java String from every `java.*` call, so sources count
        // one with Java's `length()`; a JavaScriptCore string has only the `length` number.
        // Route a no-argument `.length()` call through `__yueduJavaLength` (JSCoreEngine),
        // which also still calls a `length()` method that an object really has.
        for index in tokens.indices where tokens[index].text == "length" {
            guard index > 0, tokens[index - 1].text == ".",
                  // `x..length()` is an E4X descendant, rewritten whole below.
                  !(index > 1 && tokens[index - 2].text == "." && adjacent(tokens[index - 2], tokens[index - 1])),
                  tokens.indices.contains(index + 2),
                  tokens[index + 1].text == "(", tokens[index + 2].text == ")" else { continue }
            pending.append(PendingEdit(range: tokens[index].range, replacement: "__yueduJavaLength"))
        }

        // Rhino parses E4X: Legado's `VERSION_ES6` context has `FEATURE_E4X`, so `x..name` (a
        // descendant query) compiles, and only throws once it runs — Legado has no XML runtime,
        // so it always throws. JavaScriptCore rejects the whole script instead: 哔哩哔哩
        // (YCK1331) writes `return data..item_null.text` in one `switch` case of its jsLib, and
        // every function in that jsLib was missing. `x..name` becomes
        // `x[__yueduE4XDescendants("name")]` (JSCoreEngine), a member that throws when read
        // or assigned. `1..toString()` is the number `1.` and a member; `...` is a spread.
        for index in tokens.indices where tokens[index].text == "." {
            guard tokens.indices.contains(index + 2),
                  tokens[index + 1].text == ".", adjacent(tokens[index], tokens[index + 1]),
                  !(index > 0 && tokens[index - 1].text == "." && adjacent(tokens[index - 1], tokens[index])),
                  !(tokens[index + 2].text == "." && adjacent(tokens[index + 1], tokens[index + 2])),
                  !isIntegerLiteralClaimingDot(before: index, in: tokens),
                  let nameEnd = e4xNameEnd(after: index + 1, in: tokens) else { continue }
            let name = tokens[(index + 2)...nameEnd].map(\.text).joined()
            let start = tokens[index].range.location
            pending.append(PendingEdit(
                range: NSRange(location: start, length: NSMaxRange(tokens[nameEnd].range) - start),
                replacement: "[__yueduE4XDescendants(\"\(name)\")]"
            ))
        }

        // `eval`'d source is Rhino source too: 小小阅读 keeps its decoder in
        // `bookSourceComment` and runs `eval(String(source.bookSourceComment))`. Pass a direct
        // eval's argument through `__yueduRhinoSource` (JSCoreEngine), which applies these
        // rules to a string. The callee stays `eval`, so it is still a direct eval that sees
        // the caller's scope. A method or function named `eval` is left alone. The lexer
        // emits no token for a string literal, so `eval('…')` is told from `eval()` by the
        // source text between the parentheses.
        for index in tokens.indices where tokens[index].text == "eval" {
            guard index == 0 || (tokens[index - 1].text != "." && tokens[index - 1].text != "function"),
                  tokens.indices.contains(index + 2), tokens[index + 1].text == "(",
                  !evalWrappers.contains(tokens[index + 2].text),
                  let close = matching(open: "(", close: ")", at: index + 1, in: tokens),
                  !(tokens.indices.contains(close + 1) && tokens[close + 1].text == "{") else { continue }
            let argumentStart = NSMaxRange(tokens[index + 1].range)
            let argument = (source as NSString).substring(with: NSRange(
                location: argumentStart,
                length: tokens[close].range.location - argumentStart
            ))
            guard !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            pending.append(PendingEdit(
                range: NSRange(location: argumentStart, length: 0),
                replacement: evalWrapper + "("
            ))
            pending.append(PendingEdit(range: NSRange(location: tokens[close].range.location, length: 0), replacement: ")"))
        }

        // Rhino's `TokenStream.getChar` drops every Unicode format character (category Cf,
        // above ASCII, the BOM aside) it reads outside a string or template literal — in code
        // and in a regex literal alike — so the parser never sees one; JavaScriptCore rejects
        // it as an invalid character. 移动阅读 (YCK1330) runs `source.getSource\u{200B}()` in
        // its search, book-URL and chapter-URL scripts: under Legado that is `getSource()`.
        // A token rewritten above already writes its text without them (`le\u{200B}t` → `var`),
        // so a format character inside a replaced token is not deleted a second time.
        let replacedRanges = pending.map(\.range).filter { $0.length > 0 }
        pending += formatCharacters.filter { character in
            !replacedRanges.contains { NSLocationInRange(character.location, $0) }
        }.map { PendingEdit(range: $0, replacement: "") }

        // Coalesce duplicate edits (a parameter named result matches two contracts).
        // At one offset an insertion goes first: it lands before the original text there, and
        // a deletion or replacement applied first would shift it (`eval(\u{200B}x)` would put
        // `__yueduRhinoSource(` in front of the `(`).
        var seen = Set<String>()
        pending = pending.filter {
            seen.insert("\($0.range.location):\($0.range.length):\($0.replacement)").inserted
        }.sorted { lhs, rhs in
            lhs.range.location == rhs.range.location
                ? lhs.range.length < rhs.range.length
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

    /// The `{` tokens that open a function body: after `=>`, or after a parameter list that
    /// follows `function`, a function's name, or a method's name. A `{` after `if (…)`,
    /// `for (…)`, `while (…)`, `switch (…)`, `catch (…)` or `with (…)` opens a block.
    private static func functionBodyBraces(in tokens: [Token]) -> Set<Int> {
        var opens: [Int] = []
        var openFor: [Int: Int] = [:]
        for index in tokens.indices {
            if tokens[index].text == "(" { opens.append(index) }
            if tokens[index].text == ")", let open = opens.popLast() { openFor[index] = open }
        }
        let blockHeads: Set<String> = ["if", "for", "while", "switch", "catch", "with"]
        var braces = Set<Int>()
        for index in tokens.indices where tokens[index].text == "{" && index > 0 {
            let previous = tokens[index - 1].text
            if previous == "=>" { braces.insert(index); continue }
            guard previous == ")", let open = openFor[index - 1], open > 0 else { continue }
            let head = tokens[open - 1].text
            if head == "function" || (isIdentifier(head) && !blockHeads.contains(head)) {
                braces.insert(index)
            }
        }
        return braces
    }

    /// Whether the `let` at `index` declares a name its own initializer reads: an identifier
    /// token of that name that is not a member (`.key`) or an object key (`{ key: … }`).
    /// Each declarator's initializer ends at a `,` or `;` outside brackets, at a bracket that
    /// closes past it, or at a line break automatic semicolon insertion would end it at.
    private static func letReadsItsOwnName(at index: Int, in tokens: [Token], source: String) -> Bool {
        let statementKeywords: Set<String> = [
            "let", "var", "const", "if", "for", "while", "do", "return", "function", "switch",
            "try", "throw", "break", "continue", "class"
        ]
        let text = source as NSString
        func lineBreak(between lhs: Token, _ rhs: Token) -> Bool {
            let start = NSMaxRange(lhs.range)
            guard rhs.range.location > start else { return false }
            let gap = text.substring(with: NSRange(location: start, length: rhs.range.location - start))
            return gap.contains("\n") || gap.contains("\r")
        }
        func endsOperand(_ token: String) -> Bool {
            isIdentifier(token) || token == ")" || token == "]" || token == "}"
                || token.unicodeScalars.first.map { CharacterSet.decimalDigits.contains($0) } == true
        }
        var cursor = index + 1
        while tokens.indices.contains(cursor + 1), isIdentifier(tokens[cursor].text) {
            let name = tokens[cursor].text
            guard tokens[cursor + 1].text == "=",
                  !(tokens.indices.contains(cursor + 2) && tokens[cursor + 2].text == "=") else { return false }
            var depth = 0
            var position = cursor + 2
            var readsName = false
            while position < tokens.count {
                let token = tokens[position].text
                if depth == 0, token == "," || token == ";" { break }
                if depth == 0, position > cursor + 2,
                   lineBreak(between: tokens[position - 1], tokens[position]),
                   statementKeywords.contains(token)
                    || (endsOperand(tokens[position - 1].text) && isIdentifier(token)) {
                    return readsName
                }
                if token == "(" || token == "[" || token == "{" { depth += 1 }
                if token == ")" || token == "]" || token == "}" {
                    depth -= 1
                    if depth < 0 { return readsName }
                }
                if token == name,
                   tokens[position - 1].text != ".",
                   !(tokens.indices.contains(position + 1) && tokens[position + 1].text == ":"
                     && ["{", ","].contains(tokens[position - 1].text)) {
                    readsName = true
                }
                position += 1
            }
            if readsName { return true }
            guard position < tokens.count, tokens[position].text == "," else { return false }
            cursor = position + 1
        }
        return false
    }

    private static func adjacent(_ lhs: Token, _ rhs: Token) -> Bool {
        NSMaxRange(lhs.range) == rhs.range.location
    }

    /// `1..x`: Rhino's number scanner takes the first dot as the decimal point of `1.`, so the
    /// second is an ordinary member access. A number that already has its point (`1.5`, `.5`),
    /// an exponent or a radix prefix leaves both dots to the descendant operator.
    private static func isIntegerLiteralClaimingDot(before dot: Int, in tokens: [Token]) -> Bool {
        guard dot > 0, adjacent(tokens[dot - 1], tokens[dot]),
              tokens[dot - 1].text.utf16.allSatisfy({ (48...57).contains($0) }) else { return false }
        let hasPoint = dot > 1 && tokens[dot - 2].text == "." && adjacent(tokens[dot - 2], tokens[dot - 1])
        return !hasPoint
    }

    /// The last token of an E4X descendant's name after the second dot: an identifier, `*`, or
    /// an attribute (`@name`, `@*`). A namespace-qualified or bracketed name is not rewritten.
    private static func e4xNameEnd(after secondDot: Int, in tokens: [Token]) -> Int? {
        let first = secondDot + 1
        guard tokens.indices.contains(first) else { return nil }
        func isName(_ token: Token) -> Bool { token.text == "*" || isIdentifier(token.text) }
        let end: Int
        if tokens[first].text == "@" {
            guard tokens.indices.contains(first + 1), isName(tokens[first + 1]),
                  adjacent(tokens[first], tokens[first + 1]) else { return nil }
            end = first + 1
        } else {
            guard isName(tokens[first]) else { return nil }
            end = first
        }
        // `ns::name`; a lone `:` after the name is a ternary's or a `case`'s.
        if tokens.indices.contains(end + 2), tokens[end + 1].text == ":", tokens[end + 2].text == ":",
           adjacent(tokens[end + 1], tokens[end + 2]) {
            return nil
        }
        return end
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_$")).contains(first) else { return false }
        return text.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0)
        }
    }

    /// Rhino's `TokenStream.isJSFormatChar`: above ASCII and in Unicode category Cf. The BOM is
    /// Cf too, but `getChar` hands it on as whitespace, as JavaScriptCore reads it. Checked per
    /// UTF-16 unit, so a format character outside the BMP (U+E0001 and the like) is not caught.
    private static func isRhinoFormatCharacter(_ value: unichar) -> Bool {
        guard value > 127, value != 0xFEFF, let scalar = UnicodeScalar(value) else { return false }
        return scalar.properties.generalCategory == .format
    }

    /// The code's tokens, and the format characters (`isRhinoFormatCharacter`) Rhino would drop:
    /// those in code and in regex literals, none in a string or template literal or a comment.
    /// A token's text leaves its format characters out, so `eval\u{200B}` still reads `eval`.
    private static func lex(_ source: String) -> (tokens: [Token], formatCharacters: [NSRange]) {
        let text = source as NSString
        let length = text.length
        var tokens: [Token] = []
        var formatCharacters: [NSRange] = []
        var i = 0
        var canStartRegex = true

        func unit(_ offset: Int) -> unichar { text.character(at: offset) }
        func noteFormatCharacter(at offset: Int) {
            if isRhinoFormatCharacter(unit(offset)) {
                formatCharacters.append(NSRange(location: offset, length: 1))
            }
        }
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
            var value = text.substring(with: NSRange(location: start, length: end - start))
            if value.utf16.contains(where: isRhinoFormatCharacter) {
                value = String(String.UnicodeScalarView(value.unicodeScalars.filter {
                    !($0.value <= 0xFFFF && isRhinoFormatCharacter(unichar($0.value)))
                }))
            }
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
            if isRhinoFormatCharacter(c) { noteFormatCharacter(at: i); i += 1; continue }
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
                    if unit(i) == 47 && !inClass { i += 1; while i < length && isWord(unit(i)) { noteFormatCharacter(at: i); i += 1 }; break }
                    noteFormatCharacter(at: i)
                    i += 1
                }
                canStartRegex = false
                continue
            }
            if isWord(c) {
                let start = i; i += 1
                while i < length && isWord(unit(i)) { noteFormatCharacter(at: i); i += 1 }
                append(start, i); continue
            }
            let start = i
            if c == 61 && n == 62 { i += 2 } else { i += 1 }
            append(start, i)
        }
        return (tokens, formatCharacters)
    }
}
