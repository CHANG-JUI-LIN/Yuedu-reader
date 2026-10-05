import Foundation

struct AozoraToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A run of characters that start no markup.
        case text
        /// ｜, which fixes where the next ruby's base text starts.
        case rubyBar
        /// 《reading》 on one line.
        case ruby
        /// ［＃command］, which may span lines.
        case annotation
        /// ※［＃description、code］.
        case gaiji
        /// 〔…〕, or 〔 to the end of its line when it is never closed: an
        /// accent decomposition such as 〔cafe'〕 or an ordinary bracket.
        case accent(closed: Bool)
        /// ／＼ (くの字点), or ／″＼ (濁点付き).
        case kunojiten(voiced: Bool)
        /// \r\n, \n or \r.
        case newline
    }

    var kind: Kind
    /// UTF-16 offsets into the tokenized text.
    var range: Range<Int>

    /// Between the delimiters: the reading of 《…》, the command of ［＃…］
    /// and ※［＃…］, the inside of 〔…〕.
    var content: Range<Int> {
        switch kind {
        case .ruby: return (range.lowerBound + 1)..<(range.upperBound - 1)
        case .annotation: return (range.lowerBound + 2)..<(range.upperBound - 1)
        case .gaiji: return (range.lowerBound + 3)..<(range.upperBound - 1)
        case .accent(let closed): return (range.lowerBound + 1)..<(range.upperBound - (closed ? 1 : 0))
        case .text, .rubyBar, .kunojiten, .newline: return range
        }
    }
}

/// Splits Aozora text into tokens whose ranges cover the input exactly once.
/// Markup that never closes stays text: an unterminated ［＃ or 《 is shown
/// as written.
enum AozoraTokenizer {
    static func tokenize(_ text: String) -> [AozoraToken] {
        let units = Array(text.utf16)
        return tokenize(units, in: 0..<units.count)
    }

    static func tokenize(_ units: [UInt16], in range: Range<Int>) -> [AozoraToken] {
        var tokens: [AozoraToken] = []
        var textStart = range.lowerBound
        var index = range.lowerBound
        let limit = range.upperBound
        while index < limit {
            guard let token = token(in: units, at: index, limit: limit) else {
                index += 1
                continue
            }
            if textStart < index {
                tokens.append(AozoraToken(kind: .text, range: textStart..<index))
            }
            tokens.append(token)
            index = token.range.upperBound
            textStart = index
        }
        if textStart < limit {
            tokens.append(AozoraToken(kind: .text, range: textStart..<limit))
        }
        return tokens
    }

    // MARK: Code units

    static let lineFeed: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let rubyBar: UInt16 = 0xFF5C        // ｜
    static let rubyOpen: UInt16 = 0x300A       // 《
    static let rubyClose: UInt16 = 0x300B      // 》
    static let bracketOpen: UInt16 = 0xFF3B    // ［
    static let bracketClose: UInt16 = 0xFF3D   // ］
    static let sharp: UInt16 = 0xFF03          // ＃
    static let gaijiMark: UInt16 = 0x203B      // ※
    static let accentOpen: UInt16 = 0x3014     // 〔
    static let accentClose: UInt16 = 0x3015    // 〕
    static let slash: UInt16 = 0xFF0F          // ／
    static let backslash: UInt16 = 0xFF3C      // ＼ (CP932 0x815F)
    static let doublePrime: UInt16 = 0x2033    // ″, aozora2html's 濁点 for くの字点
    static let voicedMark: UInt16 = 0x309B     // ゛, the same 濁点 in some files

    static func isNewline(_ unit: UInt16) -> Bool {
        unit == lineFeed || unit == carriageReturn
    }

    /// The end of the ［＃…］ starting at `start`, or nil when it never
    /// closes. Like aozora2html's TagParser, only ［＃ nests; a plain ［ is a
    /// character and the first unmatched ］ closes the annotation.
    static func annotationEnd(in units: [UInt16], from start: Int, limit: Int) -> Int? {
        var depth = 0
        var index = start
        while index < limit {
            let unit = units[index]
            if unit == bracketOpen, index + 1 < limit, units[index + 1] == sharp {
                depth += 1
                index += 2
                continue
            }
            if unit == bracketClose {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func token(in units: [UInt16], at index: Int, limit: Int) -> AozoraToken? {
        let unit = units[index]
        func next(_ offset: Int) -> UInt16? {
            index + offset < limit ? units[index + offset] : nil
        }
        switch unit {
        case lineFeed:
            return AozoraToken(kind: .newline, range: index..<(index + 1))
        case carriageReturn:
            return AozoraToken(kind: .newline, range: index..<(index + (next(1) == lineFeed ? 2 : 1)))
        case rubyBar:
            return AozoraToken(kind: .rubyBar, range: index..<(index + 1))
        case rubyOpen:
            return rubyEnd(in: units, from: index, limit: limit)
                .map { AozoraToken(kind: .ruby, range: index..<$0) }
        case bracketOpen where next(1) == sharp:
            return annotationEnd(in: units, from: index, limit: limit)
                .map { AozoraToken(kind: .annotation, range: index..<$0) }
        case gaijiMark where next(1) == bracketOpen && next(2) == sharp:
            return annotationEnd(in: units, from: index + 1, limit: limit)
                .map { AozoraToken(kind: .gaiji, range: index..<$0) }
        case accentOpen:
            return accent(in: units, from: index, limit: limit)
        case slash where next(1) == backslash:
            return AozoraToken(kind: .kunojiten(voiced: false), range: index..<(index + 2))
        case slash where (next(1) == doublePrime || next(1) == voicedMark) && next(2) == backslash:
            return AozoraToken(kind: .kunojiten(voiced: true), range: index..<(index + 3))
        default:
            return nil
        }
    }

    /// A non-empty reading on the same line. Annotations inside the reading
    /// (a gaiji, a note) are skipped whole; another 《 means this one is text.
    private static func rubyEnd(in units: [UInt16], from start: Int, limit: Int) -> Int? {
        var index = start + 1
        while index < limit {
            let unit = units[index]
            if unit == rubyClose { return index > start + 1 ? index + 1 : nil }
            if unit == rubyOpen || isNewline(unit) { return nil }
            if unit == bracketOpen, index + 1 < limit, units[index + 1] == sharp,
               let end = annotationEnd(in: units, from: index, limit: limit) {
                index = end
                continue
            }
            index += 1
        }
        return nil
    }

    /// 〔 up to its 〕 on the same line, or to the end of the line when it never
    /// closes (aozora2html's AccentParser reads to 〕 or the line end).
    private static func accent(in units: [UInt16], from start: Int, limit: Int) -> AozoraToken {
        var index = start + 1
        while index < limit {
            let unit = units[index]
            if unit == accentClose {
                return AozoraToken(kind: .accent(closed: true), range: start..<(index + 1))
            }
            if isNewline(unit) { break }
            if unit == bracketOpen, index + 1 < limit, units[index + 1] == sharp,
               let end = annotationEnd(in: units, from: index, limit: limit) {
                index = end
                continue
            }
            index += 1
        }
        return AozoraToken(kind: .accent(closed: false), range: start..<index)
    }
}
