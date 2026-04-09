import Foundation

struct TXTChapterIndex: Equatable {
    let index: Int
    let title: String
    let contentRange: NSRange

    var sourceHref: String { String(index) }
}

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

    static func parseChapterIndexes(_ text: String, bookTitle: String) -> [TXTChapterIndex] {
        let nsText = text as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else {
            return [TXTChapterIndex(index: 0, title: bookTitle, contentRange: NSRange(location: 0, length: 0))]
        }

        let titleMatches = detectTitleMatches(in: text)
        if !titleMatches.isEmpty {
            var indexes: [TXTChapterIndex] = []

            let firstTitleStart = titleMatches[0].range.location
            if firstTitleStart > 0 {
                let prefaceRange = NSRange(location: 0, length: firstTitleStart)
                if hasReadableContent(in: nsText, range: prefaceRange) {
                    indexes.append(
                        TXTChapterIndex(
                            index: indexes.count,
                            title: "前言",
                            contentRange: prefaceRange
                        )
                    )
                }
            }

            for (i, match) in titleMatches.enumerated() {
                let end = i + 1 < titleMatches.count
                    ? titleMatches[i + 1].range.location
                    : totalLength
                let rawStart = match.range.location + match.range.length
                let start = skipLeadingWhitespace(in: nsText, from: rawStart, upperBound: end)
                guard end >= start else { continue }
                let chapterRange = NSRange(location: start, length: end - start)
                indexes.append(
                    TXTChapterIndex(
                        index: indexes.count,
                        title: match.title,
                        contentRange: chapterRange
                    )
                )
            }

            if indexes.isEmpty {
                return [TXTChapterIndex(index: 0, title: bookTitle, contentRange: NSRange(location: 0, length: totalLength))]
            }
            return indexes
        }

        return splitIntoBlockIndexes(text, blockSize: 3000, bookTitle: bookTitle)
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
        let indexes = parseChapterIndexes(text, bookTitle: bookTitle)
        return indexes.map { idx in
            let body = chapterText(text, range: idx.contentRange)
            return ParsedChapter(
                title: idx.title,
                paragraphs: splitIntoParagraphs(body)
            )
        }
    }

    static func chapterText(_ text: String, range: NSRange) -> String {
        let nsText = text as NSString
        let safe = safeRange(range, in: nsText)
        guard safe.length > 0 else { return "" }
        return nsText.substring(with: safe)
    }

    static func paragraphsForChapterContent(_ text: String) -> [String] {
        splitIntoParagraphs(text)
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

    private static func splitIntoBlockIndexes(_ text: String, blockSize: Int, bookTitle: String) -> [TXTChapterIndex] {
        let nsText = text as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else {
            return [TXTChapterIndex(index: 0, title: bookTitle, contentRange: NSRange(location: 0, length: 0))]
        }

        var result: [TXTChapterIndex] = []
        var cursor = 0
        while cursor < totalLength {
            var end = min(cursor + blockSize, totalLength)
            if end < totalLength {
                let tailLen = min(256, totalLength - end)
                let tail = nsText.substring(with: NSRange(location: end, length: tailLen))
                if let lineBreak = tail.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let distance = tail.distance(from: tail.startIndex, to: lineBreak)
                    end += distance
                }
            }
            let range = NSRange(location: cursor, length: max(0, end - cursor))
            let title = result.isEmpty ? bookTitle : "第 \(result.count + 1) 節"
            result.append(TXTChapterIndex(index: result.count, title: title, contentRange: range))
            cursor = max(end, cursor + 1)
        }
        return result
    }

    private struct TitleMatch {
        let range: NSRange
        let title: String
    }

    private static func detectTitleMatches(in text: String) -> [TitleMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var selected: [TitleMatch] = []

        for regex in chapterPatterns {
            let results = regex.matches(in: text, range: fullRange)
            if results.count >= 2 {
                selected = results.compactMap { match in
                    let raw = nsText.substring(with: match.range)
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return TitleMatch(range: match.range, title: trimmed)
                }
                break
            }
        }

        if let specialRegex = specialTitlePattern {
            let special = specialRegex.matches(in: text, range: fullRange).compactMap { match -> TitleMatch? in
                let raw = nsText.substring(with: match.range)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TitleMatch(range: match.range, title: trimmed)
            }
            selected.append(contentsOf: special)
        }

        if selected.isEmpty { return [] }

        selected.sort {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var deduped: [TitleMatch] = []
        var seenLocations = Set<Int>()
        for item in selected where !seenLocations.contains(item.range.location) {
            deduped.append(item)
            seenLocations.insert(item.range.location)
        }
        return deduped
    }

    private static func skipLeadingWhitespace(in text: NSString, from start: Int, upperBound: Int) -> Int {
        guard start < upperBound else { return min(start, upperBound) }
        var cursor = max(0, start)
        let limit = max(cursor, upperBound)
        while cursor < limit {
            let scalar = UnicodeScalar(text.character(at: cursor))
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == " " || scalar == "\u{3000}" {
                cursor += 1
                continue
            }
            break
        }
        return cursor
    }

    private static func hasReadableContent(in text: NSString, range: NSRange) -> Bool {
        let safe = safeRange(range, in: text)
        guard safe.length > 0 else { return false }
        let raw = text.substring(with: safe)
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func safeRange(_ range: NSRange, in text: NSString) -> NSRange {
        let cappedStart = max(0, min(range.location, text.length))
        let cappedEnd = max(cappedStart, min(range.location + range.length, text.length))
        let normalized = NSRange(location: cappedStart, length: cappedEnd - cappedStart)
        guard normalized.length > 0 else { return normalized }
        return text.rangeOfComposedCharacterSequences(for: normalized)
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
    func parse(url: URL) async throws -> ParsedBookDocument {
        let text = try TXTFileReader.readTextFile(url: url)
            .filter { ch in
                if ch == "\n" || ch == "\r" || ch == "\t" { return true }
                return !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isWhitespace
            }
        let title = url.deletingPathExtension().lastPathComponent
        let chapters = TXTChapterParser.parseChapters(text, bookTitle: title)
            .map { chapter in
                let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = chapter.paragraphs
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty { return body }
                if body.isEmpty { return trimmedTitle }
                return trimmedTitle + "\n" + body
            }
            .filter { !$0.isEmpty }
        return ParsedBookDocument(title: title, author: "未知作者", chapters: chapters)
    }
}

