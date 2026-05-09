import Foundation

/// Port of Legado's RuleAnalyzer.kt — a rule string tokenizer/parser.
/// Splits rule strings by operators (`||`, `&&`, `%%`) while correctly handling
/// nested brackets, quoted strings, escape characters, and code blocks.
final class RuleAnalyzer {

    private static let ESC: Character = "\\"

    private let queue: [Character]
    private var pos: Int = 0
    private var start: Int = 0
    private var startX: Int = 0
    private var rule: [String] = []
    private var step: Int = 0

    /// Current operator type after splitRule ("||", "&&", "%%", or "")
    var elementsType: String = ""

    /// Balance-checking mode selected at init (code blocks vs rule expressions)
    private let isCode: Bool

    init(data: String, code: Bool = false) {
        self.queue = Array(data)
        self.isCode = code
    }

    /// Dispatches to the correct balanced-bracket checker based on init-time mode.
    private func chompBalanced(_ open: Character, _ close: Character) -> Bool {
        isCode ? chompCodeBalanced(open, close) : chompRuleBalanced(open, close)
    }

    // MARK: - Public API

    /// Trim leading '@' and whitespace (ASCII < '!')
    func trim() {
        guard pos < queue.count else { return }
        guard queue[pos] == "@" || queue[pos] < "!" else { return }
        pos += 1
        while pos < queue.count && (queue[pos] == "@" || queue[pos] < "!") {
            pos += 1
        }
        start = pos
        startX = pos
    }

    /// Reset position to 0 for reuse
    func reSetPos() {
        pos = 0
        startX = 0
    }

    /// Split rule string by operators, handling nested brackets.
    /// Accepts one or more operator strings (e.g. "||", "&&", "%%").
    func splitRule(_ split: String...) -> [String] {
        let operators = split.filter { !$0.isEmpty }
        guard !operators.isEmpty else {
            elementsType = ""
            pos = queue.count
            return [substringFrom(startX)]
        }

        var parts: [String] = []
        var partStart = startX
        var index = startX
        var squareDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var chosenOperator: String?

        while index < queue.count {
            let character = queue[index]

            if escaped {
                escaped = false
                index += 1
                continue
            }

            if character == Self.ESC, isCode || (!inSingleQuote && !inDoubleQuote) {
                escaped = true
                index += 1
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                index += 1
                continue
            }
            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                index += 1
                continue
            }

            if !inSingleQuote && !inDoubleQuote {
                switch character {
                case "[":
                    squareDepth += 1
                    index += 1
                    continue
                case "]":
                    squareDepth = max(0, squareDepth - 1)
                    index += 1
                    continue
                case "(":
                    parenDepth += 1
                    index += 1
                    continue
                case ")":
                    parenDepth = max(0, parenDepth - 1)
                    index += 1
                    continue
                case "{":
                    if isCode { braceDepth += 1 }
                    index += 1
                    continue
                case "}":
                    if isCode { braceDepth = max(0, braceDepth - 1) }
                    index += 1
                    continue
                default:
                    break
                }

                if squareDepth == 0, parenDepth == 0, braceDepth == 0 {
                    let activeOperators = chosenOperator.map { [$0] } ?? operators
                    if let matched = activeOperators.first(where: { matchesOperator($0, at: index) }) {
                        chosenOperator = matched
                        parts.append(substring(partStart, index))
                        index += matched.count
                        partStart = index
                        continue
                    }
                }
            }

            index += 1
        }

