import Foundation
import Combine
import SwiftSoup
import CryptoKit

// MARK: - Data+FeedDetection

extension Data {

    func containsASCII(_ needle: String) -> Bool {
        let needleBytes = Array(needle.utf8)
        guard !needleBytes.isEmpty else { return true }
        return withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let count = buffer.count
            guard count >= needleBytes.count else { return false }
            let last = count - needleBytes.count
            var i = 0
            while i <= last {
                var matched = true
                for j in 0..<needleBytes.count {
                    if ptr[i + j] != needleBytes[j] { matched = false; break }
                }
                if matched { return true }
                i += 1
            }
            return false
        }
    }

    var isProbablyXML: Bool { startsWithASCII("<?xml") }

    var isProbablyJSON: Bool { startsWithASCII("{") }

    func startsWithASCII(_ needle: String) -> Bool {
        let needleBytes = Array(needle.utf8)
        guard !needleBytes.isEmpty else { return true }
        return withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let count = buffer.count
            var i = 0
            while i < count {
                let byte = ptr[i]
                if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\r")
                    || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") {
                    i += 1; continue
                }
                if byte == needleBytes[0] {
                    guard count - i >= needleBytes.count else { return false }
                    for j in 0..<needleBytes.count {
                        if ptr[i + j] != needleBytes[j] { return false }
                    }
                    return true
                }
                if i < 4 { i += 1; continue }
                return false
            }
            return false
        }
    }

    var isProbablyJSONFeed: Bool {
        guard isProbablyJSON else { return false }
        return containsASCII("://jsonfeed.org/version/")
            || containsASCII(":\\/\\/jsonfeed.org\\/version\\/")
    }

    var isProbablyRSSInJSON: Bool {
        guard isProbablyJSON else { return false }
        return containsASCII("rss") && containsASCII("channel") && containsASCII("item")
    }

    var isProbablyRSS: Bool {
        if containsASCII("<rss") || containsASCII("<rdf:RDF") { return true }
        return containsASCII("<channel>") && containsASCII("<pubDate>")
    }

    var isProbablyAtom: Bool {
        containsASCII("<feed")
    }

    var isProbablyHTML: Bool {
        guard let prefix = String(data: self.prefix(512), encoding: .utf8)?.lowercased() else {
            return false
        }
        return prefix.contains("<!doctype html")
            || prefix.contains("<html")
            || prefix.contains("<head")
    }
}

// MARK: - Feed Type Detection

let minFeedDetectionBytes = 128

func detectFeedType(data: Data, isPartialData: Bool = false) -> FeedType {
    if data.count < minFeedDetectionBytes { return .unknown }
    if data.isProbablyJSONFeed { return .jsonFeed }
    if data.isProbablyRSSInJSON { return .rssInJSON }
    if data.isProbablyRSS { return .rss }
    if data.isProbablyAtom { return .atom }
    if isPartialData && data.isProbablyJSON { return .unknown }
    return .notAFeed
}

// MARK: - Feed Parser Entry Point

enum RSSFeedParser {
    static func parse(data: Data, url: String) -> ParsedFeedInfo? {
        let type = detectFeedType(data: data)
        switch type {
        case .jsonFeed:
            return (try? JSONFeedParser.parse(data: data, url: url)) ?? nil
        case .rssInJSON:
            return (try? RSSInJSONParser.parse(data: data, url: url)) ?? nil
        case .rss:
            return RSSXMLParserDelegate.parse(data: data, url: url).flatMap { (info, items) in
                ParsedFeedInfo(type: .rss, title: info.title, homePageURL: info.homepageURL,
                               feedURL: url, language: nil, feedDescription: nil, nextURL: nil,
                               iconURL: nil, faviconURL: info.faviconURL, authors: nil,
                               expired: false, hubs: nil, items: items)
            }
        case .atom:
            return AtomXMLParserDelegate.parse(data: data, url: url).flatMap { (info, items) in
                ParsedFeedInfo(type: .atom, title: info.title, homePageURL: info.homepageURL,
                               feedURL: url, language: nil, feedDescription: nil, nextURL: nil,
                               iconURL: info.faviconURL, faviconURL: info.faviconURL, authors: nil,
                               expired: false, hubs: nil, items: items)
            }
        case .unknown, .notAFeed:
            return nil
        }
    }
}

// MARK: - Shared Date Parsing

private let sharedDateFormatters: [DateFormatter] = {
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy/MM/dd HH:mm:ss"
    ]
    return formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}()

private func parseDateRFC(_ string: String) -> Date? {
    for formatter in sharedDateFormatters {
        if let date = formatter.date(from: string) { return date }
    }
    return nil
}

private func resolveURL(_ urlString: String, relativeTo baseURL: String?) -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
        return trimmed
    }
    guard let base = baseURL.flatMap(URL.init(string:)),
          let resolved = URL(string: trimmed, relativeTo: base) else {
        return trimmed
    }
    return resolved.absoluteString
}

private func stringIsProbablyURLOrPath(_ s: String) -> Bool {
    if s.contains(" ") { return false }
    if !s.contains("/") { return false }
    if s.lowercased().hasPrefix("tag:") { return false }
    return true
}

private func objectForCaseInsensitiveKey(_ dict: [String: String], _ key: String) -> String? {
    if let v = dict[key] { return v }
    let target = key.lowercased()
    for (k, v) in dict where k.lowercased() == target { return v }
    return nil
}

// MARK: - RSS 2.0 / 1.0 (RDF) Parser

private struct RSSFeedMeta {
    var title: String?
    var homepageURL: String?
    var faviconURL: String?
}

