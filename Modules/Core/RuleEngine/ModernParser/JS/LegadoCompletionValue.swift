import Foundation

/// Rhino's script completion value on JavaScriptCore.
///
/// A rule script answers with its completion value — the value of the last statement that
/// produced one. Legado runs scripts on Rhino, which keeps ES5's rule: a statement that
/// produces nothing (an `if` whose test is false, a loop that never runs, an empty `switch`)
/// leaves the earlier value in place. JavaScriptCore follows ES2015, where those statements
/// complete with `undefined` and replace it: `'a'; if (false) {}` is `a` on Rhino and
/// `undefined` here. 美女图站's content script ends with one `if` per site; the iqupu branch
/// builds the images and the `xgmn02` test after it is false, so Legado shows the images and
/// JavaScriptCore answered nothing.
///
/// `functionBody` rewrites each expression statement at script level (not inside a function)
/// to record its value, `__yueduCompletion = (expression);`, and ends the body by returning
/// it, which is ES5's completion value. A `finally` block's value is not recorded, as in ES5,
/// where a `finally` that completes normally leaves the `try` block's value.
///
/// Every rule script is rewritten: it runs as the body of a function, in a scope of its own
/// (`LegadoRuleScope`), and a function body has no completion value of its own to keep.
enum LegadoCompletionValue {
    static let variable = "__yueduCompletion"

    /// The script as a function body that answers with its completion value, or nil when
    /// the reader cannot follow it (a construct it does not know, brackets that do not
    /// balance).
    static func functionBody(_ source: String) -> String? {
        let units = Array(source.utf16)
        guard let parser = read(units) else { return nil }
        var output: [UInt16] = []
        output.reserveCapacity(units.count + parser.expressions.count * 32 + 64)
        output.append(contentsOf: "let \(variable); ".utf16)
        var cursor = 0
        for (range, endsWithSemicolon) in zip(parser.expressions, parser.endsWithSemicolon) {
            output.append(contentsOf: units[cursor..<range.lowerBound])
            output.append(contentsOf: "\(variable) = (".utf16)
            output.append(contentsOf: units[range])
            // The statement's own `;` stays: a second one would be an empty statement, and
            // `if (a) b; else c` would lose its `else`.
            output.append(contentsOf: (endsWithSemicolon ? ")" : ");").utf16)
            cursor = range.upperBound
        }
        output.append(contentsOf: units[cursor...])
        output.append(contentsOf: "\nreturn \(variable);".utf16)
        return String(utf16CodeUnits: output, count: output.count)
    }

    /// The script's tokens, or nil when it does not lex (an unterminated literal or comment).
    static func tokens(_ source: String) -> [Token]? {
        var lexer = Lexer(Array(source.utf16))
        return lexer.tokens()
    }

    /// The UTF-16 ranges of the script-level expression statements `functionBody` records, for
    /// checking the reader against Rhino's own parse. Nil when the reader cannot follow it.
    static func expressionStatementRanges(_ source: String) -> [Range<Int>]? {
        read(Array(source.utf16))?.expressions
    }

    private static func read(_ units: [UInt16]) -> StatementReader? {
        var lexer = Lexer(units)
        guard let tokens = lexer.tokens() else { return nil }
        var reader = StatementReader(tokens: tokens)
        return reader.readScript() ? reader : nil
    }

    // MARK: - Tokens

    enum Kind { case name, number, string, template, regex, punct }

    struct Token {
        let kind: Kind
        let text: String
        let start: Int
        let end: Int
        let newlineBefore: Bool
    }

    // MARK: - Lexer

