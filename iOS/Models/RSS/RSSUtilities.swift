import Foundation
import SwiftSoup

struct RSSFeedFetchMetadata: Codable, Equatable {
    var etag: String?
    var lastModified: String?
    var lastFetchedAt: Date?
}

struct RSSFeedInfo: Codable, Equatable {
    var title: String?
    var homepageURL: String?
    var faviconURL: String?
}

enum RSSFeedResponse {
    case notModified
    case updated(items: [RSSItem], metadata: RSSFeedFetchMetadata, feedInfo: RSSFeedInfo?)
}

enum RSSRequestFactory {
    static func feedRequest(for source: RSSSource, metadata: RSSFeedFetchMetadata?) -> URLRequest? {
        guard let url = URL(string: source.url)?.upgradedToHTTPS() else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let etag = metadata?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = metadata?.lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }
}

enum RSSFaviconResolver {
    static func faviconURL(for source: RSSSource, fallbackURL: URL? = nil) -> URL? {
        if let faviconURL = source.displayFaviconURL,
           let url = normalizedURL(faviconURL, relativeTo: homepageURL(for: source, fallbackURL: fallbackURL)) {
            return url
        }

        guard let homepageURL = homepageURL(for: source, fallbackURL: fallbackURL) else {
            return nil
        }
        return defaultFaviconURL(for: homepageURL)
    }

    static func candidateURLs(for source: RSSSource, fallbackURL: URL? = nil) async -> [URL] {
        var candidates: [URL] = []
        let homepageURL = homepageURL(for: source, fallbackURL: fallbackURL)

        if let explicit = source.displayFaviconURL,
           let url = normalizedURL(explicit, relativeTo: homepageURL),
           shouldUseIconURL(url) {
            candidates.append(url)
        }

        if let homepageURL {
            candidates.append(contentsOf: await htmlIconURLs(for: homepageURL))
            if let defaultURL = defaultFaviconURL(for: homepageURL) {
                candidates.append(defaultURL)
            }
        }

        return deduplicate(candidates.filter(shouldUseIconURL))
    }

    static func htmlIconURLs(in html: String, pageURL: URL) -> [URL] {
        guard let document = try? SwiftSoup.parse(html, pageURL.absoluteString),
              let links = try? document.select("link[rel][href]") else {
            return []
        }

        var standardIcons: [URL] = []
        var touchIcons: [URL] = []

        for link in links.array() {
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            let href = ((try? link.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty,
                  let url = normalizedURL(href, relativeTo: pageURL),
                  shouldUseIconURL(url) else {
                continue
            }

            let relValues = Set(rel.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init))
            if relValues.contains("icon") || relValues.contains("shortcut") {
                standardIcons.append(url)
            } else if relValues.contains("apple-touch-icon") || relValues.contains("apple-touch-icon-precomposed") {
                touchIcons.append(url)
            }
        }

        return deduplicate(standardIcons + touchIcons)
    }

    private static func htmlIconURLs(for homepageURL: URL) async -> [URL] {
        var request = URLRequest(url: homepageURL.upgradedToHTTPS())
        request.timeoutInterval = 10
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return []
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return []
            }
            return htmlIconURLs(in: html, pageURL: homepageURL)
        } catch {
            return []
        }
    }

    private static func homepageURL(for source: RSSSource, fallbackURL: URL?) -> URL? {
        if let homepageURL = source.homepageURL,
           let url = URL(string: homepageURL)?.upgradedToHTTPS(),
           url.scheme != nil,
           url.host != nil {
            return url
        }

        let candidate = fallbackURL?.upgradedToHTTPS() ?? URL(string: source.url)?.upgradedToHTTPS()
        guard let url = candidate,
              url.host != nil else {
            return nil
        }
        return URL(string: "https://\(url.host!)/")
    }

    private static func defaultFaviconURL(for homepageURL: URL) -> URL? {
        guard let host = homepageURL.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    private static func normalizedURL(_ value: String, relativeTo baseURL: URL?) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url.upgradedToHTTPS()
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.upgradedToHTTPS()
    }

    private static func shouldUseIconURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "svg"
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = url.absoluteString
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

enum RSSOPMLParserError: LocalizedError {
    case noSources

