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
    var diagnostics: AozoraDiagnostics
}

/// The only place that reads Aozora Bunko notation.
enum AozoraDocumentParser {
    static func parse(_ text: String, tables: AozoraTables = .shared) -> AozoraDocument {
        let source = AozoraSource(text)
        var diagnostics = AozoraDiagnostics()
        let structure = structure(of: source, diagnostics: &diagnostics)
        let header = AozoraHeaderParser.parse(
            headerLines: structure.header.map { AozoraHeaderParser.strippingRuby(source.line($0)) })
        let bibliography = bibliography(of: structure.colophon.map(source.line))
        return AozoraDocument(structure: structure, header: header, bibliography: bibliography,
                              diagnostics: diagnostics)
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
}
