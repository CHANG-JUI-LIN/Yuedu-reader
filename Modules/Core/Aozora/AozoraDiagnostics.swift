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

    /// One line for the log: each kind with its count, unknown annotations by
    /// shape with the most frequent first.
    var summary: String {
        guard !counts.isEmpty else { return "clean" }
        let names: [(Kind, String)] = [
            (.unclosedNotationBlock, "unclosedNotationBlock"), (.unresolvedGaiji, "unresolvedGaiji"),
            (.unmappedGaijiCode, "unmappedGaijiCode"), (.missingForwardReference, "missingForwardReference"),
            (.unclosedRange, "unclosedRange"), (.unopenedRangeEnd, "unopenedRangeEnd"),
        ]
        var parts = names.compactMap { kind, name in counts[kind].map { "\(name)=\($0)" } }
        let unknown = counts.compactMap { kind, count -> (shape: String, count: Int)? in
            if case .unknownAnnotation(let shape) = kind { return (shape, count) }
            return nil
        }.sorted { ($0.count, $1.shape) > ($1.count, $0.shape) }
        if !unknown.isEmpty {
            let shown = unknown.prefix(10).map { "\($0.shape)×\($0.count)" }.joined(separator: ", ")
            let more = unknown.count > 10 ? ", +\(unknown.count - 10) shapes" : ""
            parts.append("unknownAnnotation=[\(shown)\(more)]")
        }
        return parts.joined(separator: " ")
    }

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
