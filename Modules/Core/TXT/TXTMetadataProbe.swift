import Foundation

struct TXTBookMetadata: Equatable, Sendable {
    let title: String
    let author: String?
    /// 文案／内容简介 as the file's header gives it, a paragraph a line.
    var intro: String? = nil
    /// The header's 标签／类型 line, at most five.
    var tags: [String] = []
}

enum TXTMetadataProbe {
    static let maximumSampleBytes = 128 * 1024
    static let maximumMetadataCharacters = 3_000

    static func probe(url: URL, fallbackTitle: String) throws -> TXTBookMetadata {
        let prefix = try TXTFileReader.readPrefix(
            url: url,
            maxByteCount: maximumSampleBytes
        )
        return infer(from: prefix, fallbackTitle: fallbackTitle)
    }

    static func infer(from prefix: String, fallbackTitle: String) -> TXTBookMetadata {
        // An Aozora Bunko file names its work and author on its first lines,
        // with no 書名／作者 labels; the brackets in 『…』中篇自序 belong to the title.
        if AozoraDocumentDetector.isAozoraDocument(prefix),
           let header = AozoraHeaderParser.parse(headerLines: AozoraDocumentParser.headerLines(of: prefix)) {
            return TXTBookMetadata(title: header.title, author: header.author)
        }
        let sample = String(prefix.prefix(maximumMetadataCharacters))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // A downloaded file's name: 《万古神帝》（精校版全本）作者：飞天鱼.txt.
        let file = fileNameParts(fallbackTitle)
        let fallback = file.title
        let lines = sample.components(separatedBy: "\n")

        let explicitTitle = firstCapture(
            in: sample,
            patterns: [
                #"(?im)^\s*(?:書名|书名|作品名|作品名稱|作品名称|Title)\s*[：:﹕]\s*(.{1,80}?)\s*$"#
            ],
            maximumLength: 80
        )
        let explicitAuthor = firstCapture(
            in: sample,
            patterns: [
                #"(?im)^\s*(?:作者|著者|著)\s*[：:﹕]\s*([^\n，,。！？]{1,40}?)\s*$"#,
                #"(?im)^\s*Author\s*[：:]\s*([^\n,.;!?]{1,60}?)\s*$"#,
                #"(?im)^\s*Written\s+by\s*[：:]?\s*([^\n,.;!?]{1,60}?)\s*$"#
            ],
            maximumLength: 60
        )

        // A web novel download's first line: 《万古神帝》作者：飞天鱼, or 修真聊天群 作者：圣骑士的传说.
        let creditLine = bookCreditLine(in: sample)
        let standaloneCredit = standaloneAuthorCredit(in: sample)
        // 我师兄实在太稳健了 / 作者：言归正传: the title is the line above the 作者 line.
        let titleAboveAuthor = explicitAuthor == nil ? nil : authorLineIndex(in: lines)
            .flatMap { titleBeforeAuthorCredit(lines: lines, authorLineIndex: $0) }
        let inferredTitle = explicitTitle ?? creditLine?.title ?? titleAboveAuthor
            ?? standaloneCredit.flatMap { titleBeforeAuthorCredit(lines: $0.lines, authorLineIndex: $0.index) }
        let inferredAuthor = explicitAuthor ?? creditLine?.author ?? standaloneCredit?.author ?? file.author
        let header = Array(lines.prefix { !isChapterHeading($0) })

        return TXTBookMetadata(
            title: inferredTitle ?? fallback,
            author: inferredAuthor,
            intro: introduction(in: header),
            tags: tags(in: header)
        )
    }

    // MARK: - The header before the first chapter

    private static let introLabel = try? NSRegularExpression(
        pattern: #"^\s*【?(?:文案|简介|簡介|内容简介|內容簡介|作品简介|作品簡介|内容介绍|內容介紹|小说简介|小說簡介|书籍简介|書籍簡介|故事简介|故事簡介)】?\s*(?:[：:﹕]\s*(.*))?$"#
    )
    private static let tagLabel = try? NSRegularExpression(
        pattern: #"^\s*【?(?:标签|標籤|作品标签|作品標籤|类型|類型|分类|分類|题材|題材)】?\s*[：:﹕]\s*(.+)$"#
    )
    private static let otherLabel = try? NSRegularExpression(
        pattern: #"^\s*(?:书名|書名|作者|著者|主角|配角|状态|狀態|字数|字數|出版社|ISBN)\s*[：:﹕]"#, options: [.caseInsensitive]
    )

