import Foundation

// MARK: - TXT → XHTML 轉換器（大廠做法：語意化後重用 EPUB 渲染管線）

final class TXTToXHTMLConverter {
    struct ChapterInput {
        let title: String
        let body: String
    }

    struct XHTMLChapterInput {
        let title: String
        let html: String
        let href: String?
    }

    // MARK: - 公開介面

    /// 解析結果
    struct ConvertedBook {
        let title: String
        let chapters: [EPUBChapterRaw]
        let basePath: URL  // XHTML 暫存目錄
        let tocEntries: [EPUBTocEntry]
    }

    /// 從 TXT 檔案 URL 讀取並轉換
    /// - Parameters:
    ///   - url: TXT 檔案路徑
    ///   - title: 書名（若 nil 則使用檔名）
    /// - Returns: 轉換結果（含 EPUBChapterRaw 陣列）
    static func convert(url: URL, title: String? = nil) throws -> ConvertedBook {
        let text = try readTextFile(url: url)
        let bookTitle = title ?? url.deletingPathExtension().lastPathComponent
        return try convert(text: text, title: bookTitle)
    }

    /// 從純文字字串轉換
    static func convert(text: String, title: String) throws -> ConvertedBook {
        let chapters = parseChapters(text, bookTitle: title)
        return try convert(parsedChapters: chapters, title: title)
    }

    static func convert(chapters: [ChapterInput], title: String) throws -> ConvertedBook {
        let parsed = chapters.map { chapter in
            var paragraphs = splitIntoParagraphs(chapter.body)
            // 去除正文開頭與 TOC 標題重複的行，避免 <h1> 和首段重複顯示
            paragraphs = stripLeadingTitleFromParagraphs(paragraphs, chapterTitle: chapter.title)
            return ParsedChapter(
                title: chapter.title,
                paragraphs: paragraphs
            )
        }
        return try convert(parsedChapters: parsed, title: title)
    }

    static func convert(
        xhtmlChapters: [XHTMLChapterInput],
        title: String,
        basePathPrefix: String = "reader_xhtml",
        reuseBasePath: URL? = nil
    ) throws -> ConvertedBook {
        try buildConvertedBook(
            title: title,
            basePathPrefix: basePathPrefix,
            xhtmlChapters: xhtmlChapters,
            reuseBasePath: reuseBasePath
        )
    }

    static func package(
        from converted: ConvertedBook,
        title: String,
        author: String,
        pipelineKind: BookPipelineKind,
        originalSourceURL: URL?
    ) -> BookPackage {
        let parsed = EPUBParsedBook(
            title: title,
            author: author,
            chapters: converted.chapters,
            basePath: converted.basePath,
            coverImageURL: nil,
            tocEntries: converted.tocEntries
        )
        return parsed.makePackage(pipelineKind: pipelineKind, originalSourceURL: originalSourceURL)
    }

    private static func convert(parsedChapters: [ParsedChapter], title: String) throws -> ConvertedBook {
        // 內容驗證：過濾空章節、記錄異常
        var validatedChapters = parsedChapters
        if !validatedChapters.isEmpty {
            let emptyCount = validatedChapters.filter { $0.paragraphs.isEmpty }.count
            if emptyCount > 0 {
                ReaderTelemetry.shared.log(
                    "ingest_validation",
                    attributes: [
                        "title": title,
                        "totalChapters": "\(validatedChapters.count)",
                        "emptyChapters": "\(emptyCount)",
                    ]
                )
            }
            // 過濾掉真正空的章節（段落為空且不是佔位符）
            validatedChapters = validatedChapters.filter { chapter in
                !chapter.paragraphs.isEmpty || chapter.title.contains("載入") || chapter.title.contains("载入")
            }
        }

        let chapters = validatedChapters.isEmpty
            ? [ParsedChapter(title: title, paragraphs: ["載入章節中…"])]
            : validatedChapters

        let xhtmlChapters = chapters.enumerated().map { (index, chapter) in
            XHTMLChapterInput(
                title: chapter.title,
                html: buildXHTML(
                    title: chapter.title,
                    paragraphs: chapter.paragraphs
                ),
                href: "chapter_\(index).xhtml"
            )
        }
        return try buildConvertedBook(
            title: title,
            basePathPrefix: "txt_xhtml",
            xhtmlChapters: xhtmlChapters
        )
    }

