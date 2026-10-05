import Foundation

/// Bibliographic lines at the top of an Aozora Bunko file: everything before
/// the first blank line.
struct AozoraHeader: Equatable, Sendable {
    var title: String
    var originalTitle: String?
    var subtitle: String?
    var originalSubtitle: String?
    var author: String?
    var translator: String?
    var editor: String?
    /// 編訳: one person both edited and translated.
    var henyaku: String?
}

/// Port of aozora2html `lib/aozora2html/header.rb` (`build_header_info`,
/// `header_element_type`, `process_person`), CC0.
enum AozoraHeaderParser {
    static func parse(headerLines: [String]) -> AozoraHeader? {
        let lines = headerLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let title = lines.first, !title.isEmpty else { return nil }
        var header = AozoraHeader(title: title)
        switch lines.count {
        case 2:
            processPerson(lines[1], into: &header)
        case 3:
            if elementType(lines[1]) == .original {
                header.originalTitle = lines[1]
                processPerson(lines[2], into: &header)
            } else if processPerson(lines[2], into: &header) == .author {
                header.subtitle = lines[1]
            } else {
                header.author = lines[1]
            }
        case 4:
            if elementType(lines[1]) == .original {
                header.originalTitle = lines[1]
            } else {
                header.subtitle = lines[1]
            }
            if processPerson(lines[3], into: &header) == .author {
                header.subtitle = lines[2]
            } else {
                header.author = lines[2]
            }
        case 5:
            header.originalTitle = lines[1]
            header.subtitle = lines[2]
            header.author = lines[3]
            // aozora2html stops here ("parser encounted author twice") when the
            // last line is not a credit. Keep the first author instead.
            if elementType(lines[4]).map(isCredit) == true {
                processPerson(lines[4], into: &header)
            }
        case 6:
            header.originalTitle = lines[1]
            header.subtitle = lines[2]
            header.originalSubtitle = lines[3]
            header.author = lines[4]
            if elementType(lines[5]).map(isCredit) == true {
                processPerson(lines[5], into: &header)
            }
        default:
            // One line, or more than six: aozora2html keeps only the title.
            break
        }
        return header
    }

    /// The header lines of a document: everything before the first blank line,
    /// with ruby removed the way aozora2html `parse_header` does (`｜` and
    /// `《…》` are dropped).
    static func headerLines(of text: String) -> [String] {
        var lines: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard !AozoraDocumentDetector.isBlank(line) else { break }
            lines.append(strippingRuby(String(line)))
        }
        return lines
    }

    enum ElementType: Equatable {
        case original, editor, henyaku, translator
    }

    enum PersonRole: Equatable {
        case author, editor, henyaku, translator
    }

    static func elementType(_ line: String) -> ElementType? {
        if line.unicodeScalars.allSatisfy({ $0.isASCII || originalScalars.contains($0) }) {
            return .original
        }
        if line.hasSuffix("校訂") || line.hasSuffix("編") || line.hasSuffix("編集") { return .editor }
        if line.hasSuffix("編訳") { return .henyaku }
        if line.hasSuffix("訳") { return .translator }
        return nil
    }

    @discardableResult
    private static func processPerson(_ line: String, into header: inout AozoraHeader) -> PersonRole {
        switch elementType(line) {
        case .editor:
            header.editor = line
            return .editor
        case .translator:
            header.translator = line
            return .translator
        case .henyaku:
            header.henyaku = line
            return .henyaku
        case .original, nil:
            header.author = line
            return .author
        }
    }

    private static func isCredit(_ type: ElementType) -> Bool {
        type != .original
    }

    static func strippingRuby(_ line: String) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "｜" {
                index = line.index(after: index)
                continue
            }
            if character == "《", let closing = line[index...].firstIndex(of: "》") {
                index = line.index(after: closing)
                continue
            }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

    /// Characters aozora2html treats as a line written in the original
    /// language: Shift_JIS 8140–8258 (JIS rows 1–2 and the digits of row 3)
    /// and 839F–8491 (Greek and Cyrillic, rows 6–7), besides ASCII. Built from
    /// both the JIS and the Microsoft mapping, since files decode as CP932.
    private static let originalScalars: Set<Unicode.Scalar> = {
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        var scalars = Set<Unicode.Scalar>()
        for code in Array(0x8140...0x8258) + Array(0x839F...0x8491) {
            let trail = code & 0xFF
            guard trail >= 0x40, trail != 0x7F, trail <= 0xFC else { continue }
            let bytes = Data([UInt8(code >> 8), UInt8(trail)])
            for encoding in [String.Encoding.shiftJIS, cp932] {
                if let decoded = String(data: bytes, encoding: encoding),
                   decoded.unicodeScalars.count == 1 {
                    scalars.formUnion(decoded.unicodeScalars)
                }
            }
        }
        return scalars
    }()
}