        elementsType = chosenOperator ?? ""
        pos = queue.count
        guard chosenOperator != nil else {
            return [substringFrom(startX)]
        }
        parts.append(substringFrom(partStart))
        return parts
    }

    /// Replace inner rules using brace-balanced extraction.
    /// - Parameters:
    ///   - inner: start marker (e.g. "{$." or "{{")
    ///   - startStep: chars not part of rule at start of match
    ///   - endStep: chars not part of rule at end of match
    ///   - fr: resolver function
    func innerRule(inner: String, startStep: Int = 1, endStep: Int = 1,
                   fr: (String) -> String?) -> String {
        var result = ""

        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced("{", "}") {
                if let frv = fr(substring(posPre + startStep, pos - endStep)), !frv.isEmpty {
                    result += substring(startX, posPre) + frv
                    startX = pos
                    continue
                }
            }
            pos += inner.count
        }

        if startX == 0 { return "" }
        result += substringFrom(startX)
        return result
    }

    /// Replace inner rules with explicit start/end delimiters.
    func innerRule(startStr: String, endStr: String, fr: (String) -> String?) -> String {
        var result = ""

        while consumeTo(startStr) {
            pos += startStr.count
            let posPre = pos
            if consumeTo(endStr) {
                let frv = fr(substring(posPre, pos)) ?? ""
                result += substring(startX, posPre - startStr.count) + frv
                pos += endStr.count
                startX = pos
            }
        }

        if startX == 0 { return String(queue) }
        result += substringFrom(startX)
        return result
    }

    // MARK: - Scanning Primitives

    /// Find next occurrence of `seq` from current position.
    /// Sets `start = pos` before searching.
    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        let seqChars = Array(seq)
        guard !seqChars.isEmpty else { return false }
        let maxStart = queue.count - seqChars.count
        guard maxStart >= pos else { return false }

        for i in pos...maxStart {
            var match = true
            for j in 0..<seqChars.count {
                if queue[i + j] != seqChars[j] { match = false; break }
            }
            if match {
                pos = i
                return true
            }
        }
        return false
    }

    /// Find nearest occurrence of any seq. Sets `step` to matched seq length.
    private func consumeToAny(_ seqs: [String]) -> Bool {
        var p = pos
        while p < queue.count {
            for s in seqs {
                let sChars = Array(s)
                guard p + sChars.count <= queue.count else { continue }
                var match = true
                for j in 0..<sChars.count {
                    if queue[p + j] != sChars[j] { match = false; break }
                }
                if match {
                    step = sChars.count
                    pos = p
                    return true
                }
            }
            p += 1
        }
        return false
    }

    private func matchesOperator(_ op: String, at index: Int) -> Bool {
        let opChars = Array(op)
        guard index + opChars.count <= queue.count else { return false }
        for offset in opChars.indices where queue[index + offset] != opChars[offset] {
            return false
        }
        return true
    }

    /// Find position of any char from current position. Returns -1 if not found.
    private func findToAny(_ chars: Character...) -> Int {
        var p = pos
        while p < queue.count {
            for c in chars where queue[p] == c {
                return p
            }
            p += 1
        }
        return -1
    }

    // MARK: - Balance Checkers

    /// For JSON/JS code: `\` always escapes next char; tracks `[]` nesting
    /// separately from the open/close pair.
    private func chompCodeBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            guard p < queue.count else { break }
            let c = queue[p]; p += 1

            if c != Self.ESC {
                if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
                else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }

                if inSingleQuote || inDoubleQuote { continue }

                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else {
                p += 1 // skip escaped char
            }
        } while depth > 0 || otherDepth > 0

        guard depth <= 0 && otherDepth <= 0 else { return false }
        pos = p
        return true
    }

    /// For CSS/XPath rules: `\` only escapes outside quotes.
    private func chompRuleBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            guard p < queue.count else { break }
            let c = queue[p]; p += 1

            if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
            else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }

            if inSingleQuote || inDoubleQuote { continue }

            if c == Self.ESC {
                p += 1 // escape only outside quotes
                continue
            }

            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        } while depth > 0

        guard depth <= 0 else { return false }
        pos = p
        return true
    }

    // MARK: - splitRule Implementation (two-phase, matching Legado's tailrec)

    /// Phase 1: Multiple possible operators — find the first one, then resolve brackets.
    private func splitRulePhase1(_ split: [String]) -> [String] {
        rule = []

        // Single operator shortcut
        if split.count == 1 {
            elementsType = split[0]
            if !consumeTo(elementsType) {
                rule.append(substringFrom(startX))
                return rule
            }
            step = elementsType.count
            return splitRulePhase2()
        }

        // Multiple operators: find first match
        if !consumeToAny(split) {
            rule.append(substringFrom(startX))
            return rule
        }

        let end = pos
        pos = start

        while true {
            let st = findToAny("[", "(")

            if st == -1 {
                // No brackets — simple split
                rule = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step

                while consumeTo(elementsType) {
                    rule.append(substring(start, pos))
                    pos += step
                }
                rule.append(substringFrom(pos))
                return rule
            }

            if st > end {
                // Bracket is after operator — split up to bracket, then may recurse
                rule = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step

                while consumeTo(elementsType) && pos < st {
                    rule.append(substring(start, pos))
                    pos += step
                }

                if pos > st {
                    startX = start
                    return splitRulePhase2()
                } else {
                    rule.append(substringFrom(pos))
                    return rule
                }
            }

            // Bracket is before operator — skip the balanced group
            pos = st
            let close: Character = queue[pos] == "[" ? "]" : ")"
            guard chompBalanced(queue[pos], close) else { break }
            guard end > pos else { break }
        }

        start = pos
        return splitRulePhase1(split) // tailrec → loop via recursion
    }

    /// Phase 2: Operator already identified (`elementsType` set), fast split.
    private func splitRulePhase2() -> [String] {
        let end = pos
        pos = start

        while true {
            let st = findToAny("[", "(")

            if st == -1 {
                rule.append(substring(startX, end))
                pos = end + step

                while consumeTo(elementsType) {
                    rule.append(substring(start, pos))
                    pos += step
                }
                rule.append(substringFrom(pos))
                return rule
            }

            if st > end {
                rule.append(substring(startX, end))
                pos = end + step

                while consumeTo(elementsType) && pos < st {
                    rule.append(substring(start, pos))
                    pos += step
                }

                if pos > st {
                    startX = start
                    return splitRulePhase2()
                } else {
                    rule.append(substringFrom(pos))
                    return rule
                }
            }

            pos = st
            let close: Character = queue[pos] == "[" ? "]" : ")"
            guard chompBalanced(queue[pos], close) else { break }
            guard end > pos else { break }
        }

        start = pos
        if !consumeTo(elementsType) {
            rule.append(substringFrom(startX))
            return rule
        }
        return splitRulePhase2() // tailrec
    }

    // MARK: - Substring Helpers

    private func substring(_ from: Int, _ to: Int) -> String {
        guard from >= 0 && to <= queue.count && from <= to else { return "" }
        return String(queue[from..<to])
    }

    private func substringFrom(_ from: Int) -> String {
        guard from >= 0 && from <= queue.count else { return "" }
        if from == queue.count { return "" }
        return String(queue[from...])
    }
}
