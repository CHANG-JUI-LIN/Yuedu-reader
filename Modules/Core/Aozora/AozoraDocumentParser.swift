import Foundation

/// The decoded text as UTF-16 code units with its lines. Every offset the
/// parser reports is a UTF-16 offset into this text.
struct AozoraSource: Sendable {
    let units: [UInt16]
    /// Each line's content, without its line break. Split at \r\n, \n and \r;
    /// a text ending in a line break has an empty last line.
    let lines: [Range<Int>]
    /// Where each line ends, its line break included.
    let lineEnds: [Int]

    init(_ text: String) {
        let units = Array(text.utf16)
        var lines: [Range<Int>] = []
        var lineEnds: [Int] = []
        var start = 0
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard AozoraTokenizer.isNewline(unit) else {
                index += 1
                continue
            }
            var end = index + 1
            if unit == AozoraTokenizer.carriageReturn, end < units.count, units[end] == AozoraTokenizer.lineFeed {
                end += 1
            }
            lines.append(start..<index)
            lineEnds.append(end)
            start = end
            index = end
        }
        lines.append(start..<units.count)
        lineEnds.append(units.count)
        self.units = units
        self.lines = lines
        self.lineEnds = lineEnds
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    func line(_ index: Int) -> String {
        string(lines[index])
    }

    /// The source range of whole lines, line breaks included.
    func range(ofLines lines: Range<Int>) -> Range<Int> {
        guard !lines.isEmpty else {
            let start = lines.lowerBound < self.lines.count ? self.lines[lines.lowerBound].lowerBound : units.count
            return start..<start
        }
        return self.lines[lines.lowerBound].lowerBound..<lineEnds[lines.upperBound - 1]
    }
}

/// The four parts aozora2html's state machine reads (`:head` → `:chuuki` →
/// `:body` → `:tail`), as line indices.
struct AozoraDocumentStructure: Equatable, Sendable {
    /// The lines before the first blank line.
    var header: Range<Int>
    /// The notation block, both hyphen lines included. Dropped from the book.
    var notationBlock: ClosedRange<Int>?
    var body: Range<Int>
    /// From the first line starting with 底本： to the end.
    var colophon: Range<Int>
}

/// 底本, 初出, 入力 and 校正 from the colophon, continuation lines included.
struct AozoraBibliography: Equatable, Sendable {
    /// 底本: the printed edition the text was keyed from.
    var source: String?
    /// 初出: where the work first appeared.
    var firstPublished: String?
    /// 入力: who typed it in.
    var input: String?
    /// 校正: who proofread it.
    var proofreading: String?
}

struct AozoraDocument: Equatable, Sendable {
    var structure: AozoraDocumentStructure
    var header: AozoraHeader?
    var bibliography: AozoraBibliography
    /// The header lines as a title page shows them.
    var headerBlocks: [AozoraBlock]
    var body: [AozoraBlock]
    var colophon: [AozoraBlock]
    var diagnostics: AozoraDiagnostics
}

/// The only place that reads Aozora Bunko notation.
enum AozoraDocumentParser {
    static func parse(_ text: String, tables: AozoraTables = .shared) -> AozoraDocument {
        let source = AozoraSource(text)
        var diagnostics = AozoraDiagnostics()
        let structure = structure(of: source, diagnostics: &diagnostics)
        let parser = AozoraBlockParser(source: source, tables: tables, diagnostics: diagnostics)
        let headerBlocks = parser.parse(lines: structure.header)
        let body = parser.parse(lines: structure.body)
        let colophon = parser.parse(lines: structure.colophon)
        return AozoraDocument(
            structure: structure,
            header: AozoraHeaderParser.parse(headerLines: headerBlocks.map(\.displayedText)),
            bibliography: bibliography(of: colophon.map(\.displayedText)),
            headerBlocks: headerBlocks, body: body, colophon: colophon,
            diagnostics: parser.diagnostics)
    }