private final class RSSXMLParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: String
    private var items: Set<ParsedFeedItem> = []
    private var feedMeta = RSSFeedMeta()

    private var isRDF = false
    private var endRSSFound = false
    private var parsingArticle = false
    private var parsingAuthor = false
    private var parsingChannelImage = false
    private var currentAttributes: [String: String] = [:]
    private var characterBuffer = ""
    private var currentItem: RSSItemBuilder!

    private struct RSSItemBuilder {
        var guid: String?
        var title: String?
        var body: String?
        var summary: String?
        var link: String?
        var permalink: String?
        var datePublished: Date?
        var authors: Set<ParsedAuthor> = []
        var attachments: Set<ParsedAttachment> = []
        var imageURL: String?
    }

    init(feedURL: String) {
        self.feedURL = feedURL
    }

    static func parse(data: Data, url: String) -> (RSSFeedMeta, Set<ParsedFeedItem>)? {
        let delegate = RSSXMLParserDelegate(feedURL: url)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return (delegate.feedMeta, delegate.items)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if endRSSFound { return }
        let name = elementName.lowercased()

        if name == "rdf" || name == "rdf:rdf" { isRDF = true; return }

        if isRDF && name == "item" || name == "guid" || name == "enclosure" {
            currentAttributes = attributeDict
        } else {
            currentAttributes = [:]
        }
        characterBuffer = ""

        if name == "item" {
            parsingArticle = true
            currentItem = RSSItemBuilder()
            if isRDF, let about = attributeDict["rdf:about"] ?? attributeDict["about"], !about.isEmpty {
                currentItem.guid = about
                currentItem.permalink = about
            }
            return
        }

        if name == "image" && !parsingArticle {
            parsingChannelImage = true; return
        }

        if name == "author" { parsingAuthor = parsingArticle; return }

        if parsingArticle && (name == "media:thumbnail" || name == "media:content") {
            if currentItem.imageURL == nil, let url = attributeDict["url"] {
                currentItem.imageURL = url
            }
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

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if endRSSFound { return }
        let name = elementName.lowercased()
        let text = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if isRDF && name == "rdf" { endRSSFound = true; return }
        if name == "rss" { endRSSFound = true; return }

        if parsingChannelImage && !parsingArticle && name == "url" {
            feedMeta.faviconURL = feedMeta.faviconURL ?? (text.isEmpty ? nil : text)
            characterBuffer = ""; return
        }
        if !parsingArticle && !parsingChannelImage && name == "image" {
            parsingChannelImage = false; characterBuffer = ""; return
        }
        if name == "item" {
            parsingArticle = false
            if let item = buildParsedItem() { items.insert(item) }
            currentItem = nil; characterBuffer = ""; return
        }

        if parsingArticle {
            handleArticleElementEnd(name: name, text: text, namespaceURI: namespaceURI)
            if name == "author" { parsingAuthor = false }
        } else if !parsingChannelImage {
            handleFeedElementEnd(name: name, text: text, namespaceURI: namespaceURI)
        }
        characterBuffer = ""
    }

    // MARK: Article elements

    private func handleArticleElementEnd(name: String, text: String, namespaceURI: String?) {
        guard currentItem != nil else { return }

        // Dublin Core namespace
        if let ns = namespaceURI, ns.hasPrefix("http://purl.org/dc/") {
            if name == "creator" && !text.isEmpty {
                currentItem.authors.insert(authorFromString(text))
            } else if name == "date" && !text.isEmpty {
                currentItem.datePublished = currentItem.datePublished ?? parseDateRFC(text)
            }
            return
        }
        // content:encoded namespace
        if let ns = namespaceURI, ns.contains("rss") && ns.contains("content") {
            if (name == "encoded" || name == "content") && !text.isEmpty {
                currentItem.body = text
            }
            return
        }

        switch name {
        case "guid":
            if !text.isEmpty {
                currentItem.guid = text
                let isPermaLink = objectForCaseInsensitiveKey(currentAttributes, "ispermalink")
                if isPermaLink == nil || isPermaLink?.lowercased() != "false" {
                    if stringIsProbablyURLOrPath(text) {
                        currentItem.permalink = resolveURL(text, relativeTo: feedMeta.homepageURL)
                    }
                }
            }
        case "title":
            if !text.isEmpty && !parsingAuthor { currentItem.title = text }
        case "link":
            if currentItem.link == nil && !text.isEmpty {
                currentItem.link = resolveURL(text, relativeTo: feedMeta.homepageURL)
            }
        case "description":
            if currentItem.body == nil && !text.isEmpty { currentItem.body = text }
        case "pubdate":
            if currentItem.datePublished == nil { currentItem.datePublished = parseDateRFC(text) }
        case "author", "dc:creator":
            if !text.isEmpty { currentItem.authors.insert(authorFromString(text)) }
        case "enclosure":
            if let url = currentAttributes["url"], !url.isEmpty {
                let mimeType = currentAttributes["type"]
                let length = Int(currentAttributes["length"] ?? "") ?? 0
                if let attachment = ParsedAttachment(url: url, mimeType: mimeType, title: nil,
                                                     sizeInBytes: length > 0 ? length : nil, durationInSeconds: nil) {
                    currentItem.attachments.insert(attachment)
                }
                if currentItem.imageURL == nil,
                   let type = mimeType?.lowercased(), type.hasPrefix("image/") {
                    currentItem.imageURL = url
                }
            }
        default:
            break
        }
    }

    // MARK: Feed elements

    private func handleFeedElementEnd(name: String, text: String, namespaceURI: String?) {
        if namespaceURI != nil { return }
        switch name {
        case "title":
            if !parsingChannelImage && !text.isEmpty { feedMeta.title = feedMeta.title ?? text }
        case "link":
            if !parsingChannelImage && !text.isEmpty && feedMeta.homepageURL == nil {
                feedMeta.homepageURL = text
            }
        case "language":
            break // Not stored in feed meta currently
        default:
            break
        }
    }

    // MARK: Build

    private func buildParsedItem() -> ParsedFeedItem? {
        guard let item = currentItem else { return nil }
        let title = item.title ?? ""
        let link = item.permalink ?? item.link ?? ""
        guard !title.isEmpty || !link.isEmpty else { return nil }

        let uniqueID: String
        if let guid = item.guid, !guid.isEmpty { uniqueID = guid }
        else if !link.isEmpty { uniqueID = link }
        else { uniqueID = title }

        var contentHTML = item.body ?? ""
        var itemSummary: String? = item.summary
        if contentHTML.isEmpty, let s = itemSummary, !s.isEmpty {
            contentHTML = s; itemSummary = nil
        }

        return ParsedFeedItem(
            uniqueID: uniqueID, feedURL: feedURL,
            url: item.permalink, externalURL: item.link != item.permalink ? item.link : nil,
            title: title.isEmpty ? nil : title, language: nil,
            contentHTML: contentHTML.isEmpty ? nil : contentHTML, contentText: nil,
            summary: itemSummary, imageURL: item.imageURL, bannerImageURL: nil,
            datePublished: item.datePublished, dateModified: nil,
            authors: item.authors.isEmpty ? nil : item.authors,
            tags: nil, attachments: item.attachments.isEmpty ? nil : item.attachments
        )
    }

    private func authorFromString(_ s: String) -> ParsedAuthor {
        if s.contains("@") { return ParsedAuthor(name: nil, url: nil, avatarURL: nil, emailAddress: s) }
        if s.lowercased().hasPrefix("http") { return ParsedAuthor(name: nil, url: s, avatarURL: nil, emailAddress: nil) }
        return ParsedAuthor(name: s, url: nil, avatarURL: nil, emailAddress: nil)
    }
}

