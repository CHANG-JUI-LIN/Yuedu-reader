import Foundation
import SwiftSoup

struct WebChapterModel: Equatable {
    let title: String
    let url: String
    let index: Int
}

enum WebNovelParser {
    private static let genericContentSelectors: [String] = [
        "#content", "#chaptercontent", "#chapter-content", "#chapterContent",
        ".content", ".chapter-content", ".read-content", "#readcontent",
        "#read", ".read", "#bookContent", "#BookText", ".BookText",
        "#txt", ".txt", "article", "main", "[role=main]",
    ]

    private static let genericTOCSelectors: [String] = [
        "#list a[href]", ".listmain a[href]", ".chapter-list a[href]",
        ".catalog a[href]", "#catalog a[href]", "dl a[href]", "dd a[href]",
        ".book-list a[href]", "#chapterlist a[href]",
    ]

    private static let hostContentRules: [String: [String]] = [
        "qidian.com": ["#chapter-content", ".read-content"],
        "biquge": ["#content", "#chaptercontent", ".chapter-content"],
        "69shu": ["#content", ".txtnav"],
        "fanqie": [".muye-reader-content", "article"],
    ]

    private static let hostTOCRules: [String: [String]] = [
        "qidian.com": [".catalog-content-wrap a[href]", "#j-catalogWrap a[href]"],
        "biquge": ["#list a[href]", ".listmain a[href]", "dd a[href]"],
        "69shu": ["#catalog a[href]", ".catalog-list a[href]"],
        "fanqie": [".chapter-item a[href]", "a[href*='chapter']"],
    ]

    private static let chapterTitleRegex = try? NSRegularExpression(
        pattern: "(第\\s*[0-9零一二三四五六七八九十百千萬万兩两〇○]+\\s*[章節节回卷篇部]|chapter\\s*[0-9]+|ch\\.?\\s*[0-9]+)",
        options: [.caseInsensitive]
    )

    /// Text patterns for "next page" links.
    /// Excludes next-chapter link text (下一章/下一节/下一節, meaning "next chapter/section") — that links to a different
    /// chapter, not a continuation of the current one. Including it would cause
    /// fetchWebContent's while loop to concatenate the next entire chapter onto
    /// the current one, inflating single-chapter caches to 10+ chapters and 100+ pages.
    private static let nextPageTitleRegex = try? NSRegularExpression(
        pattern: "^(下一页|下一頁|下页|下頁|next|next page)$",
        options: [.caseInsensitive]
    )