    /// The header lines as the reader shows them: everything before the first
    /// blank line, ruby bases kept and gaiji resolved. Reads only those lines.
    static func headerLines(of text: String, tables: AozoraTables = .shared) -> [String] {
        let source = AozoraSource(text)
        let headerEnd = source.lines.indices.first {
            source.line($0).allSatisfy(\.isWhitespace)
        } ?? source.lines.count
        let parser = AozoraBlockParser(source: source, tables: tables, diagnostics: AozoraDiagnostics())
        return parser.parse(lines: 0..<headerEnd).map(\.displayedText)
    }

    // MARK: Sections

    static func structure(of source: AozoraSource, diagnostics: inout AozoraDiagnostics) -> AozoraDocumentStructure {
        let lineCount = source.lines.count
        func isBlank(_ index: Int) -> Bool {
            source.line(index).allSatisfy(\.isWhitespace)
        }
        func isHyphenLine(_ index: Int) -> Bool {
            AozoraDocumentDetector.isHyphenLine(Substring(source.line(index)))
        }

        let headerEnd = (0..<lineCount).first(where: isBlank) ?? lineCount
        var bodyStart = headerEnd
        var notationBlock: ClosedRange<Int>?
        // The census and aozora2html: the first non-blank line within five
        // lines of the header must be a hyphen line, and the next hyphen line
        // closes the block.
        if let opening = (headerEnd..<min(lineCount, headerEnd + 5)).first(where: { !isBlank($0) }),
           isHyphenLine(opening) {
            if let closing = ((opening + 1)..<lineCount).first(where: isHyphenLine) {
                if ((opening + 1)..<closing).contains(where: { explainsNotation(source.line($0)) }) {
                    notationBlock = opening...closing
                    bodyStart = closing + 1
                }
            } else {
                diagnostics.record(.unclosedNotationBlock)
            }
        }
        let colophonStart = (bodyStart..<lineCount).first {
            AozoraDocumentDetector.isColophonStart(Substring(source.line($0)))
        } ?? lineCount
        return AozoraDocumentStructure(header: 0..<headerEnd, notationBlock: notationBlock,
                                       body: bodyStart..<colophonStart, colophon: colophonStart..<lineCount)
    }

