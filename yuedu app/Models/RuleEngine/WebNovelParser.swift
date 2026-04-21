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

    private static let nextPageTitleRegex = try? NSRegularExpression(
        pattern: "^(下一页|下一頁|下页|下頁|next|next page|下一章|下一节|下一節)$",
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
            let titleRaw = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let document = try? SwiftSoup.parse(html, pageURL) else { return html.strippedHTML }

        _ = try? document.select("script,style,noscript,iframe,header,footer,nav").remove()
        let host = URL(string: pageURL)?.host?.lowercased() ?? ""

        for selector in hostMatchedSelectors(host: host, rules: hostContentRules) + genericContentSelectors {
            if let element = try? document.select(selector).first(),
               let text = extractedText(from: element),
               text.count >= 120 {
                return ChapterFetcher.shared.cleanChapterContent(text)
            }
        }

        var bestText = ""
        var bestScore = -Double.greatestFiniteMagnitude
        let candidates = (try? document.select("article,section,main,div").array()) ?? []

        for candidate in candidates {
            guard let text = extractedText(from: candidate), text.count >= 80 else { continue }
            let score = densityScore(for: candidate, text: text)
            if score > bestScore {
                bestScore = score
                bestText = text
            }
        }

        if bestText.count >= 120 {
            return ChapterFetcher.shared.cleanChapterContent(bestText)
        }

        let fallback = (try? document.body()?.text()) ?? html.strippedHTML
        return ChapterFetcher.shared.cleanChapterContent(fallback)
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
        // 優先：找 <p> 段落（標準結構站點）
        let paragraphs = ((try? element.select("p").array()) ?? [])
            .compactMap { try? $0.text() }
            .map { normalizeWhitespace($0) }
            .filter { $0.count >= 8 }

        if paragraphs.count >= 2 {
            return paragraphs.joined(separator: "\n")
        }

        // 中文小說常用 <br> 分段：把 outerHTML 做 block→\n 轉換再提取
        if let html = try? element.outerHtml() {
            var raw = html
            // 將 block-level 結束標籤和 <br> 轉成換行
            raw = raw.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            raw = raw.replacingOccurrences(
                of: "</(?:p|div|li|blockquote|section|article|dt|dd|h[1-6]|tr)>",
                with: "\n", options: .regularExpression)
            // 移除剩餘標籤
            raw = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // HTML 實體
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
            .replacingOccurrences(of: "[ \\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func densityScore(for element: Element, text: String) -> Double {
        let textLen = Double(text.count)
        let descendants = Double((try? element.getAllElements().size()) ?? 1)
        let punctuationCount = Double(text.unicodeScalars.filter {
            "，。！？；：,.!?;:".unicodeScalars.contains($0)
        }.count)
        let paragraphCount = Double((try? element.select("p,br,li").size()) ?? 0)

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