    static func parseTOC(html: String, pageURL: String) -> [WebChapterModel] {
        guard let document = try? SwiftSoup.parse(html, pageURL) else { return [] }

        let host = URL(string: pageURL)?.host?.lowercased() ?? ""
        var anchors: [Element] = []

        for selector in hostMatchedSelectors(host: host, rules: hostTOCRules) + genericTOCSelectors {
            if let selected = try? document.select(selector).array(), !selected.isEmpty {
                anchors.append(contentsOf: selected)
            }
        }

        if anchors.isEmpty, let all = try? document.select("a[href]").array() {
            anchors = all
        }

        var models: [WebChapterModel] = []
        var seen = Set<String>()

        for anchor in anchors {
            guard let hrefRaw = try? anchor.attr("href"), !hrefRaw.isEmpty else { continue }
            let titleRaw = ReaderHTMLUtilities.displayText(
                fromHTMLFragment: ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !titleRaw.isEmpty, titleRaw.count <= 120 else { continue }

            let resolved = normalizedURL(try? anchor.attr("abs:href"), hrefRaw: hrefRaw, baseURL: pageURL)
            guard !resolved.isEmpty, resolved.hasPrefix("http") else { continue }
            guard isLikelyChapterLink(title: titleRaw, url: resolved) else { continue }

            let key = dedupeKey(title: titleRaw, url: resolved)
            if seen.contains(key) { continue }
            seen.insert(key)

            models.append(WebChapterModel(title: titleRaw, url: resolved, index: models.count))
        }

        if models.count < 3 {
            return []
        }

        let ordered = reorderByChapterNumberIfNeeded(models)
        return ordered.enumerated().map { idx, item in
            WebChapterModel(title: item.title, url: item.url, index: idx)
        }
    }

    static func parseTOCRefs(html: String, pageURL: String) -> [OnlineChapterRef] {
        parseTOC(html: html, pageURL: pageURL).map {
            OnlineChapterRef(index: $0.index, title: $0.title, url: $0.url)
        }
    }

    static func extractContent(html: String, pageURL: String) -> String {
        // One line per slow page, naming how its text was found: 書源檢查's CPU exceptions
        // (Crashlytics 084ef85c) were sampled in this call.
        var foundBy = "parse"
        return SourcePerfTrace.span("webNovel.content", "bytes=\(html.utf8.count) via=\(foundBy)", thresholdMs: 5) {
            extractContent(html: html, pageURL: pageURL, foundBy: &foundBy)
        }
    }

    private static func extractContent(html: String, pageURL: String, foundBy: inout String) -> String {
        guard let document = try? SwiftSoup.parse(html, pageURL) else { return html.strippedHTML }

        _ = try? document.select("script,style,noscript,iframe,header,footer,nav").remove()
        let host = URL(string: pageURL)?.host?.lowercased() ?? ""

        for selector in hostMatchedSelectors(host: host, rules: hostContentRules) + genericContentSelectors {
            if let element = try? document.select(selector).first(),
               let text = extractedText(from: element),
               text.count >= 120 {
                foundBy = selector
                return ChapterFetcher.shared.cleanChapterContent(text)
            }
        }

        let candidates = (try? document.select("article,section,main,div").array()) ?? []
        foundBy = "density candidates=\(candidates.count)"
        if let densest = densestText(among: candidates, in: document), densest.count >= 120 {
            return ChapterFetcher.shared.cleanChapterContent(densest)
        }

        foundBy = "body candidates=\(candidates.count)"
        let fallback = (try? document.body()?.text()) ?? html.strippedHTML
        return ChapterFetcher.shared.cleanChapterContent(fallback)
    }

    /// The text of the candidate scoring highest, among those with at least 80 characters.
    ///
    /// Each candidate used to walk its own subtree — its paragraphs, all its elements, its
    /// p/br/li — and join its paragraphs before it was scored, so nested wrappers made the
    /// scan grow with depth × size: a 28 KB page of 60 wrappers took 381 ms, 56 KB 1.5 s,
    /// 113 KB 5.8 s (simulator, 2026-10-20). `DensityIndex` walks the page once and only the
    /// winner's paragraphs are joined; every score, and so the winner, is as before.
    private static func densestText(among candidates: [Element], in document: Document) -> String? {
        enum Text {
            case paragraphs(Range<Int>)
            case whole(String)
        }
        let index = DensityIndex(document)
        var best: Text?
        var bestScore = -Double.greatestFiniteMagnitude
        for candidate in candidates {
            guard let subtree = index.subtree(of: candidate) else { continue }
            let paragraphs = index.paragraphs(in: subtree)
            let length: Int
            let punctuation: Int
            let text: Text
            if paragraphs.count >= 2 {
                length = index.joinedLength(of: paragraphs)
                punctuation = index.punctuation(in: paragraphs)
                text = .paragraphs(paragraphs)
            } else {
                guard let whole = unparagraphedText(of: candidate) else { continue }
                length = whole.count
                punctuation = punctuationCount(in: whole)
                text = .whole(whole)
            }
            guard length >= 80 else { continue }
            let score = densityScore(
                for: candidate,
                length: length,
                punctuation: punctuation,
                elements: subtree.count,
                paragraphMarks: index.paragraphMarks(in: subtree)
            )
            if score > bestScore {
                bestScore = score
                best = text
            }
        }
        switch best {
        case .paragraphs(let range): return index.joined(range)
        case .whole(let text): return text
        case nil: return nil
        }
    }

    /// What the density scan scores, for every element of a page, from one walk of it. An
    /// element and its descendants are one run of the walk's order, so each of its counts is
    /// the difference of two running totals.
    private struct DensityIndex {
        /// Each element's run of the walk: itself, then its descendants.
        private var runs: [ObjectIdentifier: Range<Int>] = [:]
        /// p, br and li elements before each position of the walk.
        private var marksBefore: [Int] = [0]
        /// The paragraphs `extractedText` takes — `p` elements with at least 8 characters once
        /// whitespace is normalized — in page order, with each one's walk position.
        private var paragraphPositions: [Int] = []
        private var paragraphTexts: [String] = []
        private var lengthBefore: [Int] = [0]
        private var punctuationBefore: [Int] = [0]

        init(_ root: Element) {
            enum Step {
                case enter(Element)
                case leave(Element, start: Int)
            }
            var position = 0
            var steps: [Step] = [.enter(root)]
            while let step = steps.popLast() {
                switch step {
                case .enter(let element):
                    let tag = element.tagNameNormal()
                    marksBefore.append(marksBefore[position] + (tag == "p" || tag == "br" || tag == "li" ? 1 : 0))
                    if tag == "p", let raw = try? element.text() {
                        let text = WebNovelParser.normalizeWhitespace(raw)
                        if text.count >= 8 {
                            paragraphPositions.append(position)
                            paragraphTexts.append(text)
                            lengthBefore.append(lengthBefore[lengthBefore.count - 1] + text.count)
                            punctuationBefore.append(punctuationBefore[punctuationBefore.count - 1] + WebNovelParser.punctuationCount(in: text))
                        }
                    }
                    steps.append(.leave(element, start: position))
                    position += 1
                    for child in element.children().array().reversed() {
                        steps.append(.enter(child))
                    }
                case .leave(let element, let start):
                    runs[ObjectIdentifier(element)] = start..<position
                }
            }
        }

        func subtree(of element: Element) -> Range<Int>? {
            runs[ObjectIdentifier(element)]
        }

        /// Indices into the paragraphs, of those inside `subtree`.
        func paragraphs(in subtree: Range<Int>) -> Range<Int> {
            firstParagraph(atOrAfter: subtree.lowerBound)..<firstParagraph(atOrAfter: subtree.upperBound)
        }

        /// Characters in the paragraphs joined by line breaks, which never merge with a neighbour.
        func joinedLength(of paragraphs: Range<Int>) -> Int {
            lengthBefore[paragraphs.upperBound] - lengthBefore[paragraphs.lowerBound] + paragraphs.count - 1
        }

        func punctuation(in paragraphs: Range<Int>) -> Int {
            punctuationBefore[paragraphs.upperBound] - punctuationBefore[paragraphs.lowerBound]
        }

        func paragraphMarks(in subtree: Range<Int>) -> Int {
            marksBefore[subtree.upperBound] - marksBefore[subtree.lowerBound]
        }

        func joined(_ paragraphs: Range<Int>) -> String {
            paragraphTexts[paragraphs].joined(separator: "\n")
        }

        private func firstParagraph(atOrAfter position: Int) -> Int {
            var low = 0
            var high = paragraphPositions.count
            while low < high {
                let middle = (low + high) / 2
                if paragraphPositions[middle] < position { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    static func extractNextPageURL(html: String, currentURL: String) -> String {
        guard let document = try? SwiftSoup.parse(html, currentURL) else { return "" }

        if let nextLink = try? document.select("link[rel=next]").first(),
           let href = try? nextLink.attr("abs:href"),
           !href.isEmpty {
            return href
        }

        if let anchors = try? document.select("a[href]").array() {
            for anchor in anchors {
                let text = ((try? anchor.text()) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !text.isEmpty else { continue }
                if let regex = nextPageTitleRegex,
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                   let href = try? anchor.attr("abs:href"),
                   !href.isEmpty,
                   href != currentURL {
                    return href
                }
            }
        }

        return ChapterFetcher.shared.extractNextPageURL(
            html: html,
            currentURL: currentURL,
            baseURL: currentURL
        )
    }

    private static func hostMatchedSelectors(host: String, rules: [String: [String]]) -> [String] {
        for (key, selectors) in rules where host.contains(key) {
            return selectors
        }
        return []
    }

    private static func extractedText(from element: Element) -> String? {
        let paragraphs = ((try? element.select("p").array()) ?? [])
            .compactMap { try? $0.text() }
            .map { normalizeWhitespace($0) }
            .filter { $0.count >= 8 }

        if paragraphs.count >= 2 {
            return paragraphs.joined(separator: "\n")
        }
        return unparagraphedText(of: element)
    }

    /// An element's text when it has fewer than two paragraphs: its markup with line breaks kept.
    private static func unparagraphedText(of element: Element) -> String? {
        if let html = try? element.outerHtml() {
            var raw = html
            raw = raw.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            raw = raw.replacingOccurrences(
                of: "</(?:p|div|li|blockquote|section|article|dt|dd|h[1-6]|tr)>",
                with: "\n", options: .regularExpression)
            raw = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            raw = raw.replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            let normalized = normalizeWhitespace(raw)
            if !normalized.isEmpty { return normalized }
        }

        if let text = try? element.text() {
            let normalized = normalizeWhitespace(text)
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\r\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "[ \\x{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let densityPunctuation = Set("，。！？；：,.!?;:".unicodeScalars)

    private static func punctuationCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { densityPunctuation.contains($1) ? $0 + 1 : $0 }
    }

    /// `elements` counts the element itself with its descendants; `paragraphMarks` its p, br and li.
    private static func densityScore(
        for element: Element,
        length: Int,
        punctuation: Int,
        elements: Int,
        paragraphMarks: Int
    ) -> Double {
        let textLen = Double(length)
        let descendants = Double(elements)
        let punctuationCount = Double(punctuation)
        let paragraphCount = Double(paragraphMarks)

        let classId = (((try? element.className()) ?? "") + " " + element.id())
            .lowercased()

        var score = textLen / max(1, descendants)
        score += punctuationCount * 1.8
        score += paragraphCount * 4
        score += log(max(1, textLen))

        if classId.range(of: "nav|menu|header|footer|sidebar|ad|banner|comment|recommend|related|copyright|toolbar|toc", options: .regularExpression) != nil {
            score *= 0.35
        }
        if classId.range(of: "content|chapter|read|article|text|body|novel", options: .regularExpression) != nil {
            score *= 1.35
        }

        return score
    }

    private static func isLikelyChapterLink(title: String, url: String) -> Bool {
        let lowerTitle = title.lowercased()
        if lowerTitle.contains("返回") || lowerTitle.contains("目录") || lowerTitle.contains("目錄") ||
            lowerTitle.contains("首页") || lowerTitle.contains("首頁") {
            return false
        }

        if let regex = chapterTitleRegex,
           regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil {
            return true
        }

        let lowerURL = url.lowercased()
        if lowerURL.contains("chapter") || lowerURL.contains("read") {
            return true
        }
        if lowerURL.range(of: "/\\d+[./_-]", options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func dedupeKey(title: String, url: String) -> String {
        let normalizedTitle = title
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return normalizedTitle + "|" + url.lowercased()
    }

    private static func normalizedURL(_ absHref: String?, hrefRaw: String, baseURL: String) -> String {
        if let absHref, !absHref.isEmpty {
            return absHref
        }
        return RuleEngine.resolveURL(hrefRaw, base: baseURL)
    }

    private static func reorderByChapterNumberIfNeeded(_ items: [WebChapterModel]) -> [WebChapterModel] {
        let withOrder = items.map { item -> (WebChapterModel, Int?) in
            (item, extractOrder(from: item.title))
        }
        let orderedCount = withOrder.filter { $0.1 != nil }.count
        if orderedCount < max(3, items.count / 2) {
            return items
        }
        return withOrder.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.0.index < rhs.0.index
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.0.index < rhs.0.index
            }
        }.map { $0.0 }
    }

    private static func extractOrder(from title: String) -> Int? {
        if let regex = try? NSRegularExpression(
            pattern: "第\\s*([0-9]+)\\s*[章節节回卷篇部]",
            options: [.caseInsensitive]
        ),
        let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
        let range = Range(match.range(at: 1), in: title),
        let value = Int(title[range]) {
            return value
        }

        if let regex = try? NSRegularExpression(
            pattern: "chapter\\s*([0-9]+)",
            options: [.caseInsensitive]
        ),
        let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
        let range = Range(match.range(at: 1), in: title),
        let value = Int(title[range]) {
            return value
        }

        return nil
    }
}