    /// Whether a hyphen-fenced block explains notation: it defines a symbol
    /// (《》：ルビ, ［＃］：入力者注 …) or its title mentions 記号 or 表記. On the
    /// 2023-03 corpus this accepts 16,007 blocks and refuses the 3 that fence
    /// body text instead; one of them would have dropped 1,125 lines of poems.
    static func explainsNotation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("記号について") || trimmed.contains("表記について") { return true }
        for symbol in ["《》", "｜", "［＃］", "〔〕", "／＼", "／″＼", "※"] {
            if trimmed.hasPrefix(symbol + "：") || trimmed.hasPrefix(symbol + ":") { return true }
        }
        return false
    }

    // MARK: Colophon

    static func bibliography(of lines: [String]) -> AozoraBibliography {
        let fields: [(String, WritableKeyPath<AozoraBibliography, String?>)] = [
            ("底本", \.source), ("初出", \.firstPublished), ("入力", \.input), ("校正", \.proofreading),
        ]
        var result = AozoraBibliography()
        var current: WritableKeyPath<AozoraBibliography, String?>?
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            if let (label, field) = fields.first(where: { line.hasPrefix($0.0 + "：") || line.hasPrefix($0.0 + ":") }) {
                let text = String(value.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
                result[keyPath: field] = result[keyPath: field].map { $0 + "\n" + text } ?? text
                current = field
            } else if let field = current, line.first?.isWhitespace == true, !value.isEmpty {
                // An indented line continues the field above it, e.g. the
                // printing under 底本：.
                result[keyPath: field] = (result[keyPath: field] ?? "") + "\n" + value
            } else {
                current = nil
            }
        }
        return result
    }

    // MARK: Gaiji

    private static let jisCode = try! NSRegularExpression(pattern: #"(?<![\d\-])([12])-(\d{1,2})-(\d{1,2})(?![\d\-])"#)
    private static let unicodeCode = try! NSRegularExpression(pattern: #"U\+([0-9A-Fa-f]{4,6})"#)

    /// ※［＃description、code］ (the content between ［＃ and ］). A JIS X 0213
    /// code wins over U+ (aozora2html and the census agree); without either,
    /// the description is all there is.
    static func gaiji(_ content: String, tables: AozoraTables) -> (gaiji: AozoraGaiji, unmapped: Bool) {
        let description = gaijiDescription(content)
        let range = NSRange(content.startIndex..., in: content)
        if let match = jisCode.firstMatch(in: content, range: range) {
            let numbers = (1...3).compactMap { Range(match.range(at: $0), in: content).flatMap { Int(content[$0]) } }
            let code = AozoraGaijiCode.jis(plane: numbers[0], row: numbers[1], cell: numbers[2])
            let resolved = tables.character(plane: numbers[0], row: numbers[1], cell: numbers[2])
            return (AozoraGaiji(resolved: resolved, description: description, code: code), resolved == nil)
        }
        if let match = unicodeCode.firstMatch(in: content, range: range),
           let hex = Range(match.range(at: 1), in: content),
           let value = UInt32(content[hex], radix: 16) {
            let resolved = Unicode.Scalar(value).map { String(Character($0)) }
            return (AozoraGaiji(resolved: resolved, description: description, code: .unicode(value)), resolved == nil)
        }
        return (AozoraGaiji(resolved: nil, description: description, code: nil), false)
    }

    /// 「口＋世」、ページ数-行数 → 口＋世; コト、1-2-24 → コト. The page-line
    /// reference and the code after the first 、 are dropped.
    static func gaijiDescription(_ content: String) -> String {
        if content.hasPrefix("「") {
            var depth = 0
            for index in content.indices {
                switch content[index] {
                case "「": depth += 1
                case "」":
                    depth -= 1
                    if depth == 0 {
                        return String(content[content.index(after: content.startIndex)..<index])
                    }
                default: break
                }
            }
        }
        return String(content.prefix { $0 != "、" })
    }
}

// MARK: - Character classes

/// The ruby base classes of aozora2html `string_refinements.rb`: a ruby
/// without ｜ covers the run of one class before 《. Ranges that aozora2html
/// writes in Shift_JIS order are given here in Unicode; ideographs outside
/// JIS X 0208 count as kanji, since a UTF-8 file can hold them directly.
enum AozoraCharType: Equatable {
    case hiragana, katakana, zenkaku, hankaku, kanji, hankakuTerminator, other

    init(_ character: Character) {
        guard let scalar = character.unicodeScalars.first else {
            self = .other
            return
        }
        switch scalar.value {
        case 0x3041...0x3096, 0x309D, 0x309E:
            self = .hiragana
        case 0x30A1...0x30F4, 0x30FC, 0x30FD, 0x30FE:
            self = .katakana
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
             0x0391...0x03A9, 0x03B1...0x03C9, 0x0401, 0x0410...0x044F, 0x0451,
             0x2212, 0xFF0D, 0xFF06, 0x2019, 0xFF0C, 0xFF0E:
            self = .zenkaku
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x23, 0x2D, 0x26, 0x27, 0x2C:
            self = .hankaku
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF,
             0x3005, 0x3006, 0x3007, 0x303B, 0x203B, 0x30F6:
            self = .kanji
        case 0x2E, 0x3B, 0x22, 0x3F, 0x21, 0x29:
            self = .hankakuTerminator
        default:
            self = .other
        }
    }
}

// MARK: - Building blocks

/// A styled run in the tree being built.
private enum AozoraContainer {
    case ruby(reading: String, side: AozoraSide)
}

/// The mutable tree a block is built in, frozen into AozoraInline when the
/// block ends. Leaves remember the source range their text stands for.
private final class AozoraNode {
    enum Kind {
        case text
        case gaiji(AozoraGaiji)
        case unknownAnnotation
        case container(AozoraContainer)
    }

    var kind: Kind
    /// A visible leaf's displayed text; an annotation's command.
    var text: String
    /// A text leaf copied verbatim from `source`; only these grow and split.
    var isVerbatim: Bool
    var source: Range<Int>
    var children: [AozoraNode]

    init(kind: Kind, text: String = "", isVerbatim: Bool = false, source: Range<Int>, children: [AozoraNode] = []) {
        self.kind = kind
        self.text = text
        self.isVerbatim = isVerbatim
        self.source = source
        self.children = children
    }

    static func text(_ text: String, source: Range<Int>, verbatim: Bool) -> AozoraNode {
        AozoraNode(kind: .text, text: text, isVerbatim: verbatim, source: source)
    }

    /// UTF-16 offset `offset` splits this verbatim leaf in two; this node keeps
    /// the head and the returned node holds the tail.
    func split(at offset: Int) -> AozoraNode {
        let units = Array(text.utf16)
        let tail = AozoraNode.text(String(decoding: units[offset...], as: UTF16.self),
                                   source: (source.lowerBound + offset)..<source.upperBound, verbatim: true)
        text = String(decoding: units[..<offset], as: UTF16.self)
        source = source.lowerBound..<(source.lowerBound + offset)
        return tail
    }

    /// Whether the node shows anything. Annotations do not; a ruby does even
    /// with an empty base, since its reading is drawn.
    var isContent: Bool {
        switch kind {
        case .text, .gaiji, .container: return true
        case .unknownAnnotation: return false
        }
    }
}

private func freeze(_ nodes: [AozoraNode]) -> [AozoraInline] {
    var result: [AozoraInline] = []
    for node in nodes {
        switch node.kind {
        case .text:
            if case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + node.text)
            } else {
                result.append(.text(node.text))
            }
        case .gaiji(let gaiji):
            result.append(.gaiji(gaiji))
        case .unknownAnnotation:
            result.append(.unknownAnnotation(node.text))
        case .container(.ruby(let reading, let side)):
            result.append(.ruby(base: freeze(node.children), reading: reading, side: side))
        }
    }
    return result
}