// MARK: - Atom Parser

private final class AtomXMLParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: String
    private var items: Set<ParsedFeedItem> = []
    private var feedMeta = RSSFeedMeta()

    private var rootAuthor: ParsedAuthor?
    private var currentAuthor: (name: String?, email: String?, uri: String?)?
    private var currentItem: AtomItemBuilder!
    private var characterBuffer = ""
    private var currentAttributes: [String: String] = [:]
    private var parsingArticle = false
    private var parsingAuthor = false
    private var parsingSource = false
    private var endFeedFound = false

    // xhtml content capture
    private var capturingXHTML = false
    private var xhtmlDepth = 0
    private var xhtmlContent = ""
    private var xhtmlElementName = ""

    private struct AtomItemBuilder {
        var guid: String?
        var title: String?
        var body: String?
        var summary: String?
        var link: String?
        var permalink: String?
        var datePublished: Date?
        var dateModified: Date?
        var authors: Set<ParsedAuthor> = []
        var attachments: Set<ParsedAttachment> = []
        var imageURL: String?
        var language: String?
    }

    init(feedURL: String) {
        self.feedURL = feedURL
    }

    static func parse(data: Data, url: String) -> (RSSFeedMeta, Set<ParsedFeedItem>)? {
        let delegate = AtomXMLParserDelegate(feedURL: url)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return (delegate.feedMeta, delegate.items)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if endFeedFound { return }
        let name = elementName.lowercased()
        currentAttributes = attributeDict

        if capturingXHTML {
            xhtmlDepth += 1
            xhtmlContent += elementXML(name, attributes: attributeDict, isStart: true)
            return
        }

        characterBuffer = ""

        if name == "entry" {
            parsingArticle = true
            currentItem = AtomItemBuilder()
            return
        }
        if name == "author" { parsingAuthor = true; currentAuthor = (nil, nil, nil); return }
        if name == "source" { parsingSource = true; return }

        // xhtml content detection
        if parsingArticle && (name == "content" || name == "summary") {
            let type = (attributeDict["type"] ?? "").lowercased()
            if type == "xhtml" || type == "html" {
                capturingXHTML = true
                xhtmlDepth = 0
                xhtmlContent = ""
                xhtmlElementName = name
                if name == "content" && currentItem?.language == nil {
                    currentItem.language = attributeDict["xml:lang"]
                }
                return
            }
        }

        if !parsingArticle && name == "link" {
            handleFeedLink(attributes: attributeDict)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingXHTML { xhtmlContent += escapeXML(string); return }
        characterBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturingXHTML { return }
        if let string = String(data: CDATABlock, encoding: .utf8) {
            characterBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()

        if capturingXHTML {
            if xhtmlDepth > 0 {
                xhtmlDepth -= 1
                xhtmlContent += elementXML(name, attributes: [:], isStart: false)
                return
            }
            // End of xhtml content
            capturingXHTML = false
            if name == "content" {
                currentItem.body = xhtmlContent
            } else if name == "summary" {
                currentItem.summary = xhtmlContent
            }
            return
        }

        if name == "feed" { endFeedFound = true; return }
        if endFeedFound { return }

        let text = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if parsingAuthor {
            handleAuthorElementEnd(name: name, text: text)
            characterBuffer = ""; return
        }
        if name == "entry" {
            parsingArticle = false
            if let item = buildParsedItem() { items.insert(item) }
            currentItem = nil; characterBuffer = ""; return
        }
        if parsingArticle && !parsingSource {
            handleArticleElementEnd(name: name, text: text)
        }
        if name == "source" { parsingSource = false }
        if !parsingArticle && !parsingSource {
            handleFeedElementEnd(name: name, text: text)
        }
        characterBuffer = ""
    }

    // MARK: Article elements

    private func handleArticleElementEnd(name: String, text: String) {
        guard currentItem != nil else { return }
        switch name {
        case "id":
            currentItem.guid = text.isEmpty ? nil : text
        case "title":
            currentItem.title = text.isEmpty ? nil : text
        case "content":
            if !text.isEmpty { currentItem.body = text }
        case "summary":
            if currentItem.summary == nil && !text.isEmpty { currentItem.summary = text }
        case "link":
            handleArticleLink()
        case "published":
            currentItem.datePublished = currentItem.datePublished ?? parseDateRFC(text)
        case "updated":
            currentItem.dateModified = parseDateRFC(text)
        case "issued":
            if currentItem.datePublished == nil { currentItem.datePublished = parseDateRFC(text) }
        case "modified":
            if currentItem.dateModified == nil { currentItem.dateModified = parseDateRFC(text) }
        default:
            break
        }
    }

    private func handleArticleLink() {
        guard let urlString = currentAttributes["href"], !urlString.isEmpty else { return }
        let resolved = resolveURL(urlString, relativeTo: feedMeta.homepageURL ?? feedURL)
        let rel = (currentAttributes["rel"] ?? "alternate").lowercased()

        if rel == "enclosure" {
            let length = Int(currentAttributes["length"] ?? "") ?? 0
            if let attachment = ParsedAttachment(url: resolved, mimeType: currentAttributes["type"],
                                                  title: currentAttributes["title"],
                                                  sizeInBytes: length > 0 ? length : nil,
                                                  durationInSeconds: nil) {
                currentItem.attachments.insert(attachment)
            }
            return
        }
        if rel == "related" {
            if currentItem.link == nil { currentItem.link = resolved }
        }
        if rel == "alternate" {
            if currentItem.permalink == nil { currentItem.permalink = resolved }
        }
    }

    // MARK: Author

    private func handleAuthorElementEnd(name: String, text: String) {
        if name == "author" {
            parsingAuthor = false
            guard let author = currentAuthor else { currentAuthor = nil; return }
            let parsed = ParsedAuthor(name: author.name, url: author.uri, avatarURL: nil, emailAddress: author.email)
            if parsed.isEmpty { currentAuthor = nil; return }
            if parsingArticle {
                currentItem?.authors.insert(parsed)
            } else if rootAuthor == nil {
                rootAuthor = parsed
            }
            currentAuthor = nil
            return
        }
        if text.isEmpty { return }
        switch name {
        case "name": currentAuthor?.name = text
        case "email": currentAuthor?.email = text
        case "uri": currentAuthor?.uri = text
        default: break
        }
    }

    // MARK: Feed elements

    private func handleFeedElementEnd(name: String, text: String) {
        if text.isEmpty { return }
        switch name {
        case "title":
            feedMeta.title = feedMeta.title ?? text
        case "icon":
            feedMeta.faviconURL = feedMeta.faviconURL ?? text
        case "logo":
            feedMeta.faviconURL = text
        default:
            break
        }
    }

    private func handleFeedLink(attributes: [String: String]) {
        guard feedMeta.homepageURL == nil,
              let href = attributes["href"], !href.isEmpty else { return }
        let rel = (attributes["rel"] ?? "alternate").lowercased()
        if rel == "alternate" || rel.isEmpty {
            feedMeta.homepageURL = resolveURL(href, relativeTo: feedURL)
        }
    }

    // MARK: Build

    private func buildParsedItem() -> ParsedFeedItem? {
        guard let item = currentItem else { return nil }

        // Apply root author to items without authors
        if item.authors.isEmpty, let root = rootAuthor { currentItem.authors.insert(root) }

        let title = item.title ?? ""
        let link = item.permalink ?? item.link ?? ""
        let uniqueID = item.guid ?? link

        var contentHTML = item.body ?? ""
        var itemSummary: String? = item.summary
        if contentHTML.isEmpty, let s = itemSummary, !s.isEmpty {
            contentHTML = s; itemSummary = nil
        }

        return ParsedFeedItem(
            uniqueID: uniqueID, feedURL: feedURL,
            url: item.permalink, externalURL: item.link != item.permalink ? item.link : nil,
            title: title.isEmpty ? nil : title, language: item.language,
            contentHTML: contentHTML.isEmpty ? nil : contentHTML, contentText: nil,
            summary: itemSummary, imageURL: item.imageURL, bannerImageURL: nil,
            datePublished: item.datePublished, dateModified: item.dateModified,
            authors: item.authors.isEmpty ? nil : item.authors,
            tags: nil, attachments: item.attachments.isEmpty ? nil : item.attachments
        )
    }

    // MARK: XML helpers

    private func elementXML(_ name: String, attributes: [String: String], isStart: Bool) -> String {
        if isStart {
            let attrs = attributes.map { "\($0.key)=\"\(escapeXML($0.value))\"" }.joined(separator: " ")
            let prefix = attrs.isEmpty ? "" : " "
            return "<\(name)\(prefix)\(attrs)>"
        }
        return "</\(name)>"
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - JSON Feed Parser (https://jsonfeed.org/version/1.1)

private enum JSONFeedParser {
    struct Key {
        static let version = "version"
        static let items = "items"
        static let title = "title"
        static let homePageURL = "home_page_url"
        static let feedURL = "feed_url"
        static let feedDescription = "description"
        static let nextURL = "next_url"
        static let icon = "icon"
        static let favicon = "favicon"
        static let expired = "expired"
        static let author = "author"
        static let authors = "authors"
        static let name = "name"
        static let url = "url"
        static let avatar = "avatar"
        static let hubs = "hubs"
        static let type = "type"
        static let contentHTML = "content_html"
        static let contentText = "content_text"
        static let externalURL = "external_url"
        static let summary = "summary"
        static let image = "image"
        static let bannerImage = "banner_image"
        static let datePublished = "date_published"
        static let dateModified = "date_modified"
        static let tags = "tags"
        static let uniqueID = "id"
        static let attachments = "attachments"
        static let mimeType = "mime_type"
        static let sizeInBytes = "size_in_bytes"
        static let durationInSeconds = "duration_in_seconds"
        static let language = "language"
    }

    static let versionMarker = "://jsonfeed.org/version/"

    static func parse(data: Data, url: String) throws -> ParsedFeedInfo? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedParserError.invalidJSON
        }
        guard let version = json[Key.version] as? String,
              version.range(of: versionMarker) != nil else {
            throw FeedParserError.jsonFeedVersionNotFound
        }
        guard let itemsArray = json[Key.items] as? [[String: Any]] else {
            throw FeedParserError.jsonFeedItemsNotFound
        }
        guard json[Key.title] is String else {
            throw FeedParserError.jsonFeedTitleNotFound
        }

        let authors = parseAuthors(json)
        let homePageURL = json[Key.homePageURL] as? String
        let feedURL = json[Key.feedURL] as? String ?? url
        let feedDescription = json[Key.feedDescription] as? String
        let nextURL = json[Key.nextURL] as? String
        let iconURL = json[Key.icon] as? String
        let faviconURL = json[Key.favicon] as? String
        let expired = json[Key.expired] as? Bool ?? false
        let hubs = parseHubs(json)
        let language = json[Key.language] as? String

        let items = Set(itemsArray.compactMap { parseItem($0, feedURL: feedURL) })
        return ParsedFeedInfo(type: .jsonFeed, title: (json[Key.title] as? String),
                              homePageURL: homePageURL, feedURL: feedURL,
                              language: language, feedDescription: feedDescription,
                              nextURL: nextURL, iconURL: iconURL, faviconURL: faviconURL,
                              authors: authors, expired: expired, hubs: hubs, items: items)
    }

    private static func parseAuthors(_ json: [String: Any]) -> Set<ParsedAuthor>? {
        if let authorsArray = json[Key.authors] as? [[String: Any]] {
            let authors = authorsArray.compactMap { parseAuthor($0) }
            return authors.isEmpty ? nil : Set(authors)
        }
        if let authorObj = json[Key.author] as? [String: Any], let author = parseAuthor(authorObj) {
            return [author]
        }
        return nil
    }

    private static func parseAuthor(_ obj: [String: Any]) -> ParsedAuthor? {
        let name = obj[Key.name] as? String
        let url = obj[Key.url] as? String
        let avatar = obj[Key.avatar] as? String
        if name == nil && url == nil && avatar == nil { return nil }
        return ParsedAuthor(name: name, url: url, avatarURL: avatar, emailAddress: nil)
    }

    private static func parseHubs(_ json: [String: Any]) -> Set<ParsedHub>? {
        guard let hubsArray = json[Key.hubs] as? [[String: Any]] else { return nil }
        let hubs = hubsArray.compactMap { hub -> ParsedHub? in
            guard let url = hub[Key.url] as? String, let type = hub[Key.type] as? String else { return nil }
            return ParsedHub(type: type, url: url)
        }
        return hubs.isEmpty ? nil : Set(hubs)
    }

    private static func parseItem(_ item: [String: Any], feedURL: String) -> ParsedFeedItem? {
        guard let uniqueID = parseUniqueID(item) else { return nil }
        let contentHTML = item[Key.contentHTML] as? String
        let contentText = item[Key.contentText] as? String
        if contentHTML == nil && contentText == nil { return nil }

        let url = item[Key.url] as? String
        let externalURL = item[Key.externalURL] as? String
        let title = (item[Key.title] as? String).flatMap { decodeTitleEntities($0, feedURL: feedURL) }
        let language = item[Key.language] as? String
        let summary = item[Key.summary] as? String
        let imageURL = item[Key.image] as? String
        let bannerImageURL = item[Key.bannerImage] as? String
        let datePublished = (item[Key.datePublished] as? String).flatMap { parseDateRFC($0) }
        let dateModified = (item[Key.dateModified] as? String).flatMap { parseDateRFC($0) }
        let authors = parseAuthors(item)
        let tags = (item[Key.tags] as? [String]).map { Set($0) }
        let attachments = parseAttachments(item)

        return ParsedFeedItem(
            uniqueID: uniqueID, feedURL: feedURL, url: url, externalURL: externalURL,
            title: title, language: language,
            contentHTML: contentHTML, contentText: contentText,
            summary: summary, imageURL: imageURL, bannerImageURL: bannerImageURL,
            datePublished: datePublished, dateModified: dateModified,
            authors: authors, tags: tags, attachments: attachments
        )
    }

    private static func parseUniqueID(_ item: [String: Any]) -> String? {
        if let id = item[Key.uniqueID] as? String { return id }
        if let id = item[Key.uniqueID] as? Int { return "\(id)" }
        if let id = item[Key.uniqueID] as? Double { return "\(id)" }
        return nil
    }

    private static let titleEntityFeedHosts: Set<String> = [
        "kottke.org", "pxlnv.com", "macstories.net", "macobserver.com"
    ]

    private static func decodeTitleEntities(_ title: String, feedURL: String) -> String {
        guard let host = URL(string: feedURL)?.host?.lowercased(),
              titleEntityFeedHosts.contains(where: { host.contains($0) }) else {
            return title
        }
        return title
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func parseAttachments(_ item: [String: Any]) -> Set<ParsedAttachment>? {
        guard let array = item[Key.attachments] as? [[String: Any]] else { return nil }
        let attachments = array.compactMap { obj -> ParsedAttachment? in
            guard let url = obj[Key.url] as? String,
                  let mimeType = obj[Key.mimeType] as? String else { return nil }
            return ParsedAttachment(url: url, mimeType: mimeType,
                                     title: obj[Key.title] as? String,
                                     sizeInBytes: obj[Key.sizeInBytes] as? Int,
                                     durationInSeconds: obj[Key.durationInSeconds] as? Int)
        }
        return attachments.isEmpty ? nil : Set(attachments)
    }
}

private enum FeedParserError: LocalizedError {
    case invalidJSON
    case jsonFeedVersionNotFound
    case jsonFeedItemsNotFound
    case jsonFeedTitleNotFound
    case rssChannelNotFound
    case rssItemsNotFound

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Invalid JSON"
        case .jsonFeedVersionNotFound: return "JSON Feed version not found"
        case .jsonFeedItemsNotFound: return "JSON Feed items not found"
        case .jsonFeedTitleNotFound: return "JSON Feed title not found"
        case .rssChannelNotFound: return "RSS channel not found"
        case .rssItemsNotFound: return "RSS items not found"
        }
    }
}

// MARK: - RSS-in-JSON Parser

private enum RSSInJSONParser {
    static func parse(data: Data, url: String) throws -> ParsedFeedInfo? {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedParserError.invalidJSON
        }
        guard let rssObj = parsed["rss"] as? [String: Any] else {
            throw FeedParserError.rssChannelNotFound
        }
        guard let channel = rssObj["channel"] as? [String: Any] else {
            throw FeedParserError.rssChannelNotFound
        }

        guard let itemsArray = channel["item"] as? [[String: Any]]
            ?? parsed["item"] as? [[String: Any]]
            ?? channel["items"] as? [[String: Any]]
            ?? parsed["items"] as? [[String: Any]]
        else { throw FeedParserError.rssItemsNotFound }

        let title = channel["title"] as? String
        let homePageURL = channel["link"] as? String
        let feedDescription = channel["description"] as? String
        let language = channel["language"] as? String
        let iconURL = (channel["image"] as? [String: Any])?["url"] as? String

        let items = Set(itemsArray.compactMap { parseItem($0, feedURL: url) })
        return ParsedFeedInfo(type: .rssInJSON, title: title, homePageURL: homePageURL,
                              feedURL: url, language: language,
                              feedDescription: feedDescription, nextURL: nil,
                              iconURL: iconURL, faviconURL: nil, authors: nil,
                              expired: false, hubs: nil, items: items)
    }

    private static func parseItem(_ item: [String: Any], feedURL: String) -> ParsedFeedItem? {
        let externalURL = item["link"] as? String
        let title = item["title"] as? String

        var contentHTML = item["description"] as? String
        var contentText: String?
        if let html = contentHTML, !html.contains("<") {
            contentText = html; contentHTML = nil
        }
        if contentHTML == nil && contentText == nil && title == nil { return nil }

        let datePublished = (item["pubDate"] as? String).flatMap { parseDateRFC($0) }
        let authors = parseAuthors(item)
        let tags = parseTags(item)
        let attachments = parseAttachments(item)

        var uniqueID = item["guid"] as? String
        if uniqueID == nil {
            uniqueID = calculateUniqueID(title: title, externalURL: externalURL,
                                          datePublished: datePublished, authors: authors,
                                          attachments: attachments, contentHTML: contentHTML,
                                          contentText: contentText)
        }

        guard let uniqueID else { return nil }
        return ParsedFeedItem(
            uniqueID: uniqueID, feedURL: feedURL, url: nil, externalURL: externalURL,
            title: title, language: nil,
            contentHTML: contentHTML, contentText: contentText,
            summary: nil, imageURL: nil, bannerImageURL: nil,
            datePublished: datePublished, dateModified: nil,
            authors: authors, tags: tags, attachments: attachments
        )
    }

    private static func calculateUniqueID(title: String?, externalURL: String?,
                                           datePublished: Date?, authors: Set<ParsedAuthor>?,
                                           attachments: Set<ParsedAttachment>?,
                                           contentHTML: String?, contentText: String?) -> String {
        var s = ""
        if let d = datePublished { s += "\(d.timeIntervalSince1970)" }
        if let t = title { s += t }
        if let u = externalURL { s += u }
        if let e = authors?.first?.emailAddress { s += e }
        if let a = attachments?.first?.url { s += a }
        if s.isEmpty {
            s = contentHTML ?? contentText ?? UUID().uuidString
        }
        return s.md5Hash
    }

    private static func parseAuthors(_ item: [String: Any]) -> Set<ParsedAuthor>? {
        guard let email = item["author"] as? String else { return nil }
        return [ParsedAuthor(name: nil, url: nil, avatarURL: nil, emailAddress: email)]
    }

    private static func parseTags(_ item: [String: Any]) -> Set<String>? {
        if let catObj = item["category"] as? [String: Any], let tag = catObj["#value"] as? String {
            return [tag]
        }
        if let catArray = item["category"] as? [[String: Any]] {
            let tags = catArray.compactMap { $0["#value"] as? String }
            return tags.isEmpty ? nil : Set(tags)
        }
        return nil
    }

    private static func parseAttachments(_ item: [String: Any]) -> Set<ParsedAttachment>? {
        guard let enclosure = item["enclosure"] as? [String: Any],
              let url = enclosure["url"] as? String else { return nil }
        let sizeInBytes: Int?
        if let length = enclosure["length"] as? Int { sizeInBytes = length }
        else if let lengthStr = enclosure["length"] as? String { sizeInBytes = Int(lengthStr) }
        else { sizeInBytes = nil }
        guard let attachment = ParsedAttachment(url: url, mimeType: enclosure["type"] as? String,
                                                 title: nil, sizeInBytes: sizeInBytes,
                                                 durationInSeconds: nil) else { return nil }
        return [attachment]
    }
}

