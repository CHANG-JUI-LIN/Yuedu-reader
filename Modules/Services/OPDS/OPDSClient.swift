import Foundation
import SwiftSoup

struct OPDSAcquisition: Hashable {
    let url: URL
    let type: String
    let rel: String
    var size: Int64? = nil

    var importExtension: String? {
        let mime = type.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if mime.contains("epub") { return "epub" }
        if mime.contains("pdf") { return "pdf" }
        if mime.contains("markdown") { return "md" }
        if mime == "text/plain" { return "txt" }
        // Some catalogs omit the media type or use the generic binary type.
        // Their advertised filename still identifies a format the reader supports.
        if mime.isEmpty || mime == "application/octet-stream" {
            let ext = url.pathExtension.lowercased()
            if ["epub", "pdf", "txt", "md", "markdown"].contains(ext) {
                return ext == "markdown" ? "md" : ext
            }
        }
        return nil
    }
    var isSupported: Bool { importExtension != nil }
    var preference: Int {
        switch importExtension {
        case "epub": url.path.contains(".epub3") ? 0 : 1
        case "pdf": 2
        case "txt": 3
        case "md": 4
        default: 9
        }
    }
}

struct OPDSRelatedLink: Hashable {
    let title: String
    let url: URL
}

/// What an image link's rel makes it, for both feed formats. OPDS names the cover
/// `…/image` and the thumbnail `…/image/thumbnail`. The legacy names predate the spec and
/// are still all some servers write: Talebook writes only `http://opds-spec.org/cover` and
/// `…/thumbnail` (calibre 2.x's `/opds` did too, and calibre 3+ writes them beside the spec
/// rels); calibre 2.x's `/stanza` feed wrote only Lexcycle Stanza's `x-stanza-…` names.
/// A legacy name fills its role only when no spec rel does (`OPDSEntry.fillLegacyImages`).
struct OPDSImageRelation: Equatable {
    enum Role { case cover, thumbnail }
    let role: Role
    let isLegacy: Bool

    init?(_ rel: String) {
        let rel = rel.lowercased()
        if rel.hasSuffix("/image/thumbnail") { (role, isLegacy) = (.thumbnail, false) }
        else if rel.hasSuffix("/image") { (role, isLegacy) = (.cover, false) }
        else if Self.legacyThumbnails.contains(rel) { (role, isLegacy) = (.thumbnail, true) }
        else if Self.legacyCovers.contains(rel) { (role, isLegacy) = (.cover, true) }
        else { return nil }
    }

    /// One link's role from all of its rels (an OPDS 2 link may carry several): a spec rel
    /// before any legacy name, and the thumbnail when rels of the same kind disagree.
    init?(rels: [String]) {
        let relations = rels.compactMap(OPDSImageRelation.init)
        guard let relation = relations.first(where: { $0.role == .thumbnail && !$0.isLegacy })
                ?? relations.first(where: { !$0.isLegacy })
                ?? relations.first(where: { $0.role == .thumbnail })
                ?? relations.first else { return nil }
        self = relation
    }

    private static let legacyCovers: Set = ["http://opds-spec.org/cover", "x-stanza-cover-image"]
    private static let legacyThumbnails: Set = ["http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail"]
}

struct OPDSEntry: Identifiable, Hashable {
    var id: String
    var title: String
    var author: String?
    var summary: String?
    var navigationURL: URL?
    var acquisitions: [OPDSAcquisition] = []
    var thumbnailURL: URL?
    var coverURL: URL?
    var alternateURL: URL?
    var authorNames: [String] = []
    var relatedLinks: [OPDSRelatedLink] = []
    /// `dc:language` (OPDS 1) or `metadata.language` (OPDS 2), kept for the work index
    /// (unified library 1b).
    var language: String?
    /// `dc:identifier`s (OPDS 1) or `metadata.identifier` (OPDS 2), as the feed wrote them.
    var identifiers: [String] = []
    /// The first named category (OPDS 1 `<category>`, OPDS 2 `metadata.subject`), past
    /// classification codes, for 精選's card (decision 37). Nil when the feed names none.
    var category: String?