    var errorDescription: String? {
        switch self {
        case .noSources:
            return localized("OPML 中沒有找到 RSS 訂閱源")
        }
    }
}

enum RSSOPMLParser {
    static func parse(data: Data) throws -> [RSSSource] {
        let parser = RSSOPMLXMLParser()
        let sources = parser.parse(data: data)
        if sources.isEmpty {
            throw RSSOPMLParserError.noSources
        }
        return sources
    }
}

private final class RSSOPMLXMLParser: NSObject, XMLParserDelegate {
    private var sources: [RSSSource] = []
    private var seenURLs = Set<String>()
    private var folderStack: [String?] = []

    func parse(data: Data) -> [RSSSource] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return sources
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let xmlURL = firstAttribute(["xmlUrl", "xmlurl", "url"], in: attributeDict)
        let text = firstAttribute(["title", "text"], in: attributeDict)

        if let xmlURL, !xmlURL.isEmpty, !seenURLs.contains(xmlURL) {
            let name = text ?? xmlURL
            let htmlURL = firstAttribute(["htmlUrl", "htmlurl"], in: attributeDict)
            let currentFolder = folderStack.reversed().first(where: { $0 != nil }) ?? nil
            sources.append(RSSSource(
                name: RSSContentSanitizer.cleanText(name),
                url: xmlURL,
                homepageURL: htmlURL,
                sortOrder: sources.count,
                sourceGroup: currentFolder
            ))
            seenURLs.insert(xmlURL)
        }

        if let text, !text.isEmpty, xmlURL == nil || xmlURL!.isEmpty {
            folderStack.append(RSSContentSanitizer.cleanText(text))
        } else {
            folderStack.append(nil)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline", !folderStack.isEmpty else { return }
        folderStack.removeLast()
    }

