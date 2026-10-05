import Foundation

/// Decides whether a decoded TXT is an Aozora Bunko document. Bare 《》 is not
/// enough: Chinese text uses it as book-title punctuation.
enum AozoraDocumentDetector {
    /// Characters read from each end. On the 2023-03 corpus (17,158 works)
    /// notation blocks end within 30 lines of the top and the 底本 colophon is
    /// the last few hundred characters, so a large non-Aozora TXT is never
    /// scanned whole.
    static let prefixCharacterLimit = 64 * 1024
    static let suffixCharacterLimit = 16 * 1024

    static let notationTitle = "テキスト中に現れる記号について"

    /// A titled notation block (【テキスト中に現れる記号について】 between two
    /// hyphen lines), or a 底本： colophon plus ［＃ or ｜…《…》 in the text.
    /// Measured on the 2023-03 corpus: 93.4% of works; the misses carry no markup.
    static func isAozoraDocument(_ text: String) -> Bool {
        let head: Substring
        let tail: Substring?
        if let cut = text.index(text.startIndex,
                                offsetBy: prefixCharacterLimit + suffixCharacterLimit,
                                limitedBy: text.endIndex),
           cut < text.endIndex {
            head = text.prefix(prefixCharacterLimit)
            tail = text.suffix(suffixCharacterLimit)
        } else {
            head = text[...]
            tail = nil
        }
        let headLines = lines(of: head)
        if hasTitledNotationBlock(headLines) { return true }
        let colophon = tail.map(lines(of:)) ?? headLines
        guard colophon.contains(where: isColophonStart) else { return false }
        return hasAozoraMarkup(head) || tail.map(hasAozoraMarkup) == true
    }

    /// A line of ten or more ASCII hyphens, which aozora2html and the census
    /// both use to fence the notation block.
    static func isHyphenLine(_ line: Substring) -> Bool {
        var hyphens = 0
        var trailingSpace = false
        for character in line {
            if character == "-", !trailingSpace {
                hyphens += 1
            } else if character.isWhitespace {
                trailingSpace = true
            } else {
                return false
            }
        }
        return hyphens >= 10
    }

    /// `底本：` at the very start of a line opens the colophon (aozora2html's
    /// TEIHON_MARK; the census also accepts a half-width colon).
    static func isColophonStart(_ line: Substring) -> Bool {
        line.hasPrefix("底本：") || line.hasPrefix("底本:")
    }

    static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func hasTitledNotationBlock(_ lines: [Substring]) -> Bool {
        for (index, line) in lines.enumerated() where isHyphenLine(line) {
            guard let titleIndex = lines[(index + 1)...].firstIndex(where: { !isBlank($0) }),
                  lines[titleIndex].contains(notationTitle)
            else { continue }
            if lines[(titleIndex + 1)...].contains(where: isHyphenLine) { return true }
        }
        return false
    }

    private static func hasAozoraMarkup(_ text: Substring) -> Bool {
        if text.contains("［＃") { return true }
        // ｜base《reading》 on one line: the bar is unambiguous Aozora markup.
        var searchStart = text.startIndex
        while let bar = text[searchStart...].firstIndex(of: "｜") {
            searchStart = text.index(after: bar)
            guard let opening = text[searchStart...].firstIndex(where: { $0 == "《" || $0 == "｜" || $0.isNewline }),
                  opening > searchStart, text[opening] == "《"
            else { continue }
            let readingStart = text.index(after: opening)
            if let closing = text[readingStart...].firstIndex(where: { $0 == "》" || $0 == "《" || $0.isNewline }),
               closing > readingStart, text[closing] == "》" {
                return true
            }
        }
        return false
    }

    private static func lines(of text: Substring) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }
}