    /// Classification codes and the DCMI type, which name no category a reader reads: Gutenberg
    /// tags each book `LCC` "PL" and `DCMIType` "Text" before its subject headings.
    static func isCategoryScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty else { return true }
        return !scheme.hasSuffix("/lcc") && !scheme.hasSuffix("/dcmitype")
    }

    var isBook: Bool { !acquisitions.isEmpty }
    var isNavigation: Bool { acquisitions.isEmpty && navigationURL != nil }
    var bestAcquisition: OPDSAcquisition? {
        acquisitions.filter(\.isSupported).min { $0.preference < $1.preference }
    }
    var displayCoverURL: URL? { thumbnailURL ?? coverURL }

    /// The images an entry's links gave only under legacy rels (`OPDSImageRelation`), once
    /// its spec rels are all applied: a spec rel wins in whatever order the links came.
    mutating func fillLegacyImages(cover: URL?, thumbnail: URL?) {
        if coverURL == nil { coverURL = cover }
        if thumbnailURL == nil { thumbnailURL = thumbnail }
    }
}

enum OPDSSearch: Hashable {
    case template(String, baseURL: URL)
    case description(URL)
}

struct OPDSFeed {
    var title: String = ""
    var entries: [OPDSEntry] = []
    var nextPageURL: URL?
    var searchDescriptionURL: URL?
    var search: OPDSSearch?
    var alternateURL: URL?
    /// The catalog's newest additions (`http://opds-spec.org/sort/new`): a link of the feed's
    /// own, or else the first navigation entry with that relation. Home's 「最新」 follows it.
    var newestURL: URL?

    /// OPDS 1.2's relation for a catalog's newest additions, which OPDS 2 keeps.
    static func isNewestRelation(_ rel: String) -> Bool {
        let rel = rel.lowercased()
        return rel == "http://opds-spec.org/sort/new" || rel == "https://opds-spec.org/sort/new"
    }
}

enum OPDSError: LocalizedError {
    case invalidURL, unsupportedScheme, authenticationFailed, noData, invalidFeed, loginPage
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return localized("目錄網址格式無效")
        case .unsupportedScheme: return localized("僅支援 http / https 網址")
        case .authenticationFailed: return localized("認證失敗，請確認帳號和密碼")
        case .http(let code): return String(format: localized("連線失敗（HTTP %d）"), code)
        case .noData: return localized("伺服器未返回資料")
        case .invalidFeed: return localized("目錄資料格式無效")
        case .loginPage: return localized("伺服器返回登入網頁，請確認目錄網址與帳密")
        }
    }
}

struct OPDSClient {
    let username: String?
    let password: String?
    let kind: RemoteLibraryKind
    private let configuredTransport: RemoteLibraryHTTPClient?

    init(username: String? = nil, password: String? = nil, baseURL: URL? = nil,
         kind: RemoteLibraryKind = .opds, httpClient: RemoteLibraryHTTPClient? = nil) {
        self.username = username
        self.password = password
        self.kind = kind
        configuredTransport = httpClient ?? baseURL.map { RemoteLibraryHTTPClient(baseURL: $0, username: username, password: password) }
    }

    /// Retained for source compatibility. Covers now use `coverSession`; putting
    /// Basic credentials in view-provided headers bypasses Digest and leaks them.
    var coverHeaders: [String: String] { [:] }
    var coverSession: URLSession? { configuredTransport?.session }

    static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func transport(for url: URL) -> RemoteLibraryHTTPClient {
        configuredTransport ?? RemoteLibraryHTTPClient(baseURL: url, username: username, password: password)
    }

