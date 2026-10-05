import Foundation

/// What the parser could not interpret in one document. Counted, never
/// logged per occurrence.
struct AozoraDiagnostics: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A hyphen line opened the notation block and none closed it; the
        /// rest of the file is read as body.
        case unclosedNotationBlock
        /// A gaiji with only a shape description, shown as ※（description）.
        case unresolvedGaiji
        /// A gaiji whose JIS or U+ code has no character.
        case unmappedGaijiCode
        /// An annotation the parser does not know, by `shape(of:)`.
        case unknownAnnotation(String)
        /// ［＃「X」に…］ whose X is not in the text before it.
        case missingForwardReference
        /// A range or block left open, closed at the end of its line or section.
        case unclosedRange
        /// ［＃…終わり］ with nothing open to close.
        case unopenedRangeEnd
    }

    private(set) var counts: [Kind: Int] = [:]

    mutating func record(_ kind: Kind, count: Int = 1) {
        counts[kind, default: 0] += count
    }

    subscript(kind: Kind) -> Int {
        counts[kind, default: 0]
    }

    var isEmpty: Bool { counts.isEmpty }

    /// An annotation with its quoted text and numbers abstracted, so unknown
    /// kinds group together: 「…」は分数, N行目 (the census `shape`).
    static func shape(of command: String) -> String {
        var result = ""
        var depth = 0
        var lastWasDigit = false
        for character in command {
            if character == "「" {
                if depth == 0 { result += "「…" }
                depth += 1
                lastWasDigit = false
                continue
            }
            if character == "」", depth > 0 {
                depth -= 1
                if depth == 0 { result += "」" }
                continue
            }
            guard depth == 0 else { continue }
            if character.isNumber {
                if !lastWasDigit { result += "N" }
                lastWasDigit = true
            } else {
                result.append(character)
                lastWasDigit = false
            }
        }
        return result
    }
}
