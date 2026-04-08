import Foundation

enum TXTChapterParser {
    struct ParsedChapter {
        let title: String
        let paragraphs: [String]
    }

    static func parseUnifiedChapters(_ text: String, bookTitle: String) -> [UnifiedChapter] {
        parseChapters(text, bookTitle: bookTitle)
            .enumerated()
            .map { index, chapter in
                UnifiedChapter(
                    index: index,
                    title: chapter.title,
                    paragraphs: chapter.paragraphs,
                    sourceHref: nil
                )
            }
    }

    private static let chapterPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+章[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+[節节][^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+卷[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+回[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+篇[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+部[^\\n]*",
            "^\\s*卷[零一二三四五六七八九十百千萬万\\d]+[^\\n]*",
            "^\\s*Chapter\\s*\\d+[^\\n]*",
            "^\\s*CHAPTER\\s*\\d+[^\\n]*",
            "^\\s*Part\\s*\\d+[^\\n]*",
            "^\\s*PART\\s*\\d+[^\\n]*",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .anchorsMatchLines) }
    }()

    private static let specialTitlePattern: NSRegularExpression? = {
        let titles = [
            "序章", "序言", "序幕", "前言", "引子", "引言", "楔子",
            "尾聲", "尾声", "終章", "终章", "後記", "后记",
            "番外", "後序", "后序", "結語", "结语",
            "Prologue", "Epilogue", "Preface", "Introduction",
        ]
        let pattern = "^\\s*(" + titles.joined(separator: "|") + ")[^\\n]*$"
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
    }()

    static func parseChapters(_ text: String, bookTitle: String) -> [ParsedChapter] {
        var bestMatches: [(Range<String.Index>, String)] = []

        for regex in chapterPatterns {
            let nsText = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            if results.count >= 2 {
                bestMatches = results.compactMap { match in
                    guard let range = Range(match.range, in: text) else { return nil }
                    return (range, String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                break
            }
        }

        if let specialRegex = specialTitlePattern {
            let nsText = text as NSString
            let specialResults = specialRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            let specialRanges: [(Range<String.Index>, String)] = specialResults.compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                return (range, String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !specialRanges.isEmpty {
                bestMatches.append(contentsOf: specialRanges)
                bestMatches.sort { $0.0.lowerBound < $1.0.lowerBound }
            }
        }

        if !bestMatches.isEmpty {
            var chapters: [ParsedChapter] = []

            let firstTitleStart = bestMatches[0].0.lowerBound
            if firstTitleStart > text.startIndex {
                let preface = String(text[text.startIndex..<firstTitleStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if preface.count > 50 {
                    chapters.append(ParsedChapter(title: "前言", paragraphs: splitIntoParagraphs(preface)))
                }
            }

            for (index, (range, title)) in bestMatches.enumerated() {
                let contentStart: String.Index
                if range.upperBound < text.endIndex {
                    let nextIndex = text.index(after: range.upperBound)
                    contentStart = nextIndex <= text.endIndex ? nextIndex : range.upperBound
                } else {
                    contentStart = range.upperBound
                }

                let contentEnd = index + 1 < bestMatches.count ? bestMatches[index + 1].0.lowerBound : text.endIndex
                let safeStart = min(contentStart, text.endIndex)
                let safeEnd = max(safeStart, contentEnd)
                let body = String(text[safeStart..<safeEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                chapters.append(ParsedChapter(title: title, paragraphs: splitIntoParagraphs(body)))
            }

            return chapters.isEmpty ? [ParsedChapter(title: bookTitle, paragraphs: splitIntoParagraphs(text))] : chapters
        }

        return splitIntoBlocks(text, blockSize: 3000, bookTitle: bookTitle)
    }

    private static func splitIntoBlocks(_ text: String, blockSize: Int, bookTitle: String) -> [ParsedChapter] {
        let paragraphs = splitIntoParagraphs(text)
        if paragraphs.isEmpty {
            return [ParsedChapter(title: bookTitle, paragraphs: [text])]
        }

        var chapters: [ParsedChapter] = []
        var current: [String] = []
        var currentSize = 0
        var chapterNum = 0

        for paragraph in paragraphs {
            current.append(paragraph)
            currentSize += paragraph.count
            if currentSize >= blockSize {
                chapterNum += 1
                chapters.append(ParsedChapter(title: "第 \(chapterNum) 節", paragraphs: current))
                current.removeAll(keepingCapacity: true)
                currentSize = 0
            }
        }

        if !current.isEmpty {
            chapterNum += 1
            let title = chapterNum == 1 ? bookTitle : "第 \(chapterNum) 節"
            chapters.append(ParsedChapter(title: title, paragraphs: current))
        }

        return chapters
    }

    private static func splitIntoParagraphs(_ text: String) -> [String] {
        var cleaned = text
        let hasHTML = cleaned.range(of: "<(?:p|div|br|span|h[1-6]|li|section|article)[\\s>/]", options: .regularExpression) != nil

        if hasHTML {
            cleaned = cleaned.replacingOccurrences(of: "<(script|style|noscript)[^>]*>[\\s\\S]*?</\\1>", with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</(?:p|div|li|blockquote|section|article|dt|dd|figcaption|pre|header|footer)>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</h[1-6]>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)
            cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            cleaned = decodeHTMLEntities(cleaned)
        }

        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")

        return cleaned
            .components(separatedBy: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}"))
            }
            .filter { !$0.isEmpty }
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&ensp;", with: " ")
        result = result.replacingOccurrences(of: "&emsp;", with: " ")
        result = result.replacingOccurrences(of: "&thinsp;", with: "")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")

        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let nsResult = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let hexRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(codePoint),
                      let fullRange = Range(match.range, in: result)
                else { continue }
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }

        if let decRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsResult = result as NSString
            let matches = decRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let decRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[decRange]),
                      let scalar = Unicode.Scalar(codePoint),
                      let fullRange = Range(match.range, in: result)
                else { continue }
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }

        return result
    }
}

struct TXTBookParser: BookParser {
    static let supportedExtensions: [String] = ["txt"]

    func parse(fileURL: URL, titleOverride: String?) throws -> ParsedBookDocument {
        let text = try TXTFileReader.readTextFile(url: fileURL)
        let title = titleOverride ?? fileURL.deletingPathExtension().lastPathComponent
        let chapters = TXTChapterParser.parseUnifiedChapters(text, bookTitle: title)
        return ParsedBookDocument(title: title, author: "未知作者", chapters: chapters)
    }
}