/// Reads the lines of one section into blocks: one paragraph per line; a blank
/// line is an empty paragraph, a line holding only annotations is no block.
private final class AozoraBlockParser {
    let source: AozoraSource
    let tables: AozoraTables
    private(set) var diagnostics: AozoraDiagnostics

    private var blocks: [AozoraBlock] = []
    private var nodes: [AozoraNode] = []
    private var lineHasTokens = false
    private var run = RubyRun()

    /// Where a ruby base would start: the run of one character class before
    /// 《, or everything after ｜. Port of aozora2html's RubyBuffer.
    private struct RubyRun {
        /// Node index, and a UTF-16 offset into that node when it is text.
        var start: (index: Int, offset: Int)?
        var type: AozoraCharType?
        var isProtected = false
        var pendingBar: Range<Int>?
    }

    init(source: AozoraSource, tables: AozoraTables, diagnostics: AozoraDiagnostics) {
        self.source = source
        self.tables = tables
        self.diagnostics = diagnostics
    }

    func parse(lines: Range<Int>) -> [AozoraBlock] {
        blocks = []
        nodes = []
        run = RubyRun()
        lineHasTokens = false
        let range = source.range(ofLines: lines)
        for token in AozoraTokenizer.tokenize(source.units, in: range) {
            if token.kind == .newline {
                finishLine()
            } else {
                lineHasTokens = true
                handle(token, accents: false)
            }
        }
        // A section's last line has no line break when it ends the file; the
        // empty line after a final line break is not a line of the book.
        if lineHasTokens { finishLine() }
        return blocks
    }