    /// The first group of `regex` on `line`, "" when it matched without one; nil when it did not.
    private static func capture(_ regex: NSRegularExpression?, _ line: String) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[range])
    }

    /// 文案：／内容简介：and what follows, up to the 标签 line, another label, an advert, the
    /// first chapter or two blank lines; a repeated 「简介：」 is the same label.
    private static func introduction(in header: [String]) -> String? {
        guard let start = header.firstIndex(where: { capture(introLabel, $0) != nil }) else { return nil }
        var paragraphs: [String] = []
        var blanks = 0
        for (offset, raw) in header[start...].enumerated() {
            var line = raw
            if let rest = capture(introLabel, raw) {
                guard offset == 0 || paragraphs.isEmpty else { break }
                line = rest
            } else if offset > 0, capture(tagLabel, raw) != nil || capture(otherLabel, raw) != nil || isNoise(raw) {
                break
            }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                blanks += 1
                if blanks >= 2, !paragraphs.isEmpty { break }
                continue
            }
            blanks = 0
            paragraphs.append(text)
            if paragraphs.joined(separator: "\n").count > 2_000 { break }
        }
        let intro = paragraphs.joined(separator: "\n")
        return intro.isEmpty ? nil : String(intro.prefix(2_000))
    }

    private static func tags(in header: [String]) -> [String] {
        guard let value = header.lazy.compactMap({ capture(tagLabel, $0) }).first else { return [] }
        var seen = Set<String>()
        return Array(value
            .components(separatedBy: CharacterSet(charactersIn: "、，,/|；;").union(.whitespaces))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 12 && !$0.contains(where: \.isNumber) && seen.insert($0).inserted }
            .prefix(5))
    }

    private static let chapterHeading = try? NSRegularExpression(
        pattern: #"^\s*(?:第[0-9０-９零〇一二三四五六七八九十百千万萬两兩]+[章节節回卷集部篇]|序章|序言|楔子|引子|前言|番外|尾声|尾聲|后记|後記|Chapter\s*\d+)"#,
        options: [.caseInsensitive]
    )

    private static func isChapterHeading(_ line: String) -> Bool { capture(chapterHeading, line) != nil }

    /// A download site's banner: its address, its slogan, or a rule of = or -.
    static func isNoise(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.count >= 3, text.allSatisfy({ "=-*~_─━—·.".contains($0) }) { return true }
        let lowered = text.lowercased()
        return ["http", "www.", ".com", ".net", ".org", "下载", "下載", "本站", "尽在", "盡在", "txt小说", "txt小說"]
            .contains { lowered.contains($0) }
    }

    private static let authorLine = try? NSRegularExpression(pattern: #"^\s*(?:作者|著者|著)\s*[：:﹕]"#)

    private static func authorLineIndex(in lines: [String]) -> Int? {
        lines.firstIndex { capture(authorLine, $0) != nil }
    }

    // MARK: - The file's name

    private static let editionWords = "精校|全本|完结|完結|完本|校对|校對|全集|txt|出书版|出書版|实体|實體|修订|修訂|无错|無錯|插图|插圖|全文|连载|連載|精排|典藏"

    /// A downloaded file's name as a title and, when it names one, an author: brackets and
    /// edition words (精校版、全本、完结) dropped.
    static func fileNameParts(_ name: String) -> (title: String, author: String?) {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var author: String?
        if let match = title.range(of: #"(?:作者|著者)\s*[：:_\-]\s*"#, options: .regularExpression) {
            author = stripEdition(String(title[match.upperBound...]))
            title = String(title[..<match.lowerBound])
        }
        if let open = title.firstIndex(of: "《"), let close = title[open...].firstIndex(of: "》") {
            title = String(title[title.index(after: open)..<close])
        }
        let cleanedTitle = stripEdition(title)
        return (cleaned(cleanedTitle, maximumLength: 120) ?? (cleaned(name, maximumLength: 120) ?? name),
                author.flatMap { cleaned($0, maximumLength: 40) })
    }

    private static func stripEdition(_ text: String) -> String {
        var value = text.replacingOccurrences(
            of: #"[(（\[【［〔][^)）\]】］〕]*(?:"# + editionWords + #")[^)）\]】］〕]*[)）\]】］〕]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        while let range = value.range(of: #"[\s_\-—]*(?:(?:"# + editionWords + #")版?)+\s*$"#,
                                      options: [.regularExpression, .caseInsensitive]),
              !range.isEmpty, range.lowerBound != value.startIndex {
            value.removeSubrange(range)
        }
        return value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "_-—")))
    }

    private static func firstCapture(
        in text: String,
        patterns: [String],
        maximumLength: Int
    ) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text),
                  let candidate = cleaned(String(text[captureRange]), maximumLength: maximumLength)
            else { continue }
            return candidate
        }
        return nil
    }

    /// A whole line `《書名》作者：某某`, the author in brackets or not; nil for a sentence that
    /// only mentions a book.
    private static func bookCreditLine(in text: String) -> (title: String, author: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^\s*(?:《([^《》\n]{1,80})》\s*[（(]?|([^\s《》：:，,。！？][^\n《》：:，,。！？]{0,39}?)[ \t\u3000]+)(?:作者|著者)\s*[：:﹕]\s*([^\n，,。！？（）()]{1,40}?)\s*[）)]?\s*$"#
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 3,
              let titleRange = Range(match.range(at: 1), in: text) ?? Range(match.range(at: 2), in: text),
              let authorRange = Range(match.range(at: 3), in: text),
              let title = cleaned(String(text[titleRange]), maximumLength: 80),
              let author = cleaned(String(text[authorRange]), maximumLength: 40)
        else { return nil }
        return (title, author)
    }

    private static func standaloneAuthorCredit(
        in text: String
    ) -> (author: String, lines: [String], index: Int)? {
        let lines = text.components(separatedBy: "\n")
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*([^\n，,。！？：:]{1,30}?)\s+著\s*$"#
        ) else { return nil }

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: line),
                  let author = cleaned(String(line[captureRange]), maximumLength: 30)
            else { continue }
            return (author, lines, index)
        }
        return nil
    }

    private static func titleBeforeAuthorCredit(lines: [String], authorLineIndex: Int) -> String? {
        guard authorLineIndex > 0 else { return nil }
        for line in lines[..<authorLineIndex].reversed() {
            guard let candidate = cleaned(line, maximumLength: 60), !isNoise(candidate) else { continue }
            if candidate.range(
                of: #"^(?:第.{0,20}[章卷回部]|Chapter\s+\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                continue
            }
            if candidate.range(of: #"[。！？!?]$"#, options: .regularExpression) != nil {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func cleaned(_ raw: String, maximumLength: Int) -> String? {
        let wrappers = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "《》〈〉「」『』\"'“”‘’")
        )
        let value = raw.trimmingCharacters(in: wrappers)
        guard !value.isEmpty, value.count <= maximumLength else { return nil }
        return value
    }
}