    /// ECMAScript tokens, literals included: strings, templates (with their `${…}` read
    /// through), regular expressions (told from division by the token before them) and
    /// numbers. Comments and white space only mark whether a line ended before a token.
    fileprivate struct Lexer {
        let units: [UInt16]
        var index = 0

        init(_ units: [UInt16]) { self.units = units }

        mutating func tokens() -> [Token]? {
            var out: [Token] = []
            guard lex(into: &out, untilTemplateBrace: false) else { return nil }
            return out
        }

        private func unit(_ i: Int) -> UInt16 { i < units.count ? units[i] : 0 }

        private static func isLineTerminator(_ u: UInt16) -> Bool {
            u == 10 || u == 13 || u == 0x2028 || u == 0x2029
        }

        private static func isSpace(_ u: UInt16) -> Bool {
            u == 9 || u == 11 || u == 12 || u == 32 || u == 0xA0 || u == 0xFEFF || u == 0x1680
                || (0x2000...0x200A).contains(u) || u == 0x202F || u == 0x205F || u == 0x3000
                || u == 0x200B || u == 0x200C || u == 0x200D
        }

        private static func isIdentifierStart(_ u: UInt16) -> Bool {
            u == 36 || u == 95 || u == 92 || (65...90).contains(u) || (97...122).contains(u)
                || (u > 127 && !isSpace(u) && !isLineTerminator(u))
        }

        private static func isIdentifierPart(_ u: UInt16) -> Bool {
            isIdentifierStart(u) || (48...57).contains(u)
        }

        private static let punctuators: [String] = [
            ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
            "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=",
            "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>",
        ].sorted { $0.count > $1.count }
        private static let punctuatorUnits: [[UInt16]] = punctuators.map { Array($0.utf16) }

        /// Keywords after which a `/` starts a regular expression.
        private static let regexKeywords: Set<String> = [
            "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
            "case", "do", "else", "yield", "await",
        ]

        private static func regexAllowed(after previous: Token?) -> Bool {
            guard let previous else { return true }
            switch previous.kind {
            case .number, .string, .template, .regex: return false
            case .name: return regexKeywords.contains(previous.text)
            case .punct: return ![")", "]", "++", "--"].contains(previous.text)
            }
        }

        /// Lexes into `out`. Inside a template's `${…}`, stops after the `}` that closes it.
        private mutating func lex(into out: inout [Token], untilTemplateBrace: Bool) -> Bool {
            var newline = false
            var braceDepth = 0
            while index < units.count {
                let c = units[index]
                if Self.isLineTerminator(c) { newline = true; index += 1; continue }
                if Self.isSpace(c) { index += 1; continue }
                if c == 47, unit(index + 1) == 47 {
                    while index < units.count, !Self.isLineTerminator(units[index]) { index += 1 }
                    continue
                }
                if c == 47, unit(index + 1) == 42 {
                    index += 2
                    while index < units.count, !(units[index] == 42 && unit(index + 1) == 47) {
                        if Self.isLineTerminator(units[index]) { newline = true }
                        index += 1
                    }
                    guard index < units.count else { return false }
                    index += 2
                    continue
                }
                let start = index
                var kind: Kind
                if c == 39 || c == 34 {
                    guard skipString(quote: c) else { return false }
                    kind = .string
                } else if c == 96 {
                    guard skipTemplate() else { return false }
                    kind = .template
                } else if c == 47, Self.regexAllowed(after: out.last) {
                    guard skipRegex() else { return false }
                    kind = .regex
                } else if (48...57).contains(c) || (c == 46 && (48...57).contains(unit(index + 1))) {
                    skipNumber()
                    kind = .number
                } else if Self.isIdentifierStart(c) {
                    index += 1
                    while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
                    kind = .name
                } else {
                    if untilTemplateBrace {
                        if c == 123 { braceDepth += 1 }
                        if c == 125 {
                            if braceDepth == 0 { index += 1; return true }
                            braceDepth -= 1
                        }
                    }
                    let length = punctuatorLength(at: index)
                    index += length
                    kind = .punct
                }
                let text = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                out.append(Token(kind: kind, text: text, start: start, end: index, newlineBefore: newline))
                newline = false
            }
            return !untilTemplateBrace
        }

        private func punctuatorLength(at i: Int) -> Int {
            for candidate in Self.punctuatorUnits where i + candidate.count <= units.count {
                if Array(units[i..<(i + candidate.count)]) == candidate {
                    // `?.5` is a conditional followed by a number, not optional chaining.
                    if candidate == Array("?.".utf16), (48...57).contains(unit(i + 2)) { continue }
                    return candidate.count
                }
            }
            return 1
        }

        private mutating func skipString(quote: UInt16) -> Bool {
            index += 1
            while index < units.count {
                let u = units[index]
                if u == 92 {
                    // A line continuation over CRLF is three units.
                    index += unit(index + 1) == 13 && unit(index + 2) == 10 ? 3 : 2
                    continue
                }
                if u == quote { index += 1; return true }
                if u == 10 || u == 13 { return false }
                index += 1
            }
            return false
        }

        private mutating func skipTemplate() -> Bool {
            index += 1
            while index < units.count {
                let u = units[index]
                if u == 92 { index += 2; continue }
                if u == 96 { index += 1; return true }
                if u == 36, unit(index + 1) == 123 {
                    index += 2
                    var inner: [Token] = []
                    guard lex(into: &inner, untilTemplateBrace: true) else { return false }
                    continue
                }
                index += 1
            }
            return false
        }

        private mutating func skipRegex() -> Bool {
            index += 1
            var inClass = false
            while index < units.count {
                let u = units[index]
                if Self.isLineTerminator(u) { return false }
                if u == 92 { index += 2; continue }
                if u == 91 { inClass = true } else if u == 93 { inClass = false } else if u == 47, !inClass {
                    index += 1
                    while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
                    return true
                }
                index += 1
            }
            return false
        }

        private mutating func skipNumber() {
            let first = units[index]
            if first == 48, let radix = Optional(unit(index + 1)), [120, 88, 98, 66, 111, 79].contains(radix) {
                index += 2
                while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
                return
            }
            while index < units.count, (48...57).contains(units[index]) || units[index] == 95 { index += 1 }
            if unit(index) == 46 {
                index += 1
                while index < units.count, (48...57).contains(units[index]) || units[index] == 95 { index += 1 }
            }
            if unit(index) == 101 || unit(index) == 69 {
                let sign = unit(index + 1)
                let digitAt = (sign == 43 || sign == 45) ? index + 2 : index + 1
                if (48...57).contains(unit(digitAt)) {
                    index = digitAt
                    while index < units.count, (48...57).contains(units[index]) { index += 1 }
                }
            }
            while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
        }
    }