    // MARK: Lines

    private func finishLine() {
        restorePendingBar()
        if !lineHasTokens {
            blocks.append(.paragraph([], .plain))
        } else if nodes.contains(where: \.isContent) {
            blocks.append(.paragraph(freeze(nodes), .plain))
        }
        nodes = []
        run = RubyRun()
        lineHasTokens = false
    }

    // MARK: Tokens

    private func handle(_ token: AozoraToken, accents: Bool) {
        switch token.kind {
        case .text:
            appendText(token.range, accents: accents)
        case .rubyBar:
            restorePendingBar()
            run = RubyRun(start: (nodes.count, 0), type: nil, isProtected: true, pendingBar: token.range)
        case .ruby:
            applyRuby(reading: visibleText(token.content), side: .right)
        case .gaiji:
            let (gaiji, unmapped) = AozoraDocumentParser.gaiji(source.string(token.content), tables: tables)
            if unmapped { diagnostics.record(.unmappedGaijiCode) }
            if gaiji.resolved == nil { diagnostics.record(.unresolvedGaiji) }
            appendLeaf(AozoraNode(kind: .gaiji(gaiji), text: gaiji.displayedText, source: token.range), type: .kanji)
        case .accent(let closed):
            appendAccent(token, closed: closed)
        case .kunojiten(let voiced):
            appendLeaf(.text(voiced ? "\u{3034}\u{3035}" : "\u{3033}\u{3035}", source: token.range, verbatim: false),
                       type: .other)
        case .annotation:
            nodes.append(AozoraNode(kind: .unknownAnnotation, text: source.string(token.content), source: token.range))
        case .newline:
            break
        }
    }

    // MARK: Text and ruby

    private func appendText(_ range: Range<Int>, accents: Bool) {
        let characters = Array(source.string(range))
        var offset = range.lowerBound
        var index = 0
        while index < characters.count {
            if accents, let (resolved, length) = accent(in: characters, at: index) {
                let width = characters[index..<(index + length)].reduce(0) { $0 + $1.utf16.count }
                appendLeaf(.text(resolved, source: offset..<(offset + width), verbatim: false), type: .hankaku)
                offset += width
                index += length
                continue
            }
            let character = characters[index]
            let width = character.utf16.count
            appendCharacter(character, source: offset..<(offset + width))
            offset += width
            index += 1
        }
    }

    /// The accent decomposition starting at `index`: three characters (AE&)
    /// before two (e').
    private func accent(in characters: [Character], at index: Int) -> (String, Int)? {
        for length in [3, 2] where index + length <= characters.count {
            if let resolved = tables.accent(String(characters[index..<(index + length)])) {
                return (resolved, length)
            }
        }
        return nil
    }

    private func appendCharacter(_ character: Character, source range: Range<Int>) {
        let type = AozoraCharType(character)
        if let last = nodes.last, case .text = last.kind, last.isVerbatim, last.source.upperBound == range.lowerBound {
            if beginsRun(type) { run.start = (nodes.count - 1, last.text.utf16.count) }
            last.text.append(character)
            last.source = last.source.lowerBound..<range.upperBound
        } else {
            if beginsRun(type) { run.start = (nodes.count, 0) }
            nodes.append(.text(String(character), source: range, verbatim: true))
        }
    }

    private func appendLeaf(_ node: AozoraNode, type: AozoraCharType) {
        if beginsRun(type) { run.start = (nodes.count, 0) }
        nodes.append(node)
    }

    /// aozora2html RubyBuffer#push_char: true when the character starts a new
    /// run, after updating the run's class.
    private func beginsRun(_ type: AozoraCharType) -> Bool {
        if type == .hankakuTerminator, run.type == .hankaku {
            run.type = .other
            return false
        }
        if run.isProtected { return false }
        if type != .other, type == run.type { return false }
        run.type = type
        return true
    }