    private static func buildConvertedBook(
        title: String,
        basePathPrefix: String,
        xhtmlChapters: [XHTMLChapterInput],
        reuseBasePath: URL? = nil
    ) throws -> ConvertedBook {
        let normalizedInputs = xhtmlChapters.isEmpty
            ? [XHTMLChapterInput(
                title: title,
                html: ReaderAdapterAssets.normalizedChapterHTML(
                    title: title,
                    paragraphs: ["載入章節中…"]
                ),
                href: "chapter_0.xhtml"
            )]
            : xhtmlChapters

        let basePath: URL
        if let reuse = reuseBasePath {
            basePath = reuse
        } else {
            basePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(basePathPrefix)_\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)

        var epubChapters: [EPUBChapterRaw] = []
        var tocEntries: [EPUBTocEntry] = []

        for (i, chapter) in normalizedInputs.enumerated() {
            let href = chapter.href ?? "chapter_\(i).xhtml"
            let fileURL = basePath.appendingPathComponent(href)
            try chapter.html.write(to: fileURL, atomically: true, encoding: .utf8)

            epubChapters.append(
                EPUBChapterRaw(
                    href: href,
                    title: chapter.title,
                    html: chapter.html,
                    cssEntries: [],
                    baseURL: basePath
                )
            )
            tocEntries.append(
                EPUBTocEntry(
                    href: href,
                    title: chapter.title,
                    level: 0
                )
            )
        }

        return ConvertedBook(
            title: title,
            chapters: epubChapters,
            basePath: basePath,
            tocEntries: tocEntries
        )
    }

    /// 清理暫存目錄
    static func cleanup(basePath: URL) {
        try? FileManager.default.removeItem(at: basePath)
    }

    // MARK: - 編碼偵測

    /// 多編碼嘗試讀取 TXT：UTF-8 → BIG5 → GBK → 系統自動偵測
    static func readTextFile(url: URL) throws -> String {
        // 1. UTF-8
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        // 2. BIG5
        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        if let text = try? String(contentsOf: url, encoding: big5) {
            return text
        }

        // 3. GBK (GB18030)
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = try? String(contentsOf: url, encoding: gbk) {
            return text
        }

        // 4. 讓系統自動偵測
        var usedEncoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return text
        }

        throw TXTConvertError.encodingNotSupported
    }
}

extension TXTToXHTMLConverter {

    // MARK: - 章節解析

    /// 解析後的章節（中間格式）
    struct ParsedChapter {
        let title: String
        let paragraphs: [String]  // 段落列表（已去除多餘空白）
    }

