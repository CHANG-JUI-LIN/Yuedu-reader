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
    /// Which reading of the markup.
    enum Dialect: Sendable {
        /// aozora2html's, for the converter (`AozoraDocumentParser`).
        case document
        /// The TXT reader's (`AozoraMarkupParser`), which shows a TXT book's ruby and hides its
        /// notes, read as it always has been: its displayed text has no position migration, so
        /// it must not move (Aozora plan, Task 18). Its notes are found first, over the whole
        /// text (`txtNotes(in:)`), and its ruby is then read in the text without them: there is
        /// no annotation, gaiji, accent or くの字点 token, so ※, 〔〕 and ／＼ stay text, and a
        /// reading also ends at any line separator (U+000B, U+000C, U+0085, U+2028, U+2029).
        case txt
    }

    /// The TXT dialect's notes: each ［＃ to the first ］ after it, nothing nested, across lines,
    /// matched as `NSString` matches them, so a ［＃ or ］ with a combining mark after it is no
    /// delimiter; an unclosed ［＃ ends the search. The text without them, and their ranges.
    static func txtNotes(in text: String) -> (shown: String, notes: [NSRange]) {
        let ns = text as NSString
        var cursor = 0, shown = "", notes: [NSRange] = []
        while cursor < ns.length {
            let opening = ns.range(of: "［＃", range: NSRange(location: cursor, length: ns.length - cursor))
            guard opening.location != NSNotFound else { break }
            let contentStart = NSMaxRange(opening)
            let closing = ns.range(of: "］", range: NSRange(location: contentStart, length: ns.length - contentStart))
            guard closing.location != NSNotFound else { break }
            shown += ns.substring(with: NSRange(location: cursor, length: opening.location - cursor))
            notes.append(NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location))
            cursor = NSMaxRange(closing)
        }
        shown += ns.substring(from: cursor)
        return (shown, notes)
    }

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
            guard let token = markup(in: units, at: index, limit: limit) else {
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

    /// Every unit Swift's `Character.isNewline` holds: the TXT reader's line ends.
    static func isLineSeparator(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
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

    /// The markup starting at `index`, or nil for a unit of text. A reader that takes markup
    /// back as text (the TXT reader's ruby without a base) reads on from its next unit.
    static func markup(in units: [UInt16], at index: Int, limit: Int, dialect: Dialect = .document) -> AozoraToken? {
        let unit = units[index]
        func next(_ offset: Int) -> UInt16? {
            index + offset < limit ? units[index + offset] : nil
        }
        if dialect == .txt {
            switch unit {
            case lineFeed:
                return AozoraToken(kind: .newline, range: index..<(index + 1))
            case carriageReturn:
                return AozoraToken(kind: .newline, range: index..<(index + (next(1) == lineFeed ? 2 : 1)))
            case rubyBar:
                return AozoraToken(kind: .rubyBar, range: index..<(index + 1))
            case rubyOpen:
                return rubyEnd(in: units, from: index, limit: limit, dialect: .txt)
                    .map { AozoraToken(kind: .ruby, range: index..<$0) }
            default:
                return nil
            }
        }
        switch unit {
        case lineFeed:
            return AozoraToken(kind: .newline, range: index..<(index + 1))
        case carriageReturn:
            return AozoraToken(kind: .newline, range: index..<(index + (next(1) == lineFeed ? 2 : 1)))
        case rubyBar:
            return AozoraToken(kind: .rubyBar, range: index..<(index + 1))
        case rubyOpen:
            return rubyEnd(in: units, from: index, limit: limit, dialect: .document)
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
    /// In the TXT dialect the notes are gone already, and nothing is skipped.
    private static func rubyEnd(in units: [UInt16], from start: Int, limit: Int, dialect: Dialect) -> Int? {
        var index = start + 1
        while index < limit {
            let unit = units[index]
            if unit == rubyClose { return index > start + 1 ? index + 1 : nil }
            if unit == rubyOpen || (dialect == .txt ? isLineSeparator(unit) : isNewline(unit)) { return nil }
            if dialect == .document, unit == bracketOpen, index + 1 < limit, units[index + 1] == sharp,
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
