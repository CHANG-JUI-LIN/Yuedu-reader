import Foundation
import Combine
import SwiftSoup

// MARK: - RSSFetcher

@MainActor
final class RSSFetcher: ObservableObject {
    @Published var items: [RSSItem] = []
    @Published var response: RSSFeedResponse?
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    func fetchItems(from source: RSSSource, metadata: RSSFeedFetchMetadata? = nil) async {
        isLoading = true
        error = nil
        response = nil
        defer { isLoading = false }

        if source.isLegadoRuleBased {
            await fetchWithLegadoRules(source: source)
            return
        }

        guard let request = RSSRequestFactory.feedRequest(for: source, metadata: metadata) else {
            error = localized("RSS URL 無效")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 304 {
                self.response = .notModified
                items = []
                return
            }

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                error = String(format: localized("RSS 請求失敗：HTTP %@"), "\(http.statusCode)")
                return
            }

            let parser = RSSXMLParser(sourceId: source.id)
            let parsedItems = parser.parse(data: data)

            if let parserError = parser.error {
                error = parserError
                items = []
                return
            }

            items = parsedItems
            let http = response as? HTTPURLResponse
            let metadata = RSSFeedFetchMetadata(
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                lastFetchedAt: Date()
            )
            self.response = .updated(items: parsedItems, metadata: metadata, feedInfo: parser.feedInfo)

            if parsedItems.isEmpty {
                error = localized("RSS 解析成功，但沒有找到文章。")
            }
        } catch {
            if isATSBlockedError(error) {
                self.error = localized("此來源使用不安全的 HTTP 連線，已被 iOS 安全政策阻擋。")
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func isATSBlockedError(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == -1022
    }

    private func fetchWithLegadoRules(source: RSSSource) async {
        do {
            let parsedItems = try await LegadoRSSScraper.scrape(source: source)
            items = parsedItems
            let metadata = RSSFeedFetchMetadata(lastFetchedAt: Date())
            self.response = .updated(items: parsedItems, metadata: metadata, feedInfo: nil)

            if parsedItems.isEmpty {
                error = localized("RSS 解析成功，但沒有找到文章。")
            }
        } catch {
            if isATSBlockedError(error) {
                self.error = localized("此來源使用不安全的 HTTP 連線，已被 iOS 安全政策阻擋。")
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - RSSXMLParser

final class RSSXMLParser: NSObject, XMLParserDelegate {
    private let sourceId: String
    private var parsedItems: [RSSItem] = []

    private var isAtom = false
    private var insideChannel = false
    private var insideChannelImage = false
    private var insideItem = false
    private var currentItem: [String: String] = [:]
    private var characterBuffer = ""
    private var currentLinkHref: String?
    private var currentLinkRel: String?
    private var feedTitle: String?
    private var feedHomepageURL: String?
    private var feedFaviconURL: String?

    private(set) var error: String?

    var feedInfo: RSSFeedInfo? {
        let title = cleanOptionalText(feedTitle)
        let homepageURL = cleanOptionalText(feedHomepageURL)
        let faviconURL = cleanOptionalText(feedFaviconURL)
        guard title != nil || homepageURL != nil || faviconURL != nil else {
            return nil
        }
        return RSSFeedInfo(title: title, homepageURL: homepageURL, faviconURL: faviconURL)
    }

    private let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    init(sourceId: String) {
        self.sourceId = sourceId
    }

    func parse(data: Data) -> [RSSItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self

        let success = parser.parse()

        if !success {
            error = parser.parserError?.localizedDescription ?? localized("RSS XML 解析失敗。")
        }

        return parsedItems
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        characterBuffer = ""

        switch name {
        case "feed":
            isAtom = true

        case "channel":
            insideChannel = true

        case "image":
            if insideChannel, !insideItem {
                insideChannelImage = true
            }

        case "item", "entry":
            insideItem = true
            currentItem = [:]
            currentLinkHref = nil
            currentLinkRel = nil

        case "media:thumbnail", "media:content":
            if insideItem, currentItem["imageURL"] == nil {
                if let url = attributeDict["url"] {
                    currentItem["imageURL"] = url
                }
            }

        case "enclosure":
            if insideItem, currentItem["imageURL"] == nil {
                if let type = attributeDict["type"]?.lowercased(), type.hasPrefix("image/"), let url = attributeDict["url"] {
                    currentItem["imageURL"] = url
                }
            }

        case "link":
            if isAtom {
                let rel = (attributeDict["rel"] ?? "alternate").lowercased()
                let href = attributeDict["href"]
                currentLinkRel = rel

                if insideItem {
                    if rel == "alternate" || rel.isEmpty {
                        currentLinkHref = href
                    }
                } else if let href, !href.isEmpty {
                    if rel == "alternate" || rel.isEmpty {
                        feedHomepageURL = feedHomepageURL ?? href
                    } else if rel == "icon" || rel == "shortcut icon" || rel == "apple-touch-icon" {
                        feedFaviconURL = feedFaviconURL ?? href
                    }
                }
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            characterBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let text = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard insideItem else {
            handleFeedElementEnd(name: name, text: text)
            characterBuffer = ""
            return
        }

        switch name {
        case "title":
            currentItem["title"] = text

        case "link":
            if isAtom {
                if let href = currentLinkHref, !href.isEmpty {
                    currentItem["link"] = href
                }
            } else {
                currentItem["link"] = text
            }

        case "description", "summary", "content", "content:encoded":
            if !text.isEmpty {
                let existingPriority = Int(currentItem["contentPriority"] ?? "0") ?? 0
                let priority: Int
                switch name {
                case "content:encoded", "content":
                    priority = 3
                case "description":
                    priority = 2
                default:
                    priority = 1
                }

                if priority >= existingPriority {
                    currentItem["description"] = text
                    currentItem["contentHTML"] = text
                    currentItem["contentPriority"] = "\(priority)"
                }
            }

        case "pubdate", "published", "updated":
            if !text.isEmpty, currentItem["pubDate"] == nil {
                currentItem["pubDate"] = text
            }

        case "author", "dc:creator":
            if !text.isEmpty {
                currentItem["author"] = text
            }

        case "item", "entry":
            if let item = buildItem() {
                parsedItems.append(item)
            }

            insideItem = false
            currentItem = [:]
            currentLinkHref = nil
            currentLinkRel = nil

        default:
            break
        }

        characterBuffer = ""
    }

    private func handleFeedElementEnd(name: String, text: String) {
        switch name {
        case "title":
            if !insideChannelImage, !text.isEmpty {
                feedTitle = feedTitle ?? text
            }

        case "link":
            if isAtom {
                currentLinkHref = nil
                currentLinkRel = nil
            } else if insideChannel, !insideChannelImage, !text.isEmpty {
                feedHomepageURL = feedHomepageURL ?? text
            }

        case "url":
            if insideChannelImage, !text.isEmpty {
                feedFaviconURL = feedFaviconURL ?? text
            }

        case "icon", "logo":
            if isAtom, !text.isEmpty {
                feedFaviconURL = feedFaviconURL ?? text
            }

        case "image":
            insideChannelImage = false

        case "channel":
            insideChannel = false

        default:
            break
        }
    }

    private func buildItem() -> RSSItem? {
        guard let title = currentItem["title"], !title.isEmpty,
              let link = currentItem["link"], !link.isEmpty
        else {
            return nil
        }

        let cleanTitle = RSSContentSanitizer.cleanText(title)
        let rawDescription = currentItem["description"] ?? ""
        let htmlMetadata = contentMetadata(from: rawDescription)
        let summary = RSSContentSanitizer.summary(from: rawDescription)
        let pubDate = currentItem["pubDate"]
            .flatMap { parseDate($0) }
            ?? htmlMetadata.dateString.flatMap { parseDate($0) }
        let author = currentItem["author"]
            .map { RSSContentSanitizer.cleanText($0) }
            ?? htmlMetadata.author

        let rawImageURL = currentItem["imageURL"].flatMap { $0.isEmpty ? nil : $0 } ?? htmlMetadata.imageURL
        let imageURL = rawImageURL.flatMap { URL(string: $0)?.upgradedToHTTPS().absoluteString }

        return RSSItem(
            id: stableID(title: cleanTitle, link: link),
            title: cleanTitle,
            link: link,
            pubDate: pubDate,
            description: summary,
            contentHTML: rawDescription,
            author: author,
            imageURL: imageURL,
            sourceId: sourceId
        )
    }

    private func contentMetadata(from html: String) -> (author: String?, dateString: String?, imageURL: String?) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body() else {
            return (nil, nil, nil)
        }

        let author = cleanOptionalText((try? body.select("address").first()?.text()) ?? nil)
        let timeElement = (try? body.select("time").first()) ?? nil
        let dateString = cleanOptionalText(
            (try? timeElement?.attr("datetime"))
            ?? (try? timeElement?.attr("pudate"))
            ?? (try? timeElement?.text())
            ?? nil
        )
        let imageURL = cleanOptionalText((try? body.select("img[src]").first()?.attr("src")) ?? nil)
        return (author, dateString, imageURL)
    }

    private func cleanOptionalText(_ text: String?) -> String? {
        guard let cleaned = text.map({ RSSContentSanitizer.cleanText($0) }),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    private func stableID(title: String, link: String) -> String {
        if !link.isEmpty {
            return link
        }
        return "\(sourceId)::\(title)"
    }

    private func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return nil
    }
}

// MARK: - RSSContentSanitizer

enum RSSContentSanitizer {
    static func cleanText(_ text: String) -> String {
        normalize(stripTags(decodeEntities(text)))
    }

    static func summary(from html: String, maxLength: Int = 220) -> String {
        let decoded = decodeEntities(html)

        if let document = try? SwiftSoup.parse(decoded) {
            _ = try? document.select(
                "script, style, noscript, svg, iframe, [aria-hidden=true], [hidden], " +
                "[data-e2e=advertisement], [data-e2e=recommendations-heading], " +
                "[data-testid=byline], [data-testid=caption], [data-component=ad-slot]"
            ).remove()

            let paragraphs = ((try? document.select("p").array()) ?? [])
                .compactMap { try? $0.text() }
                .map(normalize)
                .filter(isUsefulSummaryLine)

            let paragraphText = paragraphs.joined(separator: " ")
            if !paragraphText.isEmpty {
                return truncate(paragraphText, maxLength: maxLength)
            }

            if let bodyText = try? document.text() {
                let normalized = normalize(bodyText)
                if !normalized.isEmpty {
                    return truncate(normalized, maxLength: maxLength)
                }
            }
        }

        return truncate(normalize(stripTags(decoded)), maxLength: maxLength)
    }

    private static func isUsefulSummaryLine(_ line: String) -> Bool {
        guard line.count >= 8 else { return false }

        let noisePrefixes = [
            "Article Information",
            "Author,",
            "Role,",
            "Reporting from,",
            "Image source,",
            "圖像來源",
            "图像来源",
            "圖片來源",
            "图片来源",
            "閱讀時間",
            "阅读时间",
            "廣告",
            "广告",
            "熱讀",
            "热读",
            "Skip ",
            "End of "
        ]

        return !noisePrefixes.contains { line.hasPrefix($0) }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func decodeEntities(_ text: String) -> String {
        var decoded = text
        let replacements: [(String, String)] = [
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&ldquo;", "“"),
            ("&rdquo;", "”"),
            ("&lsquo;", "‘"),
            ("&rsquo;", "’"),
            ("&hellip;", "…"),
            ("&mdash;", "—"),
            ("&ndash;", "–")
        ]

        for (entity, value) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        return decoded
    }
}
