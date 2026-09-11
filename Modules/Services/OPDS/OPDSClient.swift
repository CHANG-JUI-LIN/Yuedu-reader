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

    var isBook: Bool { !acquisitions.isEmpty }
    var isNavigation: Bool { acquisitions.isEmpty && navigationURL != nil }
    var bestAcquisition: OPDSAcquisition? {
        let order: [String: Int] = ["epub": 0, "pdf": 1, "txt": 2, "md": 3]
        return acquisitions.filter(\.isSupported).min { (order[$0.importExtension ?? ""] ?? 9) < (order[$1.importExtension ?? ""] ?? 9) }
    }
    var displayCoverURL: URL? { thumbnailURL ?? coverURL }
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
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/atom+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(for: url).data(for: request)
        // Calibre's OPDS search deliberately uses HTTP 404 for no matches. Only
        // that documented search response is empty; unrelated 404s remain errors.
        // Delete this compatibility branch when Calibre returns a valid empty feed.
        if Self.isCalibreEmptySearch(data: data, status: response.statusCode, kind: kind, isSearch: isSearch) {
            return OPDSFeed()
        }
        try RemoteLibraryHTTPClient.validate(response)
        return try Self.parseFeed(data: data, feedURL: response.url ?? url)
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

    static func parseFeed(data: Data, feedURL: URL) throws -> OPDSFeed {
        guard !data.isEmpty else { throw OPDSError.noData }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = OPDSFeedParserDelegate(feedURL: feedURL)
        parser.delegate = delegate
        let parsed = parser.parse()
        if delegate.rootName == "html" { throw OPDSError.loginPage }
        guard parsed, delegate.rootName == "feed" else { throw OPDSError.invalidFeed }
        return delegate.feed
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
    private var authors: [String] = []

    init(feedURL: URL) { self.feedURL = feedURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        if rootName == nil { rootName = name }
        let inherited = elements.last?.base ?? feedURL
        let base = attributes["xml:base"].flatMap { URL(string: $0, relativeTo: inherited)?.absoluteURL } ?? inherited
        elements.append((name, "", base))
        if name == "entry" { current = OPDSEntry(id: "", title: ""); authors = [] }
        if name == "link" { handleLink(attributes, base: base) }
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
            if ["p", "div", "br", "li"].contains(element.name) { elements[elements.count - 1].text += " " }
        }
        switch element.name {
        case "title":
            if parent == "entry" { current?.title = Self.plain(value, limit: 512) }
            else if parent == "feed" { feed.title = Self.plain(value, limit: 512) }
        case "id": if parent == "entry" { current?.id = value }
        case "name": if parent == "author", current != nil, !value.isEmpty { authors.append(Self.plain(value, limit: 256)) }
        case "summary", "content":
            if parent == "entry", current?.summary == nil, !value.isEmpty { current?.summary = Self.plain(value, limit: 8_000) }
        case "entry":
            guard var entry = current else { return }
            current = nil
            guard entry.isBook || entry.isNavigation else { return }
            entry.author = authors.isEmpty ? nil : authors.joined(separator: ", ")
            if entry.id.isEmpty { entry.id = entry.acquisitions.first?.url.absoluteString ?? entry.navigationURL?.absoluteString ?? "" }
            feed.entries.append(entry)
        default: break
        }
    }

    private static func plain(_ value: String, limit: Int) -> String {
        let bounded = String(value.prefix(limit * 4))
        do { return String(try SwiftSoup.parse(bounded).text().prefix(limit)) }
        catch {
            AppLogger.error("Unable to sanitize OPDS metadata: \(error)")
            return String(bounded.prefix(limit))
        }
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
        guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
              OPDSClient.url(from: resolved.absoluteString) != nil else { return }
        if current != nil {
            if rel.hasPrefix("http://opds-spec.org/acquisition") || rel.hasPrefix("https://opds-spec.org/acquisition") {
                current?.acquisitions.append(OPDSAcquisition(url: resolved, type: attributes["type"] ?? "", rel: rel, size: attributes["length"].flatMap(Int64.init)))
            } else if rel.hasSuffix("/image/thumbnail") { current?.thumbnailURL = resolved }
            else if rel.hasSuffix("/image") { current?.coverURL = resolved }
            else if type.contains("application/atom+xml") || rel == "subsection", current?.navigationURL == nil { current?.navigationURL = resolved }
        } else if rel == "next" { feed.nextPageURL = resolved }
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
