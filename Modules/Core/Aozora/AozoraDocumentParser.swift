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
    /// What the reader sees: the header, body and colophon blocks joined by
    /// "\n". The notation block is not part of it.
    var displayedText: String
    /// Between UTF-16 offsets of `displayedText` and of the source text.
    var sourceMap: AozoraSourceMap
    var diagnostics: AozoraDiagnostics
}

/// The only place that reads Aozora Bunko notation.
enum AozoraDocumentParser {
    /// Parses a whole document, timed as `aozora.parse`. What could not be read
    /// is logged once per document, as counts, never per occurrence.
    static func parse(_ text: String, tables: AozoraTables = .shared) -> AozoraDocument {
        let document = SourcePerfTrace.span("aozora.parse", "units=\(text.utf16.count)") {
            parseDocument(text, tables: tables)
        }
        AppLogger.parse(
            "[Aozora] \(document.sourceMap.sourceLength) units, \(document.body.count) body blocks: "
                + document.diagnostics.summary,
            level: document.diagnostics.isEmpty ? .info : .notice)
        return document
    }

    private static func parseDocument(_ text: String, tables: AozoraTables) -> AozoraDocument {
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
            displayedText: parser.segments.map(\.text).joined(),
            sourceMap: AozoraSourceMap(segments: parser.segments, source: source.units),
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

/// A run of nodes that styles or annotates its children.
private enum AozoraContainer {
    case ruby(reading: String, side: AozoraSide)
    case style(AozoraCommandTable.Style)
    /// A figure; its children are the caption.
    case image(source: String, width: Int?, height: Int?)
}

/// The mutable tree a block is built in, frozen into AozoraInline when the
/// block ends. Leaves remember the source range their text stands for.
private final class AozoraNode {
    enum Kind {
        case text
        case gaiji(AozoraGaiji)
        case kaeriten
        case okurigana
        case lineBreak
        case editorialNote
        case unknownAnnotation
        /// Where an open ［＃X］ range starts; removed when the range closes.
        case rangeStart
        /// A 地付き／字上げ in the middle of a line: the text after it is its own
        /// end-aligned block.
        case endAlignedTail(Int)
        case pageBreak(AozoraPageBreakKind)
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

    /// Splits this verbatim leaf at UTF-16 `offset`; this node keeps the head
    /// and the returned node holds the tail.
    func split(at offset: Int) -> AozoraNode {
        let units = Array(text.utf16)
        let tail = AozoraNode.text(String(decoding: units[offset...], as: UTF16.self),
                                   source: (source.lowerBound + offset)..<source.upperBound, verbatim: true)
        text = String(decoding: units[..<offset], as: UTF16.self)
        source = source.lowerBound..<(source.lowerBound + offset)
        return tail
    }

    var isVerbatimText: Bool {
        if case .text = kind { return isVerbatim }
        return false
    }

    /// Whether the node shows anything. Annotations and marks do not; a ruby
    /// does even with an empty base, since its reading is drawn.
    var isContent: Bool {
        switch kind {
        case .text, .gaiji, .kaeriten, .okurigana, .lineBreak, .container: return true
        case .editorialNote, .unknownAnnotation, .rangeStart, .endAlignedTail, .pageBreak: return false
        }
    }

    var isWhitespaceText: Bool {
        if case .text = kind { return text.allSatisfy(\.isWhitespace) }
        return false
    }

    var isMark: Bool {
        switch kind {
        case .rangeStart, .endAlignedTail, .pageBreak: return true
        default: return false
        }
    }

    /// The UTF-16 length of what the reader sees.
    var visibleLength: Int {
        switch kind {
        case .text, .gaiji, .kaeriten, .okurigana, .lineBreak: return text.utf16.count
        case .editorialNote, .unknownAnnotation, .rangeStart, .endAlignedTail, .pageBreak: return 0
        case .container: return children.reduce(0) { $0 + $1.visibleLength }
        }
    }

    func appendVisibleUnits(to units: inout [UInt16]) {
        switch kind {
        case .text, .gaiji, .kaeriten, .okurigana, .lineBreak: units.append(contentsOf: text.utf16)
        case .editorialNote, .unknownAnnotation, .rangeStart, .endAlignedTail, .pageBreak: break
        case .container: for child in children { child.appendVisibleUnits(to: &units) }
        }
    }

    var visibleText: String {
        var units: [UInt16] = []
        appendVisibleUnits(to: &units)
        return String(decoding: units, as: UTF16.self)
    }

    /// The source the leaves under this node stand for.
    var leafSpan: Range<Int>? {
        guard case .container = kind else { return source }
        let spans = children.compactMap(\.leafSpan)
        guard let lower = spans.map(\.lowerBound).min(), let upper = spans.map(\.upperBound).max() else { return nil }
        return lower..<upper
    }
}

private extension AozoraCommandTable.Style {
    func inline(_ children: [AozoraInline]) -> AozoraInline {
        switch self {
        case .emphasis(let shape, let side): return .emphasis(shape, side: side, children)
        case .sideline(let shape, let side): return .sideline(shape, side: side, children)
        case .bold: return .bold(children)
        case .italic: return .italic(children)
        case .size(let steps): return .size(steps: steps, children)
        case .tateChuYoko: return .tateChuYoko(children)
        case .script(let kind): return .script(kind, children)
        case .warichu: return .warichu(children)
        case .heading(let level, let kind): return .heading(level, kind, children)
        case .boxed: return .boxed(children)
        case .horizontal: return .horizontal(children)
        case .caption: return .caption(children)
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
        case .gaiji(let gaiji): result.append(.gaiji(gaiji))
        case .kaeriten: result.append(.kaeriten(node.text))
        case .okurigana: result.append(.kuntenOkurigana(node.text))
        case .lineBreak: result.append(.lineBreak)
        case .editorialNote: result.append(.editorialNote(node.text))
        case .unknownAnnotation: result.append(.unknownAnnotation(node.text))
        case .rangeStart, .endAlignedTail, .pageBreak: break
        case .container(.ruby(let reading, let side)):
            result.append(.ruby(base: freeze(node.children), reading: reading, side: side))
        case .container(.style(let style)):
            result.append(style.inline(freeze(node.children)))
        case .container(.image(let source, let width, let height)):
            result.append(.image(source: source, width: width, height: height, caption: freeze(node.children)))
        }
    }
    return result
}

/// Reads the lines of one section into blocks. A line is a paragraph; a blank
/// line is an empty paragraph; a line holding only annotations is no block.
/// ［＃ここから…］ styles the lines up to its ［＃ここで…終わり］, and the lines
/// of a ［＃ここから…見出し］ make one heading.
private final class AozoraBlockParser {
    let source: AozoraSource
    let tables: AozoraTables
    private(set) var diagnostics: AozoraDiagnostics

    private var blocks: [AozoraBlock] = []
    /// What the reader sees across every section read so far, in order, with
    /// the source each piece stands for.
    private(set) var segments: [AozoraSourceMap.Segment] = []
    private var hasEmittedBlock = false
    /// The source the "\n" before the next block stands for: the line break
    /// after the previous block, or the annotation that split a line.
    private var pendingSeparator: Range<Int>?
    private var needsSeparatorSource = false
    private var lineStart = 0
    /// ［＃ここから…］ styles, innermost last.
    private var blockStyles: [BlockStyle] = []
    /// The lines of an open ［＃ここから…見出し］.
    private var heading: HeadingBlock?

    // The block being built.
    private var nodes: [AozoraNode] = []
    private var run = RubyRun()
    private var openRanges: [OpenRange] = []
    /// A 地付き／字上げ that came before any text applies to the whole line.
    private var lineEndAlignment: Int?
    /// One-line 字下げ.
    private var lineIndent: Int?
    private var lineHasTokens = false

    /// Where a ruby base would start: the run of one character class before
    /// 《, or everything after ｜. Port of aozora2html's RubyBuffer.
    private struct RubyRun {
        /// Node index, and a UTF-16 offset into that node when it is text.
        var start: (index: Int, offset: Int)?
        var type: AozoraCharType?
        var isProtected = false
        var pendingBar: Range<Int>?
    }

    private struct OpenRange {
        let mark: AozoraNode
        /// The command that opened the range; ［＃X終わり］ closes the innermost
        /// range whose command contains X (aozora2html `exec_inline_end_command`).
        let command: String
        let container: AozoraContainer
        /// 割り注 not already preceded by （ (aozora2html `apply_warichu`).
        var addsParentheses = false
    }

    private enum BlockKind: Hashable {
        case indent, endAlignment, heading, characterLimit, horizontal, boxed, caption, bold, italic, size
    }

    private struct BlockStyle {
        var kinds: Set<BlockKind> = []
        var firstLineIndent: Int?
        var indent: Int?
        var endAlignment: Int?
        var sizeSteps: Int?
        var characterLimit: Int?
    }

    private struct HeadingBlock {
        var level: AozoraHeadingLevel
        var kind: AozoraHeadingKind
        var style: AozoraParagraphStyle
        var nodes: [AozoraNode] = []
        /// Line breaks seen since the last line with content; they join the
        /// heading only when more content follows.
        var pendingBreaks: [Range<Int>] = []
    }

    init(source: AozoraSource, tables: AozoraTables, diagnostics: AozoraDiagnostics) {
        self.source = source
        self.tables = tables
        self.diagnostics = diagnostics
    }

    func parse(lines: Range<Int>) -> [AozoraBlock] {
        blocks = []
        blockStyles = []
        heading = nil
        resetLine()
        let range = source.range(ofLines: lines)
        lineStart = range.lowerBound
        for token in AozoraTokenizer.tokenize(source.units, in: range) {
            if token.kind == .newline {
                finishLine(newline: token.range)
                lineStart = token.range.upperBound
            } else {
                lineHasTokens = true
                handle(token, accents: false)
            }
        }
        // A section's last line has no line break when it ends the file; the
        // empty line after a final line break is not a line of the book.
        if lineHasTokens { finishLine(newline: nil) }
        if !blockStyles.isEmpty {
            diagnostics.record(.unclosedRange, count: blockStyles.count)
            blockStyles = []
        }
        finishHeading()
        return blocks
    }

    // MARK: Lines and blocks

    private func resetLine() {
        nodes = []
        run = RubyRun()
        openRanges = []
        lineEndAlignment = nil
        lineIndent = nil
        lineHasTokens = false
    }

    private func finishLine(newline: Range<Int>?) {
        restorePendingBar()
        closeOpenRanges()
        if heading != nil {
            absorbLineIntoHeading(newline: newline)
        } else {
            if !lineHasTokens {
                emit(.paragraph([], paragraphStyle()), showing: [], at: lineStart)
            } else {
                emitLine()
            }
            if needsSeparatorSource, let newline {
                pendingSeparator = newline
                needsSeparatorSource = false
            }
        }
        resetLine()
    }

    /// Adds a block, and to the displayed text its line break and its leaves.
    /// A block that shows nothing still takes its place between two breaks.
    private func emit(_ block: AozoraBlock, showing shown: [AozoraNode], at position: Int) {
        var leaves: [AozoraSourceMap.Segment] = []
        for node in shown { collectLeaves(node, into: &leaves) }
        if hasEmittedBlock {
            let start = leaves.first?.source.lowerBound ?? position
            segments.append(AozoraSourceMap.Segment(text: "\n", source: pendingSeparator ?? start..<start))
        }
        segments.append(contentsOf: leaves)
        blocks.append(block)
        hasEmittedBlock = true
        pendingSeparator = nil
        needsSeparatorSource = true
    }

    private func collectLeaves(_ node: AozoraNode, into leaves: inout [AozoraSourceMap.Segment]) {
        switch node.kind {
        case .text, .gaiji, .kaeriten, .okurigana, .lineBreak:
            leaves.append(AozoraSourceMap.Segment(text: node.text, source: node.source))
        case .container:
            for child in node.children { collectLeaves(child, into: &leaves) }
        case .editorialNote, .unknownAnnotation, .rangeStart, .endAlignedTail, .pageBreak:
            break
        }
    }

    /// The line's blocks: split at a mid-line 地付き when text follows it, and
    /// around page breaks.
    private func emitLine() {
        var segment: [AozoraNode] = []
        var endAlignment = lineEndAlignment
        func flush() -> Bool {
            defer { segment = [] }
            guard segment.contains(where: \.isContent) else { return false }
            emitBlock(segment, endAlignment: endAlignment)
            return true
        }
        for (index, node) in nodes.enumerated() {
            switch node.kind {
            case .endAlignedTail(let offset):
                let textFollows = nodes[(index + 1)...].contains { $0.isContent && !$0.isWhitespaceText }
                if textFollows, segment.contains(where: \.isContent), flush() {
                    // The line break between the two blocks stands for the annotation.
                    pendingSeparator = node.source
                    needsSeparatorSource = false
                }
                // With nothing after it, the annotation was written after the
                // line it aligns, e.g. （明治四十四年一月）［＃地付き］.
                endAlignment = offset
            case .pageBreak(let kind):
                if flush() {
                    pendingSeparator = node.source
                    needsSeparatorSource = false
                }
                emit(.pageBreak(kind), showing: [], at: node.source.lowerBound)
                endAlignment = nil
            default:
                segment.append(node)
            }
        }
        _ = flush()
    }

    private func emitBlock(_ nodes: [AozoraNode], endAlignment: Int?) {
        var style = paragraphStyle()
        if let endAlignment { style.endAlignment = endAlignment }
        let content = nodes.filter(\.isContent)
        let isLayoutSpace = { (node: AozoraNode) in node.isWhitespaceText }
        // A line holding one figure is a figure block; one heading, a heading block.
        if let image = content.first(where: { if case .container(.image) = $0.kind { return true }; return false }),
           content.allSatisfy({ $0 === image || isLayoutSpace($0) }),
           case .container(.image(let file, let width, let height)) = image.kind {
            emit(.image(source: file, width: width, height: height, caption: freeze(image.children)),
                 showing: [image], at: image.source.lowerBound)
            return
        }
        if let headingNode = content.first(where: { if case .container(.style(.heading)) = $0.kind { return true }; return false }),
           content.allSatisfy({ $0 === headingNode || isLayoutSpace($0) }),
           case .container(.style(.heading(let level, let kind))) = headingNode.kind {
            let flattened = nodes.flatMap { $0 === headingNode ? $0.children : [$0] }
            emit(.heading(level, kind, blockInlineStyles(freeze(flattened)), style), showing: nodes,
                 at: nodes.first?.source.lowerBound ?? lineStart)
            return
        }
        emit(.paragraph(blockInlineStyles(freeze(nodes)), style), showing: nodes,
             at: nodes.first?.source.lowerBound ?? lineStart)
    }

    private func paragraphStyle() -> AozoraParagraphStyle {
        var style = AozoraParagraphStyle()
        for entry in blockStyles {
            if let first = entry.firstLineIndent {
                style.firstLineIndent = first
                style.indent = entry.indent ?? first
            }
            if let end = entry.endAlignment { style.endAlignment = end }
            if let size = entry.sizeSteps { style.sizeSteps = size }
            if let limit = entry.characterLimit { style.characterLimit = limit }
            if entry.kinds.contains(.boxed) { style.isBoxed = true }
            if entry.kinds.contains(.horizontal) { style.isHorizontal = true }
            if entry.kinds.contains(.caption) { style.isCaption = true }
        }
        if let lineIndent {
            style.firstLineIndent = lineIndent
            style.indent = lineIndent
        }
        if let lineEndAlignment { style.endAlignment = lineEndAlignment }
        return style
    }

    /// ［＃ここから太字］ and ［＃ここから斜体］ style the text of every line.
    private func blockInlineStyles(_ inlines: [AozoraInline]) -> [AozoraInline] {
        var result = inlines
        if blockStyles.contains(where: { $0.kinds.contains(.bold) }) { result = [.bold(result)] }
        if blockStyles.contains(where: { $0.kinds.contains(.italic) }) { result = [.italic(result)] }
        return result
    }

    private func absorbLineIntoHeading(newline: Range<Int>?) {
        guard var block = heading else { return }
        if !lineHasTokens {
            if !block.nodes.isEmpty, let newline { block.pendingBreaks.append(newline) }
        } else if nodes.contains(where: \.isContent) {
            appendLineBreaks(to: &block)
            block.nodes.append(contentsOf: nodes)
            block.pendingBreaks = newline.map { [$0] } ?? []
        }
        heading = block
    }

    private func appendLineBreaks(to block: inout HeadingBlock) {
        guard !block.nodes.isEmpty else { return }
        for range in block.pendingBreaks {
            block.nodes.append(AozoraNode(kind: .lineBreak, text: "\n", source: range))
        }
        block.pendingBreaks = []
    }

    /// Ends an open ［＃ここから…見出し］: its lines, and what the closing line
    /// holds before ［＃ここで…見出し終わり］, become one heading.
    private func finishHeading() {
        guard var block = heading else { return }
        heading = nil
        restorePendingBar()
        closeOpenRanges()
        if nodes.contains(where: \.isContent) {
            appendLineBreaks(to: &block)
            block.nodes.append(contentsOf: nodes)
            nodes = []
            run = RubyRun()
        }
        guard block.nodes.contains(where: \.isContent) else { return }
        emit(.heading(block.level, block.kind, blockInlineStyles(freeze(block.nodes)), block.style),
             showing: block.nodes, at: block.nodes.first?.source.lowerBound ?? lineStart)
        // The break after the heading is the one after its last line, not the
        // one after ［＃ここで…見出し終わり］.
        if let next = block.pendingBreaks.first {
            pendingSeparator = next
            needsSeparatorSource = false
        }
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
            handleAnnotation(token)
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
        if let last = nodes.last, last.isVerbatimText, last.source.upperBound == range.lowerBound {
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

    /// Annotations and marks take no part in ruby runs.
    private func appendNote(_ kind: AozoraNode.Kind, _ command: String, source range: Range<Int>) {
        nodes.append(AozoraNode(kind: kind, text: command, source: range))
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

    // MARK: Annotations

    private func handleAnnotation(_ token: AozoraToken) {
        let command = source.string(token.content)
        if command.hasPrefix("ここから") || command.contains("折り返して") {
            if command == "ここから割り注" {
                openRange(command, container: .style(.warichu), token: token)
            } else if !startBlock(command, token: token) {
                appendUnrecognized(command, token: token)
            }
            return
        }
        if command.hasPrefix("ここで") {
            if command.contains("割り注") {
                closeRange(named: "割り注", token: token)
            } else if !endBlock(String(command.dropFirst(3))) {
                diagnostics.record(.unopenedRangeEnd)
            }
            return
        }
        if command.hasPrefix("本文") {
            // 本文終わり and other structure markers.
            appendNote(.editorialNote, command, source: token.range)
            return
        }
        if command.hasSuffix("終わり") {
            handleRangeEnd(String(command.dropLast(3)), token: token)
            return
        }
        // A figure's caption is quoted (［＃「…」のキャプション付きの図（fig….png）入る］),
        // so figures come before forward references, as in aozora2html.
        if let image = image(command, token: token) {
            appendLeaf(image, type: .other)
            return
        }
        if command.hasPrefix("「"), handleForwardReference(token, command: command) {
            return
        }
        if AozoraCommandTable.isEditorial(command) {
            appendNote(.editorialNote, command, source: token.range)
            return
        }
        if let kind = AozoraCommandTable.pageBreak(command) {
            nodes.append(AozoraNode(kind: .pageBreak(kind), source: token.range))
            return
        }
        if command == "改行" {
            appendLeaf(AozoraNode(kind: .lineBreak, text: "\n", source: token.range), type: .other)
            return
        }
        if AozoraCommandTable.isKaeriten(command) {
            appendLeaf(AozoraNode(kind: .kaeriten, text: command, source: token.range), type: .other)
            return
        }
        if AozoraCommandTable.isOkurigana(command) {
            // What the parentheses hold can itself be marked up:
            // ［＃（※［＃二の字点、1-2-22］）］, ［＃（之天［＃「之天」に白丸傍点］）］.
            let inner = (token.content.lowerBound + 1)..<(token.content.upperBound - 1)
            appendLeaf(AozoraNode(kind: .okurigana, text: visibleText(inner), source: token.range), type: .other)
            return
        }
        if command.contains("字下げ"), let width = AozoraCommandTable.count(before: "字下げ", in: command) {
            // aozora2html applies a one-line 字下げ to the whole line.
            lineIndent = width
            return
        }
        if let offset = endAlignment(command) {
            if nodes.contains(where: \.isContent) {
                nodes.append(AozoraNode(kind: .endAlignedTail(offset), source: token.range))
            } else {
                lineEndAlignment = offset
            }
            return
        }
        if ["注記付き", "左に注記付き", "ルビ付き", "左にルビ付き"].contains(command) {
            openRange(command, container: .ruby(reading: "", side: command.hasPrefix("左") ? .left : .right),
                      token: token)
            return
        }
        if let style = AozoraCommandTable.style(command) {
            openRange(command, container: .style(style), token: token)
            return
        }
        appendUnrecognized(command, token: token)
    }

    private func appendUnrecognized(_ command: String, token: AozoraToken) {
        if AozoraCommandTable.isEditorial(command) {
            appendNote(.editorialNote, command, source: token.range)
        } else {
            diagnostics.record(.unknownAnnotation(AozoraDiagnostics.shape(of: command)))
            appendNote(.unknownAnnotation, command, source: token.range)
        }
    }

    /// 地付き (0), 地からN字上げ, 地付き、地よりN字あき … the distance from the end edge.
    private func endAlignment(_ command: String) -> Int? {
        guard command.contains("地付き") || command.contains("字上げ") || command.contains("地寄せ") else { return nil }
        return AozoraCommandTable.count(before: "字上げ", in: command)
            ?? AozoraCommandTable.count(before: "字あき", in: command)
            ?? 0
    }

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^(.*)（([^（）、]+\.(?:png|jpe?g|gif))(?:、横(\d*)×縦(\d*))?）入る$"#,
        options: [.caseInsensitive])
    private static let captionPattern = try! NSRegularExpression(pattern: "^「(.*)」のキャプション付きの")

    /// ［＃挿絵１（fig226_01.png、横570×縦829）入る］ (aozora2html PAT_IMAGE). A
    /// 「…」のキャプション付きの図 carries its caption, which the reader shows.
    private func image(_ command: String, token: AozoraToken) -> AozoraNode? {
        let range = NSRange(command.startIndex..., in: command)
        guard let match = Self.imagePattern.firstMatch(in: command, range: range),
              let altRange = Range(match.range(at: 1), in: command),
              let fileRange = Range(match.range(at: 2), in: command)
        else { return nil }
        func number(_ group: Int) -> Int? {
            Range(match.range(at: group), in: command).flatMap { Int(command[$0]) }
        }
        var caption: [AozoraNode] = []
        let alt = String(command[altRange])
        if let captionMatch = Self.captionPattern.firstMatch(in: alt, range: NSRange(alt.startIndex..., in: alt)) {
            // NSRange offsets are UTF-16, so they map straight onto the source.
            let start = token.content.lowerBound + captionMatch.range(at: 1).location
            let text = visibleText(start..<(start + captionMatch.range(at: 1).length))
            if !text.isEmpty {
                caption = [.text(text, source: token.range, verbatim: false)]
            }
        }
        return AozoraNode(kind: .container(.image(source: String(command[fileRange]), width: number(3), height: number(4))),
                          source: token.range, children: caption)
    }

    // MARK: Ranges

    private func openRange(_ command: String, container: AozoraContainer, token: AozoraToken) {
        let mark = AozoraNode(kind: .rangeStart, source: token.range)
        var range = OpenRange(mark: mark, command: command, container: container)
        if case .style(.warichu) = container {
            var visible: [UInt16] = []
            for node in nodes { node.appendVisibleUnits(to: &visible) }
            range.addsParentheses = visible.last != 0xFF08                        // （
        }
        nodes.append(mark)
        openRanges.append(range)
    }

    /// ［＃X終わり］.
    private func handleRangeEnd(_ name: String, token: AozoraToken) {
        if name.contains("字下げ") {
            if !endBlock(name) { diagnostics.record(.unopenedRangeEnd) }
            return
        }
        if name.hasSuffix("地付き") || name.hasSuffix("字上げ") {
            if !endBlock(name) { diagnostics.record(.unopenedRangeEnd) }
            return
        }
        if name.hasSuffix("注記付き") || name.hasSuffix("ルビ付き"),
           let index = openRanges.lastIndex(where: { $0.command.hasSuffix("注記付き") || $0.command.hasSuffix("ルビ付き") }) {
            // ［＃注記付き］X［＃「Y」の注記付き終わり］ and
            // ［＃左にルビ付き］X［＃左に「Y」のルビ付き終わり］: Y is X's ruby.
            var reading = ""
            if let open = name.firstIndex(of: "「"), let close = name.lastIndex(of: "」"), open < close {
                let offset = name[..<name.index(after: open)].utf16.count
                let length = name[name.index(after: open)..<close].utf16.count
                let start = token.content.lowerBound + offset
                reading = visibleText(start..<(start + length))
            }
            let side: AozoraSide = name.hasPrefix("左") || openRanges[index].command.hasPrefix("左") ? .left : .right
            closeRange(at: index, container: .ruby(reading: reading, side: side), closing: token)
            return
        }
        closeRange(named: name, token: token)
    }

    private func closeRange(named name: String, token: AozoraToken) {
        guard let index = openRanges.lastIndex(where: { $0.command.contains(name) }) else {
            diagnostics.record(.unopenedRangeEnd)
            return
        }
        closeRange(at: index, container: openRanges[index].container, closing: token)
    }

    /// Wraps everything after the range's mark. Ranges opened inside it and
    /// still open are closed first, and diagnosed. A 割り注 is set in
    /// parentheses unless the text already has them; the parentheses stand
    /// for the two annotations in the source.
    private func closeRange(at index: Int, container: AozoraContainer, closing: AozoraToken? = nil) {
        while openRanges.count > index + 1 {
            diagnostics.record(.unclosedRange)
            let inner = openRanges.count - 1
            closeRange(at: inner, container: openRanges[inner].container)
        }
        let range = openRanges.remove(at: index)
        guard let markIndex = nodes.firstIndex(where: { $0 === range.mark }) else { return }
        var content = Array(nodes[(markIndex + 1)...])
        if case .style(.warichu) = container {
            if range.addsParentheses {
                content.insert(.text("（", source: range.mark.source, verbatim: false), at: 0)
            }
            if let closing, closing.range.upperBound >= source.units.count
                || source.units[closing.range.upperBound] != 0xFF09 {           // ）
                content.append(.text("）", source: closing.range, verbatim: false))
            }
        }
        nodes.replaceSubrange(markIndex..., with: [
            AozoraNode(kind: .container(container), source: range.mark.source, children: content),
        ])
        if let start = run.start, start.index > markIndex {
            run.start = (markIndex, 0)
            run.type = .other
        }
    }

    /// A range left open at the end of its line closes there.
    private func closeOpenRanges() {
        while let last = openRanges.indices.last {
            diagnostics.record(.unclosedRange)
            closeRange(at: last, container: openRanges[last].container)
        }
    }

    // MARK: Block styles

    /// ［＃ここから…］, and ［＃…折り返して…字下げ］ which also styles the
    /// following lines (aozora2html `apply_burasage`).
    private func startBlock(_ command: String, token: AozoraToken) -> Bool {
        let body = command.hasPrefix("ここから") ? String(command.dropFirst(4)) : command
        var style = BlockStyle()
        if let hanging = body.range(of: "折り返して") {
            let after = String(body[hanging.upperBound...])
            let before = String(body[..<hanging.lowerBound])
            guard let rest = AozoraCommandTable.count(before: "字下げ", in: after) else { return false }
            style.firstLineIndent = before.contains("天付き") ? 0 : (AozoraCommandTable.count(before: "字下げ", in: before) ?? 0)
            style.indent = rest
            style.kinds.insert(.indent)
        } else if let width = AozoraCommandTable.count(before: "字下げ", in: body) {
            style.firstLineIndent = width
            style.indent = width
            style.kinds.insert(.indent)
        }
        if body.hasSuffix("地付き") || body.hasSuffix("字上げ") {
            style.endAlignment = AozoraCommandTable.count(before: "字上げ", in: body) ?? 0
            style.kinds.insert(.endAlignment)
        }
        let headingLevel = AozoraCommandTable.headingLevel(in: body)
        if headingLevel != nil { style.kinds.insert(.heading) }
        if let limit = AozoraCommandTable.count(before: "字詰め", in: body) {
            style.characterLimit = limit
            style.kinds.insert(.characterLimit)
        }
        if body.contains("横組み") { style.kinds.insert(.horizontal) }
        if body.contains("罫囲み") { style.kinds.insert(.boxed) }
        if body.contains("キャプション") { style.kinds.insert(.caption) }
        if body.contains("太字") { style.kinds.insert(.bold) }
        if body.contains("斜体") { style.kinds.insert(.italic) }
        if let steps = AozoraCommandTable.sizeSteps(body) {
            style.sizeSteps = steps
            style.kinds.insert(.size)
        }
        guard !style.kinds.isEmpty else { return false }
        // aozora2html `implicit_close`: a new 字下げ or 地付き block replaces the
        // innermost open one of the same kind instead of nesting in it, also
        // when either carries more (［＃ここから２字下げ、２０字詰め］ repeated
        // without its 終わり).
        if let top = blockStyles.last,
           !top.kinds.isDisjoint(with: style.kinds.intersection([.indent, .endAlignment])) {
            blockStyles.removeLast()
        }
        blockStyles.append(style)
        if let headingLevel {
            finishHeading()
            if nodes.contains(where: \.isContent) {
                // Text before ［＃ここから…見出し］ on the same line is its own block.
                restorePendingBar()
                closeOpenRanges()
                emitLine()
                nodes = []
                run = RubyRun()
            }
            heading = HeadingBlock(level: headingLevel, kind: AozoraCommandTable.headingKind(in: body),
                                   style: paragraphStyle())
        }
        return true
    }

    /// ［＃ここで…終わり］: closes the innermost block of that kind
    /// (aozora2html `detect_command_mode`).
    private func endBlock(_ body: String) -> Bool {
        let kind: BlockKind?
        if body.hasSuffix("地付き終わり") || body.hasSuffix("字上げ終わり") || body.hasSuffix("地付き")
            || body.hasSuffix("字上げ") {
            kind = .endAlignment
        } else {
            let words: [(String, BlockKind)] = [
                ("字下げ", .indent), ("地付き", .endAlignment), ("見出し", .heading), ("字詰め", .characterLimit),
                ("横組み", .horizontal), ("罫囲み", .boxed), ("キャプション", .caption), ("太字", .bold),
                ("斜体", .italic), ("大きな文字", .size), ("小さな文字", .size),
            ]
            kind = words.first { body.contains($0.0) }?.1
        }
        guard let kind, let index = blockStyles.lastIndex(where: { $0.kinds.contains(kind) }) else { return false }
        let removed = blockStyles.remove(at: index)
        if removed.kinds.contains(.heading) { finishHeading() }
        return true
    }

    // MARK: Forward references

    private struct ForwardReference {
        /// The text the annotation names, between its outer 「」.
        var target: Range<Int>
        /// What to do with it: 傍点, は太字, に「…」の注記 …
        var spec: Range<Int>
    }

    /// 「X」に…, 「X」は…, 「X」の…: X may hold 「」 pairs and annotations
    /// (aozora2html PAT_FRONTREF).
    private func forwardReference(in content: Range<Int>) -> ForwardReference? {
        let units = source.units
        var depth = 0
        var index = content.lowerBound
        while index < content.upperBound {
            let unit = units[index]
            if unit == 0x300C {                                          // 「
                depth += 1
            } else if unit == 0x300D {                                   // 」
                depth -= 1
                if depth == 0 {
                    guard index + 1 < content.upperBound,
                          [0x306B, 0x306F, 0x306E].contains(units[index + 1])   // に は の
                    else { return nil }
                    return ForwardReference(target: (content.lowerBound + 1)..<index,
                                            spec: (index + 2)..<content.upperBound)
                }
            } else if unit == AozoraTokenizer.bracketOpen, index + 1 < content.upperBound,
                      units[index + 1] == AozoraTokenizer.sharp,
                      let end = AozoraTokenizer.annotationEnd(in: units, from: index, limit: content.upperBound) {
                index = end
                continue
            }
            index += 1
        }
        return nil
    }

    private static let leftRuby = try! NSRegularExpression(pattern: "^(?:左|下)に「(.*)」の(?:ルビ|注記)$")
    private static let rightRuby = try! NSRegularExpression(pattern: "^(?:右に)?「(.*)」の(?:ルビ|注記)$")
    private static let sideMark = try! NSRegularExpression(pattern: "^「(.)」の傍記$")

    private enum ForwardAction {
        case style(AozoraCommandTable.Style)
        case kaeriten
        case okurigana
    }

    /// Returns false when the command is not a forward reference at all.
    private func handleForwardReference(_ token: AozoraToken, command: String) -> Bool {
        guard let reference = forwardReference(in: token.content) else { return false }
        let target = visibleText(reference.target)
        let spec = source.string(reference.spec)
        let specRange = NSRange(spec.startIndex..., in: spec)

        // ［＃「１」はローマ数字、1-13-21］: the code names the character the
        // target stands for (aozora2html `exec_style` → `kuten2png`).
        if !spec.contains("※［＃"), !spec.contains("非0213外字") {
            let (gaiji, unmapped) = AozoraDocumentParser.gaiji(spec, tables: tables)
            if gaiji.code != nil, gaiji.resolved != nil {
                if !wrapTarget(target, make: { replaced in
                    AozoraNode(kind: .gaiji(gaiji), text: gaiji.displayedText,
                               source: Self.span(of: replaced) ?? token.range)
                }) {
                    diagnostics.record(.missingForwardReference)
                }
                return true
            }
            if unmapped { diagnostics.record(.unmappedGaijiCode) }
        }

        // Ruby-like notes: に「Y」の注記, の左に「Y」のルビ, に「・」の傍記.
        for (pattern, side) in [(Self.leftRuby, AozoraSide.left), (Self.rightRuby, .right)] {
            if let match = pattern.firstMatch(in: spec, range: specRange) {
                let start = reference.spec.lowerBound + match.range(at: 1).location
                let reading = visibleText(start..<(start + match.range(at: 1).length))
                if !wrapTarget(target, make: { AozoraNode(kind: .container(.ruby(reading: reading, side: side)),
                                                          source: token.range, children: $0) }) {
                    diagnostics.record(.missingForwardReference)
                }
                return true
            }
        }
        if let match = Self.sideMark.firstMatch(in: spec, range: specRange),
           let markRange = Range(match.range(at: 1), in: spec) {
            let reading = Array(repeating: String(spec[markRange]), count: target.count).joined(separator: "\u{00A0}")
            if !wrapTarget(target, make: { AozoraNode(kind: .container(.ruby(reading: reading, side: .right)),
                                                      source: token.range, children: $0) }) {
                diagnostics.record(.missingForwardReference)
            }
            return true
        }

        // Styles, possibly several: 「…」は縦中横、行右小書き.
        var actions: [ForwardAction] = []
        for part in spec.components(separatedBy: "、") {
            if let style = AozoraCommandTable.style(part) {
                actions.append(.style(style))
            } else if part == "返り点" {
                actions.append(.kaeriten)
            } else if part == "訓点送り仮名" {
                actions.append(.okurigana)
            } else {
                actions = []
                break
            }
        }
        if !actions.isEmpty {
            for action in actions {
                let applied = wrapTarget(target) { wrapped in
                    switch action {
                    case .style(let style):
                        return AozoraNode(kind: .container(.style(style)), source: token.range, children: wrapped)
                    case .kaeriten:
                        return AozoraNode(kind: .kaeriten, text: wrapped.map(\.visibleText).joined(),
                                          source: Self.span(of: wrapped) ?? token.range)
                    case .okurigana:
                        return AozoraNode(kind: .okurigana, text: wrapped.map(\.visibleText).joined(),
                                          source: Self.span(of: wrapped) ?? token.range)
                    }
                }
                if !applied {
                    diagnostics.record(.missingForwardReference)
                    break
                }
            }
            return true
        }
        if AozoraCommandTable.isEditorial(spec) {
            appendNote(.editorialNote, command, source: token.range)
        } else {
            diagnostics.record(.unknownAnnotation(AozoraDiagnostics.shape(of: command)))
            appendNote(.unknownAnnotation, command, source: token.range)
        }
        return true
    }

    private static func span(of nodes: [AozoraNode]) -> Range<Int>? {
        let spans = nodes.compactMap(\.leafSpan)
        guard let lower = spans.map(\.lowerBound).min(), let upper = spans.map(\.upperBound).max() else { return nil }
        return lower..<upper
    }

    /// Wraps the nearest preceding occurrence of `target` in this block
    /// (matched on what the reader sees, so ruby readings are skipped). An
    /// occurrence that would cut through a ruby, a gaiji or an open range is
    /// passed over for an earlier one.
    private func wrapTarget(_ target: String, make: ([AozoraNode]) -> AozoraNode) -> Bool {
        let needle = Array(target.utf16)
        guard !needle.isEmpty else { return false }
        var haystack: [UInt16] = []
        for node in nodes { node.appendVisibleUnits(to: &haystack) }
        var start = haystack.count - needle.count
        while start >= 0 {
            if haystack[start..<(start + needle.count)].elementsEqual(needle),
               wrap(start..<(start + needle.count), in: &nodes, topLevel: true, make: make) {
                return true
            }
            start -= 1
        }
        return false
    }

    /// Wraps the visible range `range` of `list` with `make`. Text leaves are
    /// split at the edges; a range strictly inside one container is wrapped
    /// inside it. Fails, changing nothing, when an edge falls inside a node
    /// that cannot be split or the range would swallow a range mark.
    private func wrap(_ range: Range<Int>, in list: inout [AozoraNode], topLevel: Bool,
                      make: ([AozoraNode]) -> AozoraNode) -> Bool {
        var starts: [Int] = []
        var position = 0
        for node in list {
            starts.append(position)
            position += node.visibleLength
        }
        func end(_ index: Int) -> Int { starts[index] + list[index].visibleLength }
        guard let first = list.indices.first(where: { list[$0].visibleLength > 0 && end($0) > range.lowerBound }),
              let last = list.indices.last(where: { list[$0].visibleLength > 0 && starts[$0] < range.upperBound })
        else { return false }

        if first == last, case .container = list[first].kind,
           starts[first] != range.lowerBound || end(first) != range.upperBound {
            let shifted = (range.lowerBound - starts[first])..<(range.upperBound - starts[first])
            return wrap(shifted, in: &list[first].children, topLevel: false, make: make)
        }
        guard !list[first...last].contains(where: \.isMark) else { return false }
        let cutsHead = range.lowerBound > starts[first]
        let cutsTail = range.upperBound < end(last)
        guard !cutsHead || list[first].isVerbatimText, !cutsTail || list[last].isVerbatimText else { return false }

        var lower = first
        var upper = last
        if cutsHead {
            let offset = range.lowerBound - starts[first]
            list.insert(list[first].split(at: offset), at: first + 1)
            if topLevel { shiftRun(afterSplitAt: first, offset: offset) }
            lower += 1
            upper += 1
        }
        if cutsTail {
            let lastStart = upper == lower && cutsHead ? range.lowerBound : starts[last]
            let offset = range.upperBound - lastStart
            list.insert(list[upper].split(at: offset), at: upper + 1)
            if topLevel { shiftRun(afterSplitAt: upper, offset: offset) }
        }
        let wrapper = make(Array(list[lower...upper]))
        list.replaceSubrange(lower...upper, with: [wrapper])
        if topLevel, let start = run.start {
            if (lower...upper).contains(start.index) {
                run.start = (lower, 0)
            } else if start.index > upper {
                run.start = (start.index - (upper - lower), start.offset)
            }
        }
        return true
    }

    private func shiftRun(afterSplitAt index: Int, offset: Int) {
        guard let start = run.start else { return }
        if start.index == index, start.offset >= offset {
            run.start = (index + 1, start.offset - offset)
        } else if start.index > index {
            run.start = (start.index + 1, start.offset)
        }
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