    // MARK: - Statements

    /// Reads statements at script level — blocks, `if`, loops, `switch`, `try`, `with` and
    /// labels are entered; functions and classes are passed over whole — and records the range
    /// of each expression statement. `false` from `readScript` means "cannot follow".
    fileprivate struct StatementReader {
        let tokens: [Token]
        var position = 0
        var expressions: [Range<Int>] = []
        /// Whether each of `expressions` is followed by its statement's `;`.
        var endsWithSemicolon: [Bool] = []
        private var recording = true

        init(tokens: [Token]) { self.tokens = tokens }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }
        private func peek(_ offset: Int) -> Token? {
            position + offset < tokens.count ? tokens[position + offset] : nil
        }
        private func isPunct(_ token: Token?, _ text: String) -> Bool {
            token?.kind == .punct && token?.text == text
        }
        private func isName(_ token: Token?, _ text: String) -> Bool {
            token?.kind == .name && token?.text == text
        }

        private static let reserved: Set<String> = [
            "break", "case", "catch", "class", "const", "continue", "debugger", "default",
            "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
            "import", "in", "instanceof", "new", "return", "super", "switch", "this", "throw",
            "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "enum",
            "await", "null", "true", "false",
        ]

        mutating func readScript() -> Bool {
            while current != nil {
                guard readStatement() else { return false }
            }
            return true
        }