    private func firstAttribute(_ names: [String], in attributes: [String: String]) -> String? {
        for name in names {
            if let value = attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        let lowerNames = Set(names.map { $0.lowercased() })
        return attributes.first { lowerNames.contains($0.key.lowercased()) }?.value
    }
}

enum RSSOPMLExporter {
    static func export(sources: [RSSSource]) -> String {
        let groups = Dictionary(grouping: sources.sorted(by: { $0.sortOrder < $1.sortOrder })) { source in
            source.sourceGroup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? source.sourceGroup!
                : nil
        }
        var outlines: [String] = []
        if let rootSources = groups[nil] {
            for source in rootSources {
                outlines.append("    \(outlineXML(for: source))")
            }
        }
        for (folderName, folderSources) in groups where folderName != nil {
            outlines.append("    <outline text=\"\(escape(folderName!))\" title=\"\(escape(folderName!))\">")
            for source in folderSources {
                outlines.append("      \(outlineXML(for: source))")
            }
            outlines.append("    </outline>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>yuedu RSS</title>
          </head>
          <body>
        \(outlines.joined(separator: "\n"))
          </body>
        </opml>
        """
    }

    private static func outlineXML(for source: RSSSource) -> String {
        let attrs = [
            #"text="\#(escape(source.name))""#,
            #"title="\#(escape(source.name))""#,
            #"type="rss""#,
            #"xmlUrl="\#(escape(source.url))""#,
            source.homepageURL.map { #"htmlUrl="\#(escape($0))""# }
        ].compactMap { $0 }.joined(separator: " ")
        return "<outline \(attrs) />"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct RSSExtractedArticle: Equatable {
    var title: String
    var html: String
    var text: String
}

enum RSSArticleExtractor {
    static func extract(from data: Data, baseURL: URL) -> RSSExtractedArticle {
        let html = String(data: data, encoding: .utf8) ?? ""
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else {
            let text = RSSContentSanitizer.cleanText(html)
            return RSSExtractedArticle(title: baseURL.absoluteString, html: RSSArticleHTMLSanitizer.paragraphsHTML(from: text), text: text)
        }

        _ = try? document.select(RSSArticleHTMLSanitizer.noiseSelector).remove()

        let title = clean((try? document.select("article h1, main h1, h1").first()?.text())
                          ?? (try? document.title())
                          ?? baseURL.absoluteString)

        let root = (try? document.select("article").first())
            ?? (try? document.select("main").first())
            ?? document.body()
            ?? document

        let rawHTML = (try? root.html()) ?? ""
        let cleanHTML = RSSArticleHTMLSanitizer.sanitizedHTML(rawHTML, baseURL: baseURL)

        let textRoot = (try? SwiftSoup.parseBodyFragment(cleanHTML, baseURL.absoluteString))?.body()
        let paragraphs = ((try? textRoot?.select("p, h2, h3, li, blockquote").array()) ?? [])
            .compactMap { try? $0.text() }
            .map(clean)
            .filter { $0.count >= 6 }

        let text: String
        if paragraphs.isEmpty {
            text = clean((try? textRoot?.text()) ?? "")
        } else {
            text = paragraphs.joined(separator: "\n\n")
        }

        return RSSExtractedArticle(title: title, html: cleanHTML, text: text)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RSSArticleHTMLSanitizer {
    static let noiseSelector = [
        "script", "style", "noscript", "svg", "iframe", "object", "embed",
        "nav", "header", "aside", "address", "time", "form", "button", "input",
        ".ad", ".ads", ".advert", ".advertisement",
        "[class*=advert]", "[id*=advert]", "[data-ad]", "[data-ad-unit]"
    ].joined(separator: ", ")

    static func hasSubstantialStructuredContent(_ html: String, fallbackText: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let body = try? SwiftSoup.parseBodyFragment(trimmed).body() else {
            return false
        }

        _ = try? body.select(noiseSelector).remove()
        let blockCount = ((try? body.select("p, figure, blockquote, ul, ol, h2, h3, footer").array()) ?? [])
            .filter { !plainText($0).isEmpty || ((try? $0.select("img").isEmpty()) == false) }
            .count
        let imageCount = ((try? body.select("img").array()) ?? []).count
        let textCount = plainText(body).count
        let fallbackCount = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).count

        if blockCount >= 4, textCount >= max(260, fallbackCount) {
            return true
        }
        return imageCount > 0 && blockCount >= 2 && textCount >= 180
    }

    static func articleBodyHTML(_ html: String, fallbackText: String, baseURL: URL?) -> String {
        let sanitized = sanitizedHTML(html, baseURL: baseURL)
        let fallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return paragraphsHTML(from: fallback)
        }

        let normalized = normalizeBodyHTML(sanitized)
        if !normalized.isEmpty {
            return normalized
        }

        let text = plainText(fromHTML: sanitized)
        let paragraphText = text.isEmpty ? fallback : text
        return paragraphsHTML(from: paragraphText)
    }

    static func sanitizedHTML(_ html: String, baseURL: URL?) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        do {
            let denoised = removeNoise(from: trimmed, baseURL: baseURL)
            let whitelist = try Whitelist.none()
                .addTags(
                    "article", "section", "div", "footer",
                    "p", "a", "img", "figure", "figcaption", "blockquote",
                    "h2", "h3", "ul", "ol", "li", "pre", "code",
                    "strong", "em", "b", "i", "span", "small", "sup", "sub", "br", "hr"
                )
                .addAttributes("a", "href", "title")
                .addAttributes("img", "src", "alt", "title", "width", "height")
                .addAttributes("blockquote", "cite")
                .addProtocols("a", "href", "http", "https", "mailto", "tel")
                .addProtocols("img", "src", "http", "https")
                .addProtocols("blockquote", "cite", "http", "https")
            let cleaned = try SwiftSoup.clean(denoised, baseURL?.absoluteString ?? "", whitelist) ?? ""
            return removeAdMarkers(fromHTML: cleaned)
                .replacingOccurrences(of: #"(?i)<p>\s*</p>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .upgradingHTTPURLsInHTML()
        } catch {
            return paragraphsHTML(from: RSSContentSanitizer.cleanText(trimmed))
        }
    }

    static func paragraphsHTML(from text: String) -> String {
        let normalized = removeAdMarkers(fromText: normalizePlainText(text))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var chunks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if chunks.count <= 1, normalized.count > 180 {
            chunks = paragraphChunks(from: normalized)
        }

        let paragraphs = chunks.isEmpty ? [normalized] : chunks
        return paragraphs
            .map { "<p>\(escape($0))</p>" }
            .joined()
    }

    private static func normalizeBodyHTML(_ html: String) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else {
            return html
        }

        let normalized = normalizeNodes(body.getChildNodes())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? html : normalized
    }

    private static func normalizeNodes(_ nodes: [Node]) -> String {
        var output: [String] = []
        var looseHTML = ""
        var looseText = ""

        func flushLoose() {
            let text = removeAdMarkers(fromText: normalizePlainText(looseText))
            let html = removeAdMarkers(fromHTML: looseHTML).trimmingCharacters(in: .whitespacesAndNewlines)

            defer {
                looseHTML = ""
                looseText = ""
            }

            guard !text.isEmpty else { return }

            if html.contains("<") {
                output.append("<p>\(html)</p>")
            } else {
                output.append(paragraphsHTML(from: text))
            }
        }

        func appendLooseText(_ text: String) {
            let normalized = normalizePlainText(text)
            guard !normalized.isEmpty else { return }
            if !looseHTML.isEmpty {
                looseHTML += " "
            }
            looseHTML += escape(normalized)
            looseText += " " + normalized
        }

        for node in nodes {
            if let textNode = node as? SwiftSoup.TextNode {
                appendLooseText(textNode.getWholeText())
                continue
            }

            guard let element = node as? SwiftSoup.Element else { continue }
            let tag = element.tagName().lowercased()

            if tag == "br" {
                flushLoose()
                continue
            }

            if inlineTags.contains(tag), let html = try? element.outerHtml() {
                if !looseHTML.isEmpty {
                    looseHTML += " "
                }
                looseHTML += removeAdMarkers(fromHTML: html)
                looseText += " " + ((try? element.text()) ?? "")
                continue
            }

            if containerTags.contains(tag) {
                flushLoose()
                let children = normalizeNodes(element.getChildNodes())
                if tag == "footer", !children.isEmpty {
                    output.append("<footer>\(children)</footer>")
                } else {
                    output.append(children)
                }
                continue
            }

            if blockTags.contains(tag), let html = try? element.outerHtml() {
                flushLoose()
                let cleaned = removeAdMarkers(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty, !isStandaloneAdLabel(plainText(element)) {
                    output.append(cleaned)
                }
                continue
            }

            if let html = try? element.outerHtml() {
                if !looseHTML.isEmpty {
                    looseHTML += " "
                }
                looseHTML += removeAdMarkers(fromHTML: html)
                looseText += " " + ((try? element.text()) ?? "")
            }
        }

        flushLoose()
        return output.joined()
    }

    private static let inlineTags: Set<String> = [
        "a", "strong", "em", "b", "i", "code", "span", "small", "sup", "sub"
    ]

    private static let blockTags: Set<String> = [
        "p", "h2", "h3", "ul", "ol", "li", "blockquote", "figure", "figcaption", "pre", "hr", "img"
    ]

    private static let containerTags: Set<String> = ["article", "section", "div", "footer"]

    private static func removeNoise(from html: String, baseURL: URL?) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html, baseURL?.absoluteString ?? "").body() else {
            return html
        }

        _ = try? body.select(noiseSelector).remove()
        for element in (try? body.select("p, div, span").array()) ?? [] {
            if isStandaloneAdLabel(plainText(element)) {
                try? element.remove()
            }
        }

        return (try? body.html()) ?? html
    }

    private static func plainText(_ element: SwiftSoup.Element) -> String {
        normalizePlainText((try? element.text()) ?? "")
    }

    private static func plainText(fromHTML html: String) -> String {
        if let document = try? SwiftSoup.parseBodyFragment(html),
           let text = try? document.text() {
            return removeAdMarkers(fromText: normalizePlainText(text))
        }
        return RSSContentSanitizer.cleanText(html)
    }

    private static func isStandaloneAdLabel(_ text: String) -> Bool {
        let normalized = normalizePlainText(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        return ["廣告", "广告", "advertisement", "advertisements", "ad"].contains(normalized)
    }

    private static func removeAdMarkers(fromHTML html: String) -> String {
        removeAdMarkers(fromText: html)
            .replacingOccurrences(
                of: #"(?is)<(p|div|span)[^>]*>\s*(?:廣告|广告|advertisement|ad)\s*</\1>"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func removeAdMarkers(fromText text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?i)^\s*(?:廣告|广告|advertisement)\s+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)([。！？!?；;\s>])\s*(?:廣告|广告|advertisement)\s+"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)([。！？!?；;])\s*(?:廣告|广告|advertisement)(?=[\p{Han}A-Z])"#,
                with: "$1",
                options: .regularExpression
            )
    }

    private static func paragraphChunks(from text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let softBreaks = Set("。！？!?；;")
        let hardBreaks = Set(".")

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
        }

        for character in text {
            current.append(character)

            if softBreaks.contains(character), current.count >= 80 {
                flush()
            } else if hardBreaks.contains(character), current.count >= 140 {
                flush()
            } else if current.count >= 260 {
                flush()
            }
        }

        flush()
        return chunks
    }

    private static func normalizePlainText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum RSSArticleReaderMode: String, CaseIterable, Identifiable {
    case feed
    case reader

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed:
            return localized("摘要")
        case .reader:
            return localized("Reader View")
        }
    }
}

struct RSSArticleHTMLDocument: Equatable {
    var title: String
    var html: String
    var baseURL: URL?
}

enum RSSArticleHTMLRenderer {
    static func render(
        article: RSSArticleRecord,
        source: RSSSource?,
        mode: RSSArticleReaderMode,
        bodyHTML: String,
        fallbackText: String,
        sourceFaviconURLs: [URL] = [],
        isLoading: Bool,
        errorMessage: String?
    ) -> RSSArticleHTMLDocument {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localized("暫無資料")
            : article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = source?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byline = author?.isEmpty == false ? author! : ""

        let articleURL = URL(string: article.link)?.upgradedToHTTPS()
        let cleanFallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = RSSArticleHTMLSanitizer.articleBodyHTML(
            bodyHTML,
            fallbackText: cleanFallback.isEmpty ? article.link : cleanFallback,
            baseURL: articleURL
        )
        let loadingHTML = isLoading ? #"<div class="readerState">"# + escape(localized("正在抓取全文…")) + "</div>" : ""
        let errorHTML = errorMessage.map { #"<div class="readerError">"# + escape($0) + "</div>" } ?? ""
        let sourceLabel = escape(sourceName?.isEmpty == false ? sourceName! : mode.title)
        let sourceURL = source.flatMap { URL(string: $0.homepageURL ?? $0.url) } ?? articleURL
        let sourceHref = sourceURL.map { linkAttributes($0.absoluteString) } ?? ""
        let preferredLink = articleURL?.absoluteString ?? ""
        let preferredLinkAttributes = preferredLink.isEmpty ? "" : linkAttributes(preferredLink)
        let dateText = article.pubDate.map { displayDateFormatter.string(from: $0) } ?? ""
        let feedLinkLine = #"<a class="feedlink"\#(sourceHref)>\#(sourceLabel)</a>"#
        let bylineHTML = byline.isEmpty ? "" : "<br />\(escape(byline))"
        let datelineHTML = dateText.isEmpty ? "" : #"<div class="articleDateline"><a\#(preferredLinkAttributes)>\#(escape(dateText))</a></div>"#
        let avatarHTML = sourceAvatarHTML(
            for: source,
            fallbackURL: articleURL,
            faviconURLs: sourceFaviconURLs
        )
        let baseURL = articleURL?.deletingLastPathComponent()
        let baseTag = baseURL.map { #"<base href="\#(escape($0.absoluteString))">"# } ?? ""

        let articleTemplate = """
        <div class="headerContainer">
          <table class="headerTable">
            <tbody>
              <tr>
                <td class="header leftAlign">\(feedLinkLine)\(bylineHTML)</td>
                <td class="header rightAlign avatar">\(avatarHTML)</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="articleTitle"><h1><a\(preferredLinkAttributes)>\(escape(title))</a></h1></div>
        \(datelineHTML)
        \(loadingHTML)
        \(errorHTML)
        <div id="bodyContainer" class="articleBody rss-reader-body">\(body)</div>
        """

        let html = """
        <!doctype html>
        <html dir="auto">
        <head>
          <meta charset="utf-8">
          <title>\(escape(title))</title>
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          \(baseTag)
          <style>\(articleStyleSheet)</style>
        </head>
        <body>
          \(articleTemplate)
          \(readerScript)
        </body>
        </html>
        """

        return RSSArticleHTMLDocument(
            title: title,
            html: html,
            baseURL: baseURL
        )
    }

    private static var displayDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static func linkAttributes(_ urlString: String) -> String {
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return #" href="\#(escape(urlString))""#
    }

    private static func sourceAvatarHTML(
        for source: RSSSource?,
        fallbackURL: URL?,
        faviconURLs: [URL]
    ) -> String {
        guard let source else {
            return ""
        }

        var urls = faviconURLs
        if let fallback = RSSFaviconResolver.faviconURL(for: source, fallbackURL: fallbackURL) {
            urls.append(fallback)
        }

        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            guard !result.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
            result.append(url)
        }

        guard let firstURL = uniqueURLs.first else {
            return ""
        }

        let fallbacks = uniqueURLs
            .dropFirst()
            .map { escapeJavaScriptString($0.absoluteString) }
            .joined(separator: ",")
        let fallbackJSON = "[\(fallbacks)]"
        return #"<img id="nnwImageIcon" src="\#(escape(firstURL.absoluteString))" height="48" width="48" data-fallback-srcs="\#(escape(fallbackJSON))" onerror="window.yueduFallbackImage(this)" />"#
    }

    private static func escapeJavaScriptString(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    // Structure and class names follow NetNewsWire's MIT-licensed article renderer
    // (`ArticleRenderer`, `template.html`, `page.html`, and `stylesheet.css`).
    private static var articleStyleSheet: String {
        """
        :root {
          color-scheme: light dark;
          font: -apple-system-body;
          font-size: 17px;
          --body-background-color: #ffffff;
          --body-text-color: #111111;
          --secondary-text-color: #777777;
          --divider-color: rgba(0, 0, 0, 0.14);
          --primary-accent-color: #086AEE;
          --error-color: #c62828;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --body-background-color: #111111;
            --body-text-color: #eeeeee;
            --secondary-text-color: #9b9b9b;
            --divider-color: rgba(255, 255, 255, 0.18);
            --error-color: #ff6b6b;
          }
        }
        html {
          background-color: var(--body-background-color);
          color: var(--body-text-color);
          -webkit-text-size-adjust: none;
        }
        body {
          margin-top: 3px;
          margin-bottom: 20px;
          margin-left: auto;
          margin-right: auto;
          max-width: 44em;
          padding-left: 20px;
          padding-right: 20px;
          padding-bottom: 120px;
          word-wrap: break-word;
          word-break: break-word;
          -webkit-hyphens: auto;
          overflow-x: hidden;
        }
        a {
          color: var(--primary-accent-color);
          text-decoration-color: var(--primary-accent-color);
          text-decoration-thickness: 0.055em;
          text-underline-offset: 0.16em;
        }
        img,
        video {
          height: auto;
          max-width: 100%;
        }
        figure {
          margin: 0 0 1.25em;
        }
        figcaption,
        small {
          color: var(--secondary-text-color);
          display: block;
          font-size: 0.85em;
          line-height: 1.45em;
          margin-top: 0.45em;
        }
        .headerContainer {
          margin-bottom: 0.5em;
        }
        .headerTable {
          height: 68px;
          width: 100%;
        }
        .header {
          color: var(--secondary-text-color);
          font-size: 0.95em;
          line-height: 1.35em;
          vertical-align: middle;
        }
        .leftAlign {
          text-align: left;
        }
        .rightAlign {
          text-align: right;
        }
        .avatar {
          width: 58px;
        }
        #nnwImageIcon {
          background: rgba(128, 128, 128, 0.12);
          border-radius: 8px;
          object-fit: cover;
        }
        .feedlink {
          font-weight: bold;
        }
        .articleTitle {
          border-top: 1px solid var(--divider-color);
          padding-top: 1.1em;
        }
        .articleTitle h1 {
          font-size: 1.5rem;
          line-height: 1.16em;
          margin: 0 0 0.28em;
        }
        .articleTitle h1 a {
          color: var(--body-text-color);
          text-decoration: none;
        }
        .articleDateline {
          color: var(--secondary-text-color);
          font-weight: bold;
          font-variant-caps: all-small-caps;
          letter-spacing: 0.025em;
          margin-bottom: 5px;
        }
        .articleDateline a {
          color: var(--secondary-text-color);
          text-decoration: none;
        }
        .articleBody {
          font-size: 1em;
          line-height: 1.6em;
          margin-top: 20px;
        }
        .articleBody p,
        .articleBody blockquote,
        .articleBody ul,
        .articleBody ol,
        .articleBody pre {
          margin-top: 0;
          margin-bottom: 1.45em;
        }
        .articleBody footer {
          color: var(--body-text-color);
          margin-top: 2em;
        }
        .articleBody footer p {
          margin-bottom: 1.15em;
        }
        .articleBody blockquote {
          border-left: 0.22em solid var(--divider-color);
          color: var(--secondary-text-color);
          margin-left: 0;
          padding-left: 1em;
        }
        .articleBody h2,
        .articleBody h3 {
          line-height: 1.28em;
          margin: 1.35em 0 0.65em;
        }
        .articleBody img {
          display: block;
          margin: 0.85em auto;
        }
        .articleBody table {
          display: block;
          max-width: 100%;
          overflow-x: auto;
        }
        pre,
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
          white-space: pre-wrap;
        }
        .readerState {
          color: var(--secondary-text-color);
          font-size: 0.875em;
          margin: 1em 0;
        }
        .readerError {
          color: var(--error-color);
          font-size: 0.875em;
          margin: 1em 0;
        }
        ::selection {
          background: rgba(8, 106, 238, 0.24);
        }
        .x-netnewswire-hide,
        .x-netnewswire-ad,
        .feedflare,
        .sharedaddy,
        .sharedaddy.sd-sharing-enabled {
          display: none !important;
        }
        """
    }

    private static var readerScript: String {
        """
        <script>
        (function() {
          function postScrollY() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollPosition) {
              window.webkit.messageHandlers.scrollPosition.postMessage(window.scrollY || 0);
            }
          }
          var scrollTimer = null;
          window.addEventListener('scroll', function() {
            if (scrollTimer) { window.clearTimeout(scrollTimer); }
            scrollTimer = window.setTimeout(postScrollY, 180);
          }, { passive: true });
          window.yueduRestoreScrollY = function(y) {
            window.requestAnimationFrame(function() {
              window.scrollTo(0, Math.max(0, Number(y) || 0));
              postScrollY();
            });
          };
          window.yueduFind = function(encodedQuery, backwards) {
            var query = "";
            try {
              query = decodeURIComponent(Array.prototype.map.call(atob(encodedQuery), function(c) {
                return "%" + ("00" + c.charCodeAt(0).toString(16)).slice(-2);
              }).join(""));
            } catch (e) {
              query = "";
            }
            if (!query) { return false; }
            return window.find(query, false, !!backwards, true, false, false, false);
          };
          window.yueduFallbackImage = function(image) {
            if (!image) { return; }
            var index = Number(image.getAttribute("data-fallback-index") || "0");
            var candidates = [];
            try {
              candidates = JSON.parse(image.getAttribute("data-fallback-srcs") || "[]");
            } catch (e) {
              candidates = [];
            }
            if (index < candidates.length) {
              image.setAttribute("data-fallback-index", String(index + 1));
              image.src = candidates[index];
              return;
            }
            image.style.display = "none";
          };
        })();
        </script>
        """
    }

    private static func escape(_ value: String) -> String {
        RSSArticleHTMLSanitizer.escape(value)
    }
}

enum RSSArticleContentLoader {
    static func loadFullText(for article: RSSArticleRecord) async throws -> RSSExtractedArticle {
        guard let url = URL(string: article.link)?.upgradedToHTTPS() else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw RSSArticleContentLoaderError.httpStatus(http.statusCode)
            }

            let extracted = RSSArticleExtractor.extract(from: data, baseURL: url)
            let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let html = extracted.html.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !html.isEmpty else {
                throw RSSArticleContentLoaderError.emptyContent
            }
            return extracted
        } catch let error as RSSArticleContentLoaderError {
            throw error
        } catch {
            if isATSBlocked(error) {
                throw RSSArticleContentLoaderError.atsBlocked
            }
            throw error
        }
    }

    private static func isATSBlocked(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == -1022
    }
}

enum RSSArticleContentLoaderError: LocalizedError, Equatable {
    case httpStatus(Int)
    case emptyContent
    case atsBlocked

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "HTTP \(status)"
        case .emptyContent:
            return localized("沒有可讀全文")
        case .atsBlocked:
            return localized("此來源使用不安全的 HTTP 連線，已被 iOS 安全政策阻擋。")
        }
    }
}
