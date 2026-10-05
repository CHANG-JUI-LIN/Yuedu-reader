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
    }

    private(set) var counts: [Kind: Int] = [:]

    mutating func record(_ kind: Kind, count: Int = 1) {
        counts[kind, default: 0] += count
    }

    subscript(kind: Kind) -> Int {
        counts[kind, default: 0]
    }

    var isEmpty: Bool { counts.isEmpty }
}