        private mutating func readStatement() -> Bool {
            guard let token = current else { return false }
            if token.kind == .punct {
                switch token.text {
                case "{": return readBlock()
                case ";": position += 1; return true
                case "}", ")", "]": return false
                default: return readExpressionStatement()
                }
            }
            guard token.kind == .name else { return readExpressionStatement() }
            switch token.text {
            case "var", "const":
                position += 1
                return skipExpression() && consumeSemicolon()
            case "let":
                let next = peek(1)
                if next?.kind == .name || isPunct(next, "[") || isPunct(next, "{") {
                    position += 1
                    return skipExpression() && consumeSemicolon()
                }
                return readExpressionStatement()
            case "function":
                return skipFunction()
            case "async" where isName(peek(1), "function") && peek(1)?.newlineBefore == false:
                position += 1
                return skipFunction()
            case "class":
                return skipClass()
            case "if":
                position += 1
                guard skipGroup(open: "(", close: ")"), readStatement() else { return false }
                if isName(current, "else") {
                    position += 1
                    return readStatement()
                }
                return true
            case "for":
                position += 1
                if isName(current, "await") { position += 1 }
                return skipGroup(open: "(", close: ")") && readStatement()
            case "while", "with":
                position += 1
                return skipGroup(open: "(", close: ")") && readStatement()
            case "do":
                position += 1
                guard readStatement(), isName(current, "while") else { return false }
                position += 1
                guard skipGroup(open: "(", close: ")") else { return false }
                if isPunct(current, ";") { position += 1 }
                return true
            case "switch":
                position += 1
                return skipGroup(open: "(", close: ")") && readSwitchBody()
            case "try":
                position += 1
                guard readBlock() else { return false }
                var handled = false
                if isName(current, "catch") {
                    handled = true
                    position += 1
                    if isPunct(current, "(") { guard skipGroup(open: "(", close: ")") else { return false } }
                    guard readBlock() else { return false }
                }
                if isName(current, "finally") {
                    handled = true
                    position += 1
                    // ES5: a `finally` that completes normally keeps the `try` block's value.
                    let wasRecording = recording
                    recording = false
                    defer { recording = wasRecording }
                    guard readBlock() else { return false }
                }
                return handled
            case "return", "throw":
                position += 1
                if let next = current, !next.newlineBefore, !isPunct(next, ";"), !isPunct(next, "}") {
                    guard skipExpression() else { return false }
                }
                return consumeSemicolon()
            case "break", "continue":
                position += 1
                if let next = current, next.kind == .name, !next.newlineBefore,
                   !Self.reserved.contains(next.text) {
                    position += 1
                }
                return consumeSemicolon()
            case "debugger":
                position += 1
                return consumeSemicolon()
            case "import", "export", "case", "default", "else", "catch", "finally":
                return false
            default:
                if isPunct(peek(1), ":"), !Self.reserved.contains(token.text) {
                        position += 2
                    return readStatement()
                }
                return readExpressionStatement()
            }
        }

        private mutating func readBlock() -> Bool {
            guard isPunct(current, "{") else { return false }
            position += 1
            while let token = current, !isPunct(token, "}") {
                guard readStatement() else { return false }
            }
            guard current != nil else { return false }
            position += 1
            return true
        }

        private mutating func readSwitchBody() -> Bool {
            guard isPunct(current, "{") else { return false }
            position += 1
            while let token = current, !isPunct(token, "}") {
                if isName(token, "case") {
                    position += 1
                    guard skipExpression(stopsAtColon: true), isPunct(current, ":") else { return false }
                    position += 1
                } else if isName(token, "default") {
                    position += 1
                    guard isPunct(current, ":") else { return false }
                    position += 1
                } else {
                    guard readStatement() else { return false }
                }
            }
            guard current != nil else { return false }
            position += 1
            return true
        }

        private mutating func readExpressionStatement() -> Bool {
            guard let first = current else { return false }
            let startIndex = position
            guard skipExpression(), position > startIndex else { return false }
            if recording {
                expressions.append(first.start..<tokens[position - 1].end)
                endsWithSemicolon.append(isPunct(current, ";"))
            }
            return consumeSemicolon()
        }

        private mutating func consumeSemicolon() -> Bool {
            if isPunct(current, ";") { position += 1 }
            return true
        }

