import Foundation

/// Aozora inline markup becomes the same RenderableNode.ruby used by EPUB.
/// Removed UTF-16 ranges also project historical TXT offsets into displayed text.
enum AozoraMarkupParser {
    struct Result {
        let nodes: [RenderableNode]
        let plainText: String
        private let noteRanges: [NSRange]
        private let rubyRanges: [NSRange]

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

    static func parse(_ source: String) -> Result {
        guard source.contains("《") || source.contains("［＃") else {
            return Result(nodes: source.isEmpty ? [] : [.text(source)], plainText: source,
                          noteRanges: [], rubyRanges: [])
        }
        let (cleaned, noteRanges) = stripNotes(source)
        let characters = Array(cleaned)
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        var nodes: [RenderableNode] = [], buffer: [Character] = [], deletions: [NSRange] = []
        var plainText = "", index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = String(buffer)
            nodes.append(.text(text)); plainText += text; buffer.removeAll(keepingCapacity: true)
        }
        func closingRuby(after opening: Int) -> Int? {
            var cursor = opening + 1
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "》" { return cursor > opening + 1 ? cursor : nil }
                if character.isNewline || character == "《" { return nil }
                cursor += 1
            }
            return nil
        }
        func appendRuby(base: String, opening: Int, closing: Int) {
            let reading = String(characters[(opening + 1)..<closing])
            nodes.append(.ruby(base: [.text(base)], text: reading))
            plainText += base
            deletions.append(NSRange(location: offsets[opening], length: offsets[closing + 1] - offsets[opening]))
        }

        while index < characters.count {
            let character = characters[index]
            if character == "｜" {
                var opening = index + 1
                while opening < characters.count, characters[opening] != "《",
                      characters[opening] != "｜", !characters[opening].isNewline { opening += 1 }
                if opening > index + 1, opening < characters.count, characters[opening] == "《",
                   let closing = closingRuby(after: opening) {
                    flush()
                    deletions.append(NSRange(location: offsets[index], length: 1))
                    appendRuby(base: String(characters[(index + 1)..<opening]), opening: opening, closing: closing)
                    index = closing + 1
                    continue
                }
            } else if character == "《", let closing = closingRuby(after: index) {
                let reading = String(characters[(index + 1)..<closing])
                // Bare 《》 are also Chinese book-title punctuation. Kana is the
                // positive signal for implicit Japanese ruby; ｜ is unambiguous.
                if reading.unicodeScalars.contains(where: isKana) {
                    let count = buffer.reversed().prefix(while: isHan).count
                    if count > 0 {
                        let base = String(buffer.suffix(count))
                        buffer.removeLast(count); flush()
                        appendRuby(base: base, opening: index, closing: closing)
                        index = closing + 1
                        continue
                    }
                }
            }
            buffer.append(character)
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

    /// Strip every complete editorial directive, including notes spanning lines.
    /// Formatting (size, emphasis, page breaks, gaiji descriptions) is not applied.
    private static func stripNotes(_ source: String) -> (String, [NSRange]) {
        let ns = source as NSString
        var cursor = 0, text = "", ranges: [NSRange] = []
        while cursor < ns.length {
            let opening = ns.range(of: "［＃", range: NSRange(location: cursor, length: ns.length - cursor))
            guard opening.location != NSNotFound else { break }
            let contentStart = NSMaxRange(opening)
            let closing = ns.range(of: "］", range: NSRange(location: contentStart, length: ns.length - contentStart))
            guard closing.location != NSNotFound else { break }
            text += ns.substring(with: NSRange(location: cursor, length: opening.location - cursor))
            ranges.append(NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location))
            cursor = NSMaxRange(closing)
        }
        text += ns.substring(from: cursor)
        return (text, ranges)
    }
}