    func fetchFeed(_ url: URL, isSearch: Bool = false) async throws -> OPDSFeed {
        guard Self.url(from: url.absoluteString) != nil else { throw OPDSError.unsupportedScheme }
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("publicLibrary.opds.load", url.path, since: started, thresholdMs: 0) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        // Atom stays preferred, so servers offering both keep answering as before.
        request.setValue("application/atom+xml,application/xml;q=0.9,application/opds+json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(for: url).data(for: request)
        // Calibre's OPDS search deliberately uses HTTP 404 for no matches. Only
        // that documented search response is empty; unrelated 404s remain errors.
        // Delete this compatibility branch when Calibre returns a valid empty feed.
        if Self.isCalibreEmptySearch(data: data, status: response.statusCode, kind: kind, isSearch: isSearch) {
            return OPDSFeed()
        }
        try RemoteLibraryHTTPClient.validate(response)
        return try Self.parseFeed(data: data, feedURL: response.url ?? url,
                                  contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    static func isCalibreEmptySearch(data: Data, status: Int, kind: RemoteLibraryKind, isSearch: Bool) -> Bool {
        guard kind == .calibre, isSearch, status == 404,
              let body = String(data: data, encoding: .utf8) else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Calibre may wrap the explicit message in its HTTP error HTML page.
        if trimmed == "No books found" { return true }
        do { return try SwiftSoup.parse(String(trimmed.prefix(16_384))).body()?.text().trimmingCharacters(in: .whitespacesAndNewlines) == "No books found" }
        catch { return false } // An unreadable error document is never an empty result.
    }

    /// One parser per format: OPDS 2 JSON by Content-Type, Atom otherwise.
    static func parseFeed(data: Data, feedURL: URL, contentType: String? = nil) throws -> OPDSFeed {
        if OPDS2FeedParser.handles(contentType: contentType) {
            return try OPDS2FeedParser.parse(data: data, feedURL: feedURL)
        }
        guard !data.isEmpty else { throw OPDSError.noData }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = OPDSFeedParserDelegate(feedURL: feedURL)
        parser.delegate = delegate
        let parsed = parser.parse()
        if delegate.rootName == "html" { throw OPDSError.loginPage }
        guard parsed, delegate.rootName == "feed" else { throw OPDSError.invalidFeed }
        var feed = delegate.feed
        for index in feed.entries.indices where feed.entries[index].isBook && feed.entries[index].alternateURL == nil {
            feed.entries[index].alternateURL = feed.alternateURL
        }
        return feed
    }

    func download(_ acquisition: OPDSAcquisition) async throws -> URL {
        let (file, _) = try await transport(for: acquisition.url).download(for: URLRequest(url: acquisition.url, timeoutInterval: 120))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(acquisition.importExtension ?? "dat")
        do { try FileManager.default.moveItem(at: file, to: destination) }
        catch {
            do { try FileManager.default.removeItem(at: file) }
            catch { AppLogger.error("Unable to clean OPDS download: \(error)") }
            throw error
        }
        return destination
    }

    func searchFeedURL(search: OPDSSearch, query: String) async throws -> URL? {
        switch search {
        case .template(let template, let baseURL):
            return Self.resolveSearchTemplate(template, baseURL: baseURL, query: query)
        case .description(let url):
            let (data, response) = try await transport(for: url).data(for: URLRequest(url: url, timeoutInterval: 30))
            try RemoteLibraryHTTPClient.validate(response)
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            let delegate = OpenSearchParserDelegate()
            parser.delegate = delegate
            guard parser.parse(), delegate.isDescription else { throw OPDSError.invalidFeed }
            guard let template = delegate.bestTemplate else { return nil }
            return Self.resolveSearchTemplate(template, baseURL: response.url ?? url, query: query)
        }
    }

    func searchFeedURL(descriptionURL: URL, query: String) async throws -> URL? {
        let raw = Self.decodedBraces(descriptionURL.absoluteString)
        return try await searchFeedURL(search: raw.contains("{searchTerms") ? .template(raw, baseURL: descriptionURL) : .description(descriptionURL), query: query)
    }

    static func resolveSearchTemplate(_ template: String, baseURL: URL, query: String) -> URL? {
        var template = decodedBraces(template)
        guard template.contains("{searchTerms}") || template.contains("{searchTerms?}") else { return nil }
        // The same strict unreserved encoding is safe in both path and query
        // templates; & / + # ? in a user's search never become URL structure.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        template = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
            .replacingOccurrences(of: "{searchTerms?}", with: encoded)
        for (key, value) in [("startIndex", "1"), ("startPage", "1"), ("count", "50"), ("language", "*"), ("inputEncoding", "UTF-8"), ("outputEncoding", "UTF-8")] {
            template = template.replacingOccurrences(of: "{\(key)}", with: value)
                .replacingOccurrences(of: "{\(key)?}", with: value)
        }
        template = template.replacingOccurrences(of: "\\{[^}]*\\?\\}", with: "", options: .regularExpression)
        guard !template.contains("{") else { return nil }
        guard let resolved = URL(string: template, relativeTo: baseURL)?.absoluteURL else { return nil }
        return Self.url(from: resolved.absoluteString)
    }

    /// Feed metadata may carry markup; both parsers reduce it to bounded plain text.
    static func plainMetadata(_ value: String, limit: Int) -> String {
        let bounded = String(value.prefix(limit * 4))
        do { return String(try SwiftSoup.parse(bounded).text().prefix(limit)) }
        catch {
            AppLogger.error("Unable to sanitize OPDS metadata: \(error)")
            return String(bounded.prefix(limit))
        }
    }

    /// What the Atom parser leaves where a block element (p, div, br, li) ended, so that a
    /// description keeps its paragraphs. Every other field reads it as a space.
    static let paragraphBreak = "\u{2029}"

    /// A description as plain text, one line per paragraph, whether the feed wrote the
    /// paragraphs as xhtml (the parser's `paragraphBreak`s) or as escaped HTML.
    static func plainParagraphs(_ value: String, limit: Int) -> String {
        let bounded = String(value.prefix(limit * 4))
        let text: String
        do {
            let document = try SwiftSoup.parseBodyFragment(bounded)
            for block in try document.select("p, div, br, li").array() {
                _ = try block.after(TextNode(paragraphBreak, nil))
            }
            text = try document.text()
        } catch {
            AppLogger.error("Unable to sanitize OPDS metadata: \(error)")
            text = bounded
        }
        let paragraphs = text.components(separatedBy: paragraphBreak)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return String(paragraphs.joined(separator: "\n").prefix(limit))
    }

    fileprivate static func decodedBraces(_ string: String) -> String {
        string.replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
    }
}

private final class OPDSFeedParserDelegate: NSObject, XMLParserDelegate {
    private(set) var feed = OPDSFeed()
    private(set) var rootName: String?
    private let feedURL: URL
    private var elements: [(name: String, text: String, base: URL)] = []
    private var current: OPDSEntry?
    /// The current entry leads to the newest additions (`OPDSFeed.isNewestRelation`).
    private var currentIsNewest = false
    /// A navigation entry's newest-additions link, used when the feed has no link of its own.
    private var newestEntryURL: URL?
    private var authors: [String] = []
    /// The current entry's images under legacy rels, applied when it ends.
    private var legacyCover: URL?
    private var legacyThumbnail: URL?

    init(feedURL: URL) { self.feedURL = feedURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        if rootName == nil { rootName = name }
        let inherited = elements.last?.base ?? feedURL
        let base = attributes["xml:base"].flatMap { URL(string: $0, relativeTo: inherited)?.absoluteURL } ?? inherited
        let parent = elements.last?.name
        elements.append((name, "", base))
        if name == "entry" {
            current = OPDSEntry(id: "", title: ""); currentIsNewest = false; authors = []
            legacyCover = nil; legacyThumbnail = nil
        }
        if name == "category", parent == "entry", current?.category == nil,
           OPDSEntry.isCategoryScheme(attributes["scheme"]) {
            let named = Self.plain(attributes["label"] ?? attributes["term"] ?? "", limit: 512)
            if !named.isEmpty { current?.category = named }
        }
        if name == "link" { handleLink(attributes, base: base) }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if feed.newestURL == nil { feed.newestURL = newestEntryURL }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !elements.isEmpty else { return }
        elements[elements.count - 1].text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = elements.popLast() else { return }
        let value = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elements.last?.name
        if !elements.isEmpty {
            elements[elements.count - 1].text += element.text
            if ["p", "div", "br", "li"].contains(element.name) { elements[elements.count - 1].text += OPDSClient.paragraphBreak }
        }
        switch element.name {
        case "title":
            if parent == "entry" { current?.title = Self.plain(value, limit: 512) }
            else if parent == "feed" { feed.title = Self.plain(value, limit: 512) }
        case "id": if parent == "entry" { current?.id = value }
        case "name": if parent == "author", current != nil, !value.isEmpty { authors.append(Self.plain(value, limit: 256)) }
        case "summary", "content":
            if parent == "entry", current?.summary == nil, !value.isEmpty { current?.summary = OPDSClient.plainParagraphs(value, limit: 8_000) }
        // The parser processes namespaces, so `dc:language` arrives as its local name.
        case "language":
            if parent == "entry", current?.language == nil, !value.isEmpty { current?.language = Self.plain(value, limit: 64) }
        case "identifier":
            if parent == "entry", !value.isEmpty, (current?.identifiers.count ?? 0) < 10 {
                current?.identifiers.append(Self.plain(value, limit: 512))
            }
        case "entry":
            guard var entry = current else { return }
            current = nil
            guard entry.isBook || entry.isNavigation else { return }
            if currentIsNewest, entry.isNavigation, newestEntryURL == nil { newestEntryURL = entry.navigationURL }
            entry.author = authors.isEmpty ? nil : authors.joined(separator: ", ")
            entry.authorNames = authors
            entry.fillLegacyImages(cover: legacyCover, thumbnail: legacyThumbnail)
            if entry.id.isEmpty { entry.id = entry.acquisitions.first?.url.absoluteString ?? entry.navigationURL?.absoluteString ?? "" }
            feed.entries.append(entry)
        default: break
        }
    }

    private static func plain(_ value: String, limit: Int) -> String {
        OPDSClient.plainMetadata(value.replacingOccurrences(of: OPDSClient.paragraphBreak, with: " "), limit: limit)
    }

    private func handleLink(_ attributes: [String: String], base: URL) {
        guard let href = attributes["href"], !href.isEmpty else { return }
        let rel = (attributes["rel"] ?? "").lowercased()
        let type = (attributes["type"] ?? "").lowercased()
        if current == nil, rel == "search" {
            let template = OPDSClient.decodedBraces(href)
            if template.contains("{searchTerms") { feed.search = .template(template, baseURL: base) }
            else if let resolved = URL(string: href, relativeTo: base)?.absoluteURL { feed.search = .description(resolved) }
            feed.searchDescriptionURL = URL(string: href, relativeTo: base)?.absoluteURL
            return
        }
        let image = current == nil ? nil : OPDSImageRelation(rel)
        // OPDS inline raster thumbnails are image data, never a navigation URL.
        if let image, image.role == .thumbnail, href.hasPrefix("data:image/"),
           href.utf8.count <= 2 * 1024 * 1024, let inline = URL(string: href) {
            applyImage(inline, image)
            return
        }
        guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
              OPDSClient.url(from: resolved.absoluteString) != nil else { return }
        if OPDSFeed.isNewestRelation(rel) {
            if current == nil {
                if feed.newestURL == nil { feed.newestURL = resolved }
                return
            }
            currentIsNewest = true
        }
        if rel == "alternate", type == "text/html" {
            if current != nil { current?.alternateURL = resolved }
            else { feed.alternateURL = resolved }
            return
        }
        if current != nil {
            if rel == "related", type.contains("application/atom+xml") {
                current?.relatedLinks.append(OPDSRelatedLink(title: Self.plain(attributes["title"] ?? "", limit: 512), url: resolved))
            }
            if rel.hasPrefix("http://opds-spec.org/acquisition") || rel.hasPrefix("https://opds-spec.org/acquisition") {
                current?.acquisitions.append(OPDSAcquisition(url: resolved, type: attributes["type"] ?? "", rel: rel, size: attributes["length"].flatMap(Int64.init)))
            } else if let image { applyImage(resolved, image) }
            else if type.contains("application/atom+xml") || rel == "subsection" || OPDSFeed.isNewestRelation(rel),
                    current?.navigationURL == nil { current?.navigationURL = resolved }
        } else if rel == "next" { feed.nextPageURL = resolved }
    }

    /// A spec rel sets its role, the last one winning; a legacy name is held for the
    /// entry's end, the first one winning.
    private func applyImage(_ url: URL, _ image: OPDSImageRelation) {
        switch (image.role, image.isLegacy) {
        case (.cover, false): current?.coverURL = url
        case (.thumbnail, false): current?.thumbnailURL = url
        case (.cover, true): if legacyCover == nil { legacyCover = url }
        case (.thumbnail, true): if legacyThumbnail == nil { legacyThumbnail = url }
        }
    }
}

private final class OpenSearchParserDelegate: NSObject, XMLParserDelegate {
    private(set) var bestTemplate: String?
    private(set) var isDescription = false
    private var atomTemplate: String?
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if depth == 0 { isDescription = elementName.lowercased() == "opensearchdescription" }
        depth += 1
        guard elementName.lowercased() == "url", let template = attributes["template"], template.contains("{searchTerms") else { return }
        if (attributes["type"] ?? "").lowercased().contains("atom") { if atomTemplate == nil { atomTemplate = template } }
        else if bestTemplate == nil { bestTemplate = template }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parserDidEndDocument(_ parser: XMLParser) { if let atomTemplate { bestTemplate = atomTemplate } }
}