        private mutating func skipFunction() -> Bool {
            guard isName(current, "function") else { return false }
            position += 1
            if isPunct(current, "*") { position += 1 }
            if current?.kind == .name { position += 1 }
            return skipGroup(open: "(", close: ")") && skipGroup(open: "{", close: "}")
        }

        private mutating func skipClass() -> Bool {
            position += 1
            while let token = current, !isPunct(token, "{") {
                if isPunct(token, "(") || isPunct(token, "[") {
                    guard skipGroup(open: token.text, close: token.text == "(" ? ")" : "]") else { return false }
                    continue
                }
                position += 1
            }
            return skipGroup(open: "{", close: "}")
        }

        /// Passes over a bracketed group, its brackets balanced.
        private mutating func skipGroup(open: String, close: String) -> Bool {
            guard isPunct(current, open) else { return false }
            var depth = 0
            while let token = current {
                if token.kind == .punct {
                    if ["(", "[", "{"].contains(token.text) { depth += 1 }
                    if [")", "]", "}"].contains(token.text) {
                        depth -= 1
                        if depth == 0 {
                            guard token.text == close else { return false }
                            position += 1
                            return true
                        }
                        if depth < 0 { return false }
                    }
                }
                position += 1
            }
            return false
        }

        /// Operators after which an expression cannot end, so a line break does not end it.
        private static let continuingNames: Set<String> = [
            "typeof", "void", "delete", "new", "in", "instanceof", "of", "await", "yield",
        ]

        /// Whether `next`, on a new line after `last`, continues the expression. When unsure
        /// it does: a wrong join is what JavaScript itself reads or a syntax error, a wrong
        /// split silently changes what the script means.
        private static func continues(_ last: Token, with next: Token) -> Bool {
            switch last.kind {
            case .punct:
                if ![")", "]", "}", "++", "--"].contains(last.text) { return true }
            case .name:
                if continuingNames.contains(last.text) { return true }
            default:
                break
            }
            switch next.kind {
            case .punct:
                return !["++", "--", "!", "~", "{", ";", "}"].contains(next.text)
            case .template:
                return true
            case .name:
                return next.text == "in" || next.text == "instanceof"
            default:
                return false
            }
        }

        /// Passes over one expression (or a declaration list): to a `;`, the bracket that
        /// closes the enclosing block, or a line break that ends the statement.
        private mutating func skipExpression(stopsAtColon: Bool = false) -> Bool {
            var depth = 0
            var conditionals = 0
            var last: Token?
            // Which open brackets are an arrow function's block body (`=> {`).
            var arrowBodies: [Bool] = []
            // The last token closed an arrow body back at this expression's own level.
            var endsArrowBody = false
            while let token = current {
                if depth == 0 {
                    if token.kind == .punct {
                        if token.text == ";" || token.text == "}" || token.text == ")" || token.text == "]" {
                            break
                        }
                        if stopsAtColon, token.text == ":" {
                            if conditionals == 0 { break }
                            conditionals -= 1
                        } else if stopsAtColon, token.text == "?" {
                            conditionals += 1
                        }
                    }
                    if token.newlineBefore, let last {
                        // An arrow function is not a member or call expression, so nothing
                        // but `,` or a conditional's `:` can follow its block body: on a new
                        // line anything else starts the next statement. 美女图站／多看's
                        // `$$=(a,b,c)=>{…}` followed by a line opening with `[[…]].map(…)`.
                        if endsArrowBody {
                            if token.text != "," && token.text != ":" { break }
                        } else if !Self.continues(last, with: token) {
                            break
                        }
                    }
                }
                endsArrowBody = false
                if token.kind == .punct {
                    if ["(", "[", "{"].contains(token.text) {
                        depth += 1
                        arrowBodies.append(token.text == "{" && last?.kind == .punct && last?.text == "=>")
                    }
                    if [")", "]", "}"].contains(token.text) {
                        depth -= 1
                        if depth < 0 { return false }
                        endsArrowBody = arrowBodies.removeLast() && depth == 0
                    }
                }
                last = token
                position += 1
            }
            return depth == 0 && last != nil
        }
    }
}