    private func applyRuby(reading: String, side: AozoraSide) {
        let base: [AozoraNode]
        if let start = run.start {
            let index = splitNodes(at: start)
            base = Array(nodes[index...])
            nodes.removeSubrange(index...)
        } else {
            base = []
        }
        let lower = base.first?.source.lowerBound ?? 0
        let upper = base.last?.source.upperBound ?? lower
        nodes.append(AozoraNode(kind: .container(.ruby(reading: reading, side: side)),
                                source: lower..<upper, children: base))
        run = RubyRun()
    }

    /// A ｜ that never met its reading is shown as written, in front of the
    /// text it would have marked.
    private func restorePendingBar() {
        guard run.isProtected, let bar = run.pendingBar, let start = run.start else { return }
        let index = splitNodes(at: start)
        nodes.insert(.text("｜", source: bar, verbatim: true), at: index)
        run.pendingBar = nil
        run.isProtected = false
    }

    /// Makes `position` a node boundary and returns the node index there.
    private func splitNodes(at position: (index: Int, offset: Int)) -> Int {
        guard position.index < nodes.count, position.offset > 0 else { return position.index }
        let node = nodes[position.index]
        guard position.offset < node.text.utf16.count else { return position.index + 1 }
        nodes.insert(node.split(at: position.offset), at: position.index + 1)
        return position.index + 1
    }

    // MARK: Accents

    /// 〔…〕 holding an accent decomposition loses its brackets and has every
    /// decomposition replaced (aozora2html AccentParser); any other 〔…〕 stays
    /// as written. An unclosed 〔 reaches to the end of its line.
    private func appendAccent(_ token: AozoraToken, closed: Bool) {
        let inner = AozoraTokenizer.tokenize(source.units, in: token.content)
        let converts = inner.contains { $0.kind == .text && containsAccent($0.range) }
        if converts {
            for part in inner { handle(part, accents: true) }
            return
        }
        appendCharacter("〔", source: token.range.lowerBound..<(token.range.lowerBound + 1))
        for part in inner { handle(part, accents: false) }
        if closed {
            appendCharacter("〕", source: (token.range.upperBound - 1)..<token.range.upperBound)
        }
    }

    private func containsAccent(_ range: Range<Int>) -> Bool {
        let characters = Array(source.string(range))
        return characters.indices.contains { accent(in: characters, at: $0) != nil }
    }

    // MARK: Visible text of nested markup

    /// What a ruby reading or a forward reference shows: text, gaiji and
    /// converted accents; ruby readings and annotations inside are dropped.
    func visibleText(_ range: Range<Int>) -> String {
        var result = ""
        for token in AozoraTokenizer.tokenize(source.units, in: range) {
            switch token.kind {
            case .text:
                result += source.string(token.range)
            case .gaiji:
                result += AozoraDocumentParser.gaiji(source.string(token.content), tables: tables).gaiji.displayedText
            case .kunojiten(let voiced):
                result += voiced ? "\u{3034}\u{3035}" : "\u{3033}\u{3035}"
            case .accent(let closed):
                let inner = AozoraTokenizer.tokenize(source.units, in: token.content)
                if inner.contains(where: { $0.kind == .text && containsAccent($0.range) }) {
                    result += convertedAccents(inner)
                } else {
                    result += "〔" + visibleText(token.content) + (closed ? "〕" : "")
                }
            case .ruby, .annotation, .rubyBar, .newline:
                break
            }
        }
        return result
    }

    private func convertedAccents(_ tokens: [AozoraToken]) -> String {
        var result = ""
        for token in tokens {
            guard token.kind == .text else {
                result += visibleText(token.range)
                continue
            }
            let characters = Array(source.string(token.range))
            var index = 0
            while index < characters.count {
                if let (resolved, length) = accent(in: characters, at: index) {
                    result += resolved
                    index += length
                } else {
                    result.append(characters[index])
                    index += 1
                }
            }
        }
        return result
    }
}
