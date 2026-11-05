import Foundation

/// Aozora inline markup becomes the same RenderableNode.ruby used by EPUB.
/// Removed UTF-16 ranges also project historical TXT offsets into displayed text.
enum AozoraMarkupParser {
    struct Result {
        let nodes: [RenderableNode]
        let plainText: String
        /// The notes hidden, in the source's UTF-16 offsets.
        let noteRanges: [NSRange]
        /// The ruby markup removed (｜ and 《reading》), in offsets of the text with its notes hidden.
        let rubyRanges: [NSRange]

        var hasChanges: Bool { !noteRanges.isEmpty || !rubyRanges.isEmpty }

        fileprivate init(nodes: [RenderableNode], plainText: String,
                         noteRanges: [NSRange], rubyRanges: [NSRange]) {
            self.nodes = nodes
            self.plainText = plainText
            self.noteRanges = noteRanges
            self.rubyRanges = rubyRanges
        }

        func displayedOffset(forSourceOffset offset: Int) -> Int {
            Self.project(Self.project(offset, through: noteRanges), through: rubyRanges)
        }

        /// The first source offset shown at `displayed`: a location just after removed markup
        /// goes back to before it, which projects forward to the same displayed offset.
        func sourceOffset(forDisplayedOffset displayed: Int) -> Int {
            let removed = noteRanges.reduce(0) { $0 + $1.length } + rubyRanges.reduce(0) { $0 + $1.length }
            var low = 0, high = displayed + removed
            while low < high {
                let mid = (low + high) / 2
                if displayedOffset(forSourceOffset: mid) < displayed { low = mid + 1 } else { high = mid }
            }
            return low
        }

        private static func project(_ offset: Int, through ranges: [NSRange]) -> Int {
            offset - ranges.reduce(0) { removed, range in
                removed + max(0, min(range.length, offset - range.location))
            }
        }

        var paragraphs: [[RenderableNode]] {
            var result: [[RenderableNode]] = []
            var current: [RenderableNode] = []
            for node in nodes {
                if case .text(let text) = node {
                    let parts = text.components(separatedBy: "\n")
                    for (index, part) in parts.enumerated() {
                        if index > 0 { result.append(current); current = [] }
                        if !part.isEmpty { current.append(.text(part)) }
                    }
                } else { current.append(node) }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    /// The markup is read by the Aozora module's tokenizer, in the TXT reader's dialect
    /// (`AozoraTokenizer.Dialect.txt`, Aozora plan, Task 18); what it does with each piece is
    /// this reader's own: notes are hidden, ruby shown, and nothing else converted (no gaiji,
    /// accent or くの字点). The displayed text is the one this reader has always shown, which
    /// stored positions index.
    static func parse(_ source: String) -> Result {
        guard source.contains("《") || source.contains("［＃") else {
            return Result(nodes: source.isEmpty ? [] : [.text(source)], plainText: source,
                          noteRanges: [], rubyRanges: [])
        }
        let (cleaned, noteRanges) = AozoraTokenizer.txtNotes(in: source)
        let units = Array(cleaned.utf16)
        let count = units.count
        // This reader reads characters as Swift does: a ｜, 《 or 》 that shares a character
        // with its neighbour (a combining mark after it) is text, so the tokenizer reads it
        // masked.
        var boundaries = [Bool](repeating: false, count: count + 1)
        var offset = 0
        for character in cleaned {
            boundaries[offset] = true
            offset += character.utf16.count
        }
        boundaries[count] = true
        var delimiters = units
        for index in 0..<count where !(boundaries[index] && boundaries[index + 1]) {
            switch units[index] {
            case AozoraTokenizer.rubyBar, AozoraTokenizer.rubyOpen, AozoraTokenizer.rubyClose: delimiters[index] = 0xFFFF
            default: break
            }
        }

        var nodes: [RenderableNode] = [], deletions: [NSRange] = []
        var plainText = "", buffer: [UInt16] = [], index = 0
        func string(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = String(decoding: buffer, as: UTF16.self)
            nodes.append(.text(text)); plainText += text; buffer.removeAll(keepingCapacity: true)
        }
        func appendRuby(base: String, ruby: AozoraToken) {
            nodes.append(.ruby(base: [.text(base)], text: string(ruby.content)))
            plainText += base
            deletions.append(NSRange(location: ruby.range.lowerBound, length: ruby.range.count))
        }

        while index < count {
            guard let token = AozoraTokenizer.markup(in: delimiters, at: index, limit: count, dialect: .txt) else {
                buffer.append(units[index])
                index += 1
                continue
            }
            switch token.kind {
            case .rubyBar:
                // ｜base《reading》: the base runs to the next 《, ｜ or line end.
                var opening = index + 1
                while opening < count, delimiters[opening] != AozoraTokenizer.rubyOpen,
                      delimiters[opening] != AozoraTokenizer.rubyBar,
                      !AozoraTokenizer.isLineSeparator(delimiters[opening]) { opening += 1 }
                if opening > index + 1, opening < count,
                   let ruby = AozoraTokenizer.markup(in: delimiters, at: opening, limit: count, dialect: .txt),
                   ruby.kind == .ruby {
                    flush()
                    deletions.append(NSRange(location: index, length: 1))
                    appendRuby(base: string((index + 1)..<opening), ruby: ruby)
                    index = ruby.range.upperBound
                    continue
                }
            case .ruby:
                // Bare 《》 are also Chinese book-title punctuation. Kana is the
                // positive signal for implicit Japanese ruby; ｜ is unambiguous.
                if string(token.content).unicodeScalars.contains(where: isKana) {
                    let text = String(decoding: buffer, as: UTF16.self)
                    let baseLength = text.reversed().prefix(while: isHan).count
                    if baseLength > 0 {
                        buffer = Array(text.dropLast(baseLength).utf16); flush()
                        appendRuby(base: String(text.suffix(baseLength)), ruby: token)
                        index = token.range.upperBound
                        continue
                    }
                }
            case .newline:
                buffer.append(contentsOf: units[token.range])
                index = token.range.upperBound
                continue
            case .text, .annotation, .gaiji, .accent, .kunojiten:
                break
            }
            // Markup read back as text: its first unit, and on from the next.
            buffer.append(units[index])
            index += 1
        }
        flush()
        return Result(nodes: nodes, plainText: plainText, noteRanges: noteRanges, rubyRanges: deletions)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA,
             0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return true
        default:
            return false
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        let han: Bool
        switch first.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x323AF, 0x3005...0x3007, 0x303B: han = true
        default: han = false
        }
        return han && character.unicodeScalars.dropFirst().allSatisfy {
            (0xFE00...0xFE0F).contains($0.value) || (0xE0100...0xE01EF).contains($0.value)
        }
    }
}