// MARK: - String MD5 helper

private extension String {
    var md5Hash: String {
        let digest = Insecure.MD5.hash(data: Data(utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - RSSFetcher

@MainActor
final class RSSFetcher: ObservableObject {
    @Published var items: [RSSItem] = []
    @Published var response: RSSFeedResponse?
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var resolvedFeedURL: String?
    @Published var resolvedHomepageURL: String?

    func fetchItems(from source: RSSSource, metadata: RSSFeedFetchMetadata? = nil) async {
        isLoading = true
        error = nil
        response = nil
        resolvedFeedURL = nil
        resolvedHomepageURL = nil
        defer { isLoading = false }

        if source.isLegadoRuleBased {
            await fetchWithLegadoRules(source: source)
            return
        }

        await fetchItems(from: source, metadata: metadata, allowFeedDiscovery: true)
    }

    private func fetchItems(from source: RSSSource, metadata: RSSFeedFetchMetadata?, allowFeedDiscovery: Bool) async {
        error = nil
        response = nil
        items = []

        if source.isLegadoRuleBased {
            await fetchWithLegadoRules(source: source)
            return
        }

        guard let request = RSSRequestFactory.feedRequest(for: source, metadata: metadata) else {
            error = localized("RSS URL 無效")
            return
        }

        do {
            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            if let http = httpResponse as? HTTPURLResponse, http.statusCode == 304 {
                self.response = .notModified
                items = []
                return
            }

            if let http = httpResponse as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                error = formattedHTTPError(statusCode: http.statusCode)
                return
            }

            // Try unified parser first
            if let parsed = RSSFeedParser.parse(data: data, url: source.url) {
                let rssItems = parsed.items.map { item in
                    RSSItem(from: item, sourceId: source.id,
                        summary: RSSContentSanitizer.summary(from: item.contentHTML ?? item.contentText ?? item.summary ?? ""))
                }
                items = rssItems

                let http = httpResponse as? HTTPURLResponse
                let fetchMeta = RSSFeedFetchMetadata(
                    etag: http?.value(forHTTPHeaderField: "ETag"),
                    lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                    lastFetchedAt: Date()
                )
                let feedInfo = RSSFeedInfo(
                    title: parsed.title, homepageURL: parsed.homePageURL, faviconURL: parsed.faviconURL
                )
                self.response = .updated(items: rssItems, metadata: fetchMeta, feedInfo: feedInfo)

                if rssItems.isEmpty {
                    error = localized("RSS 解析成功，但沒有找到文章。")
                }
                return
            }

            // Fallback: legacy XML parser + feed discovery
            let parser = RSSXMLParser(sourceId: source.id)
            let parsedItems = parser.parse(data: data)

            if let parserError = parser.error {
                if allowFeedDiscovery,
                   let sourceURL = request.url,
                   data.isProbablyHTML,
                   await fetchDiscoveredFeed(from: data, sourceURL: sourceURL, originalSource: source) {
                    return
                }
                // Keep the error from feed discovery if it was set; otherwise use parser error
                if error == nil {
                    error = parserError
                }
                items = []
                return
            }

            items = parsedItems
            let http = httpResponse as? HTTPURLResponse
            let fetchMeta = RSSFeedFetchMetadata(
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                lastFetchedAt: Date()
            )
            self.response = .updated(items: parsedItems, metadata: fetchMeta, feedInfo: parser.feedInfo)

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

    private func fetchDiscoveredFeed(from data: Data, sourceURL: URL, originalSource: RSSSource) async -> Bool {
        let candidates = RSSFeedDiscovery.feedURLs(inHTML: data, baseURL: sourceURL)
        var lastDiscoveryError: String?
        for candidate in candidates where candidate.absoluteString != sourceURL.absoluteString {
            var resolvedSource = originalSource
            resolvedSource.url = candidate.absoluteString
            await fetchItems(from: resolvedSource, metadata: nil, allowFeedDiscovery: false)
            if error == nil, response != nil || !items.isEmpty {
                resolvedFeedURL = candidate.absoluteString
                resolvedHomepageURL = sourceURL.absoluteString
                return true
            }
            // Save the best error from discovery attempts
            if lastDiscoveryError == nil, let err = error {
                lastDiscoveryError = err
            }
        }
        // Surface the discovery error instead of the generic parser error
        if let discoveryError = lastDiscoveryError {
            error = discoveryError
        }
        return false
    }

    private func formattedHTTPError(statusCode: Int) -> String {
        let reason: String
        switch statusCode {
        case 401:
            reason = localized("此來源需要認證（401），請檢查 URL 是否包含帳號密碼，或是否為私人訂閱源。")
        case 403:
            reason = localized("伺服器拒絕存取（403），此來源可能封鎖了請求。")
        case 404:
            reason = localized("找不到此 RSS 來源（404），連結可能已失效。")
        case 429:
            reason = localized("請求過於頻繁（429），請稍後再試。")
        case 500...599:
            reason = String(format: localized("伺服器錯誤（HTTP %d），來源暫時無法存取。"), statusCode)
        default:
            reason = String(format: localized("RSS 請求失敗：HTTP %d"), statusCode)
        }
        return reason
    }

    private func isATSBlockedError(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == -1022
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

// MARK: - RSSXMLParser (Legacy fallback)

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
        guard title != nil || homepageURL != nil || faviconURL != nil else { return nil }
        return RSSFeedInfo(title: title, homepageURL: homepageURL, faviconURL: faviconURL)
    }

    private let dateFormatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
         "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
         "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
         "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
         "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"].map { f in
            let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = f; return d
        }
    }()

    init(sourceId: String) { self.sourceId = sourceId }

    func parse(data: Data) -> [RSSItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() { return parsedItems }
        error = parser.parserError?.localizedDescription ?? localized("RSS XML 解析失敗。")
        return parsedItems
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        characterBuffer = ""
        switch name {
        case "feed": isAtom = true
        case "channel": insideChannel = true
        case "image": if insideChannel, !insideItem { insideChannelImage = true }
        case "item", "entry":
            insideItem = true; currentItem = [:]; currentLinkHref = nil; currentLinkRel = nil
        case "media:thumbnail", "media:content":
            if insideItem, currentItem["imageURL"] == nil, let url = attributeDict["url"] { currentItem["imageURL"] = url }
        case "enclosure":
            if insideItem, currentItem["imageURL"] == nil,
               let type = attributeDict["type"]?.lowercased(), type.hasPrefix("image/"),
               let url = attributeDict["url"] { currentItem["imageURL"] = url }
        case "link":
            if isAtom {
                let rel = (attributeDict["rel"] ?? "alternate").lowercased()
                let href = attributeDict["href"]; currentLinkRel = rel
                if insideItem { if rel == "alternate" || rel.isEmpty { currentLinkHref = href } }
                else if let href, !href.isEmpty {
                    if rel == "alternate" || rel.isEmpty { feedHomepageURL = feedHomepageURL ?? href }
                    else if rel == "icon" || rel == "shortcut icon" || rel == "apple-touch-icon" { feedFaviconURL = feedFaviconURL ?? href }
                }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { characterBuffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { characterBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let text = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard insideItem else { handleFeedElementEnd(name: name, text: text); characterBuffer = ""; return }
        switch name {
        case "title": currentItem["title"] = text
        case "link":
            if isAtom { if let href = currentLinkHref, !href.isEmpty { currentItem["link"] = href } }
            else { currentItem["link"] = text }
        case "description", "summary", "content", "content:encoded":
            if !text.isEmpty {
                let existing = Int(currentItem["contentPriority"] ?? "0") ?? 0
                let p: Int = (name == "content:encoded" || name == "content") ? 3 : (name == "description" ? 2 : 1)
                if p >= existing { currentItem["description"] = text; currentItem["contentHTML"] = text; currentItem["contentPriority"] = "\(p)" }
            }
        case "pubdate", "published", "updated":
            if !text.isEmpty, currentItem["pubDate"] == nil { currentItem["pubDate"] = text }
        case "author", "dc:creator":
            if !text.isEmpty { currentItem["author"] = text }
        case "item", "entry":
            if let item = buildItem() { parsedItems.append(item) }
            insideItem = false; currentItem = [:]; currentLinkHref = nil; currentLinkRel = nil
        default: break
        }
        characterBuffer = ""
    }

    private func handleFeedElementEnd(name: String, text: String) {
        switch name {
        case "title": if !insideChannelImage, !text.isEmpty { feedTitle = feedTitle ?? text }
        case "link":
            if isAtom { currentLinkHref = nil; currentLinkRel = nil }
            else if insideChannel, !insideChannelImage, !text.isEmpty { feedHomepageURL = feedHomepageURL ?? text }
        case "url": if insideChannelImage, !text.isEmpty { feedFaviconURL = feedFaviconURL ?? text }
        case "icon", "logo": if isAtom, !text.isEmpty { feedFaviconURL = feedFaviconURL ?? text }
        case "image": insideChannelImage = false
        case "channel": insideChannel = false
        default: break
        }
    }

    private func buildItem() -> RSSItem? {
        guard let title = currentItem["title"], !title.isEmpty,
              let link = currentItem["link"], !link.isEmpty else { return nil }
        let cleanTitle = RSSContentSanitizer.cleanText(title)
        let rawHTML = currentItem["description"] ?? ""
        let htmlMeta = contentMetadata(from: rawHTML)
        let summary = RSSContentSanitizer.summary(from: rawHTML)
        let pubDate = currentItem["pubDate"].flatMap { parseDate($0) } ?? htmlMeta.dateString.flatMap { parseDate($0) }
        let author = currentItem["author"].map { RSSContentSanitizer.cleanText($0) } ?? htmlMeta.author
        let rawImage = currentItem["imageURL"].flatMap { $0.isEmpty ? nil : $0 } ?? htmlMeta.imageURL
        let imageURL = rawImage.flatMap { URL(string: $0)?.upgradedToHTTPS().absoluteString }
        return RSSItem(id: stableID(title: cleanTitle, link: link), title: cleanTitle, link: link,
                       pubDate: pubDate, description: summary, contentHTML: rawHTML,
                       author: author, imageURL: imageURL, sourceId: sourceId)
    }

    private func contentMetadata(from html: String) -> (author: String?, dateString: String?, imageURL: String?) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else { return (nil, nil, nil) }
        let author = cleanOptionalText((try? body.select("address").first()?.text()) ?? nil)
        let timeEl = (try? body.select("time").first()) ?? nil
        let dateStr = cleanOptionalText((try? timeEl?.attr("datetime")) ?? (try? timeEl?.attr("pudate")) ?? (try? timeEl?.text()) ?? nil)
        let imgURL = cleanOptionalText((try? body.select("img[src]").first()?.attr("src")) ?? nil)
        return (author, dateStr, imgURL)
    }

    private func cleanOptionalText(_ text: String?) -> String? {
        guard let cleaned = text.map({ RSSContentSanitizer.cleanText($0) }), !cleaned.isEmpty else { return nil }
        return cleaned
    }

    private func stableID(title: String, link: String) -> String { link.isEmpty ? "\(sourceId)::\(title)" : link }

    private func parseDate(_ string: String) -> Date? {
        for f in dateFormatters { if let d = f.date(from: string) { return d } }
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
            _ = try? document.select("script, style, noscript, svg, iframe, [aria-hidden=true], [hidden], " +
                "[data-e2e=advertisement], [data-e2e=recommendations-heading], " +
                "[data-testid=byline], [data-testid=caption], [data-component=ad-slot]").remove()
            let paragraphs = ((try? document.select("p").array()) ?? [])
                .compactMap { try? $0.text() }.map(normalize).filter(isUsefulSummaryLine)
            let paragraphText = paragraphs.joined(separator: " ")
            if !paragraphText.isEmpty { return truncate(paragraphText, maxLength: maxLength) }
            if let bodyText = try? document.text() {
                let normalized = normalize(bodyText)
                if !normalized.isEmpty { return truncate(normalized, maxLength: maxLength) }
            }
        }
        return truncate(normalize(stripTags(decoded)), maxLength: maxLength)
    }

    private static func isUsefulSummaryLine(_ line: String) -> Bool {
        guard line.count >= 8 else { return false }
        let noisePrefixes = [
            "Article Information", "Author,", "Role,", "Reporting from,", "Image source,",
            "圖像來源", "图像来源", "圖片來源", "图片来源", "閱讀時間", "阅读时间",
            "廣告", "广告", "熱讀", "热读", "Skip ", "End of "
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
            ("&nbsp;", " "), ("&#160;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"), ("&hellip;", "\u{2026}"), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}")
        ]
        for (entity, value) in replacements { decoded = decoded.replacingOccurrences(of: entity, with: value) }
        return decoded
    }
}