    /// 預編譯的正則表達式
    private static let chapterPatterns: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // 中文章節（同時支援繁體與簡體）
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+章[^\\n]*", "chapter"),
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+[節节][^\\n]*", "section"),
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+卷[^\\n]*", "volume"),
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+回[^\\n]*", "episode"),
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+篇[^\\n]*", "part"),
            ("^\\s*第[零一二三四五六七八九十百千萬万\\d]+部[^\\n]*", "part"),
            // 卷X 格式
            ("^\\s*卷[零一二三四五六七八九十百千萬万\\d]+[^\\n]*", "volume"),
            // 英文章節
            ("^\\s*Chapter\\s*\\d+[^\\n]*", "chapter"),
            ("^\\s*CHAPTER\\s*\\d+[^\\n]*", "chapter"),
            ("^\\s*Part\\s*\\d+[^\\n]*", "part"),
            ("^\\s*PART\\s*\\d+[^\\n]*", "part"),
        ]
        return patterns.compactMap { (pattern, type) in
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            else { return nil }
            return (regex, type)
        }
    }()

    /// 特殊章節標題（獨立行匹配）
    private static let specialTitlePattern: NSRegularExpression? = {
        let titles = [
            "序章", "序言", "序幕", "前言", "引子", "引言", "楔子",
            "尾聲", "尾声", "終章", "终章", "後記", "后记",
            "番外", "後序", "后序", "結語", "结语",
            "Prologue", "Epilogue", "Preface", "Introduction",
        ]
        let pattern = "^\\s*(" + titles.joined(separator: "|") + ")[^\\n]*$"
        return try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
    }()

    /// 解析文本為章節列表
    static func parseChapters(_ text: String, bookTitle: String) -> [ParsedChapter] {
        // 1. 嘗試用正則找章節標題
        var bestMatches: [(Range<String.Index>, String)] = []

        for (regex, _) in chapterPatterns {
            let nsText = text as NSString
            let results = regex.matches(
                in: text, range: NSRange(location: 0, length: nsText.length))
            if results.count >= 2 {
                bestMatches = results.compactMap { m -> (Range<String.Index>, String)? in
                    guard let r = Range(m.range, in: text) else { return nil }
                    return (r, String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                break
            }
        }

        // 2. 也嘗試特殊標題（序章、楔子等），合併到結果中
        if let specialRegex = specialTitlePattern {
            let nsText = text as NSString
            let specialResults = specialRegex.matches(
                in: text, range: NSRange(location: 0, length: nsText.length))
            let specialRanges: [(Range<String.Index>, String)] = specialResults.compactMap { m in
                guard let r = Range(m.range, in: text) else { return nil }
                return (r, String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !specialRanges.isEmpty {
                bestMatches.append(contentsOf: specialRanges)
                bestMatches.sort { $0.0.lowerBound < $1.0.lowerBound }
            }
        }

        // 3. 有章節結構：按標題拆分
        if !bestMatches.isEmpty {
            var chapters: [ParsedChapter] = []

            // 保留第一個標題前的內容（序言/前言）
            let firstTitleStart = bestMatches[0].0.lowerBound
            if firstTitleStart > text.startIndex {
                let preface = String(text[text.startIndex..<firstTitleStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if preface.count > 50 {  // 超過 50 字才保留，太短可能是書名/作者等無用資訊
                    let paras = splitIntoParagraphs(preface)
                    chapters.append(ParsedChapter(title: "前言", paragraphs: paras))
                }
            }

            // 每個章節標題到下一個標題之間的內容
            for (i, (range, title)) in bestMatches.enumerated() {
                let contentStart: String.Index
                if range.upperBound < text.endIndex {
                    contentStart =
                        text.index(after: range.upperBound) <= text.endIndex
                        ? text.index(after: range.upperBound)
                        : range.upperBound
                } else {
                    contentStart = range.upperBound
                }

                let contentEnd =
                    i + 1 < bestMatches.count
                    ? bestMatches[i + 1].0.lowerBound
                    : text.endIndex

                let safeStart = min(contentStart, text.endIndex)
                let safeEnd = max(safeStart, contentEnd)
                let body = String(text[safeStart..<safeEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let paras = splitIntoParagraphs(body)
                chapters.append(ParsedChapter(title: title, paragraphs: paras))
            }

            return chapters.isEmpty
                ? [ParsedChapter(title: bookTitle, paragraphs: splitIntoParagraphs(text))]
                : chapters
        }

        // 4. 無章節結構：在段落邊界按約 3000 字分塊
        return splitIntoBlocks(text, blockSize: 3000, bookTitle: bookTitle)
    }

    /// 去除正文段落開頭與章節標題重複的行
    /// 許多網站的正文開頭會包含章節標題（如「第一章 倫敦孤兒」），
    /// 而 TOC 已經提供了權威標題，不需要在正文中重複顯示。
    private static func stripLeadingTitleFromParagraphs(_ paragraphs: [String], chapterTitle: String) -> [String] {
        guard !paragraphs.isEmpty, !chapterTitle.isEmpty else { return paragraphs }

        let normalizedTitle = chapterTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()

        // 最多檢查前 3 段（標題可能不在第一行，前面可能有空白行殘留）
        var dropCount = 0
        for (i, para) in paragraphs.prefix(3).enumerated() {
            let normalizedPara = para
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                .lowercased()

            if normalizedPara.isEmpty {
                dropCount = i + 1
                continue
            }

            // 完全匹配 或 標題包含段落 或 段落包含標題
            if normalizedPara == normalizedTitle
                || normalizedTitle.contains(normalizedPara)
                || normalizedPara.contains(normalizedTitle)
            {
                // 確認是「標題行」而非正文段落（正文段落通常較長）
                if para.count < chapterTitle.count * 3 && para.count < 80 {
                    dropCount = i + 1
                    continue
                }
            }
            break
        }

        if dropCount > 0 {
            return Array(paragraphs.dropFirst(dropCount))
        }
        return paragraphs
    }

    /// 將文本拆分為段落（支援純文字 + HTML 內容）
    private static func splitIntoParagraphs(_ text: String) -> [String] {
        var cleaned = text

        // 1. 偵測是否含 HTML — 如果有 <p>, <div>, <br> 等標籤，先轉成純文字
        let hasHTML =
            cleaned.range(
                of: "<(?:p|div|br|span|h[1-6]|li|section|article)[\\s>/]",
                options: .regularExpression,
                range: cleaned.startIndex..<cleaned.endIndex) != nil

        if hasHTML {
            // 移除 script / style 等不可見區塊（含內容）
            cleaned = cleaned.replacingOccurrences(
                of: "<(script|style|noscript)[^>]*>[\\s\\S]*?</\\1>",
                with: "", options: .regularExpression)
            // 把 block 標籤轉成換行（開標籤 + 閉標籤都處理）
            cleaned = cleaned.replacingOccurrences(
                of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            // 閉合塊級標籤 → 換行
            cleaned = cleaned.replacingOccurrences(
                of: "</(?:p|div|li|blockquote|section|article|dt|dd|figcaption|pre|header|footer)>",
                with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(
                of: "</h[1-6]>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(
                of: "</tr>", with: "\n", options: .caseInsensitive)
            // 移除所有剩餘 HTML 標籤
            cleaned = cleaned.replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression)
            // 解碼 HTML entities
            cleaned = Self.decodeHTMLEntities(cleaned)
        }

        // 2. 統一換行符
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")

        // 3. 按行拆分，每個非空行作為一個段落
        let lines = cleaned.components(separatedBy: "\n")
        var paragraphs: [String] = []

        for line in lines {
            // 去除首尾空白 + 中文全形空格縮排
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}"))  // 全形空格
            if !trimmed.isEmpty {
                paragraphs.append(trimmed)
            }
        }

        return paragraphs
    }

    /// 解碼 HTML entities（命名 + 數字 + 十六進位）
    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        // 命名 entities
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
        result = result.replacingOccurrences(of: "&mdash;", with: "—")
        result = result.replacingOccurrences(of: "&ndash;", with: "–")
        result = result.replacingOccurrences(of: "&hellip;", with: "…")
        result = result.replacingOccurrences(of: "&lsquo;", with: "\u{2018}")
        result = result.replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
        result = result.replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
        result = result.replacingOccurrences(of: "&rdquo;", with: "\u{201D}")

        // 十六進位數字 entities：&#xHHHH; → 對應 Unicode 字元
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let nsResult = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            // 從後往前替換避免 range 偏移
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

        // 十進位數字 entities：&#DDD; → 對應 Unicode 字元
        if let decRegex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
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

    /// 無章節時按段落邊界分塊
    private static func splitIntoBlocks(_ text: String, blockSize: Int, bookTitle: String)
        -> [ParsedChapter]
    {
        let paragraphs = splitIntoParagraphs(text)

        if paragraphs.isEmpty {
            return [ParsedChapter(title: bookTitle, paragraphs: [text])]
        }

        var chapters: [ParsedChapter] = []
        var currentParas: [String] = []
        var currentSize = 0
        var chapterNum = 0

        for para in paragraphs {
            currentParas.append(para)
            currentSize += para.count

            if currentSize >= blockSize {
                chapterNum += 1
                chapters.append(
                    ParsedChapter(
                        title: "第 \(chapterNum) 節",
                        paragraphs: currentParas
                    ))
                currentParas = []
                currentSize = 0
            }
        }

        // 剩餘段落
        if !currentParas.isEmpty {
            chapterNum += 1
            chapters.append(
                ParsedChapter(
                    title: chapterNum == 1 ? bookTitle : "第 \(chapterNum) 節",
                    paragraphs: currentParas
                ))
        }

        return chapters
    }

    // MARK: - XHTML 生成

    /// 將單章的段落列表轉成完整 XHTML
    private static func buildXHTML(title: String, paragraphs: [String]) -> String {
        ReaderAdapterAssets.normalizedChapterHTML(
            title: title,
            paragraphs: paragraphs
        )
    }
}

#if false // DISABLED: TXT/HTML ingestion temporarily disabled pending CoreText migration

struct TXTBookIngester: BookIngesting {
    let text: String?
    let chapterInputs: [TXTToXHTMLConverter.ChapterInput]?
    let title: String
    let author: String
    let originalSourceURL: URL?

    init(text: String, title: String, author: String = "", originalSourceURL: URL? = nil) {
        self.text = text
        self.chapterInputs = nil
        self.title = title
        self.author = author
        self.originalSourceURL = originalSourceURL
    }

    init(
        chapters: [TXTToXHTMLConverter.ChapterInput],
        title: String,
        author: String = "",
        originalSourceURL: URL? = nil
    ) {
        self.text = nil
        self.chapterInputs = chapters
        self.title = title
        self.author = author
        self.originalSourceURL = originalSourceURL
    }

    func ingest() throws -> BookPackage {
        ReaderTelemetry.shared.log(
            "ingest_start",
            attributes: [
                "pipelineKind": BookPipelineKind.txt.rawValue,
                "title": title,
            ]
        )
        let converted: TXTToXHTMLConverter.ConvertedBook
        if let chapterInputs {
            converted = try TXTToXHTMLConverter.convert(chapters: chapterInputs, title: title)
        } else {
            converted = try TXTToXHTMLConverter.convert(text: text ?? "", title: title)
        }
        let package = TXTToXHTMLConverter.package(
            from: converted,
            title: title,
            author: author,
            pipelineKind: .txt,
            originalSourceURL: originalSourceURL
        )
        ReaderTelemetry.shared.log(
            "ingest_end",
            attributes: [
                "pipelineKind": BookPipelineKind.txt.rawValue,
                "spineCount": "\(package.manifest.spine.count)",
            ]
        )
        return package
    }
}

struct HTMLBookIngester: BookIngesting {
    let html: String
    let title: String
    let author: String
    let originalSourceURL: URL?

    init(html: String, title: String, author: String = "", originalSourceURL: URL? = nil) {
        self.html = html
        self.title = title
        self.author = author
        self.originalSourceURL = originalSourceURL
    }

    func ingest() throws -> BookPackage {
        let normalizedHTML = Self.normalizeHTML(title: title, html: html)
        let converted = try TXTToXHTMLConverter.convert(
            xhtmlChapters: [
                TXTToXHTMLConverter.XHTMLChapterInput(
                    title: title,
                    html: normalizedHTML,
                    href: "chapter_0.xhtml"
                )
            ],
            title: title,
            basePathPrefix: "html_xhtml"
        )
        return TXTToXHTMLConverter.package(
            from: converted,
            title: title,
            author: author,
            pipelineKind: .html,
            originalSourceURL: originalSourceURL
        )
    }

    private static func normalizeHTML(title: String, html: String) -> String {
        let cleanedBodyHTML = sanitizedBodyHTML(from: html)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedTitle = ReaderAdapterAssets.escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading: String
        if trimmedTitle.isEmpty || containsHeading(cleanedBodyHTML) {
            heading = ""
        } else {
            heading = "<h1>\(ReaderAdapterAssets.escapeHTML(trimmedTitle))</h1>\n"
        }

        return """
            <!DOCTYPE html>
            <html lang="zh-Hant">
            <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>\(escapedTitle)</title>
            </head>
            <body>
            <article id="reader-content">
            \(heading)\(cleanedBodyHTML)
            </article>
            </body>
            </html>
            """
    }

    private static func sanitizedBodyHTML(from html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else {
            return html
        }

        _ = try? doc.select("script, style, noscript, iframe, canvas, svg defs").remove()
        if let existingReaderContent = try? doc.select("#reader-content").first() {
            sanitizeInteractiveAttributes(in: existingReaderContent)
            return (try? existingReaderContent.html()) ?? html
        }

        let contentRoot =
            (try? doc.select("main, article, [role=main], .chapter-content, .content").first())
            ?? doc.body()

        guard let contentRoot else {
            return html
        }

        sanitizeInteractiveAttributes(in: contentRoot)
        return (try? contentRoot.html()) ?? html
    }

    private static func sanitizeInteractiveAttributes(in root: SwiftSoup.Element) {
        let elements = (try? root.getAllElements().array()) ?? [root]
        for element in elements {
            let attributes = element.getAttributes()?.asList() ?? []
            for attribute in attributes {
                let key = attribute.getKey()
                if key.lowercased().hasPrefix("on") {
                    _ = try? element.removeAttr(key)
                }
            }
            if let href = try? element.attr("href"),
                href.lowercased().hasPrefix("javascript:")
            {
                _ = try? element.removeAttr("href")
            }
        }
    }

    private static func containsHeading(_ html: String) -> Bool {
        html.range(of: #"<h[1-6][\s>]"#, options: .regularExpression) != nil
    }
}

#endif // DISABLED

// MARK: - 錯誤定義

enum TXTConvertError: LocalizedError {
    case encodingNotSupported
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .encodingNotSupported: return "無法偵測檔案編碼，請確認為 UTF-8、BIG5 或 GBK 格式"
        case .emptyContent: return "檔案內容為空"
        }
    }
}