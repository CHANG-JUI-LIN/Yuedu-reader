import Foundation

// MARK: - OPDS Client (OPDS 1.x / Atom)
//
// Read-only client for browsing OPDS catalogs and downloading acquisition links.
// Mirrors `WebDAVBrowseClient`: a small value-type client over `URLSession`, with
// an `XMLParser` delegate for the Atom feed. Supports optional HTTP Basic Auth.

// MARK: Models

struct OPDSAcquisition: Hashable {
    let url: URL
    let type: String   // MIME type, e.g. "application/epub+zip"
    let rel: String

    /// File extension for the supported import formats, else nil (unsupported).
    var importExtension: String? {
        let t = type.lowercased()
        if t.contains("epub") { return "epub" }
        if t.contains("markdown") { return "md" }
        if t.hasPrefix("text/plain") || t == "text/plain" { return "txt" }
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

    /// Preferred downloadable link: EPUB, then TXT, then Markdown.
    var bestAcquisition: OPDSAcquisition? {
        let supported = acquisitions.filter { $0.isSupported }
        let order: [String: Int] = ["epub": 0, "txt": 1, "md": 2]
        return supported.min { (order[$0.importExtension ?? ""] ?? 9) < (order[$1.importExtension ?? ""] ?? 9) }
    }

    var displayCoverURL: URL? { thumbnailURL ?? coverURL }
}

struct OPDSFeed {
    var title: String = ""
    var entries: [OPDSEntry] = []
    var nextPageURL: URL?
    var searchDescriptionURL: URL?
}

// MARK: Errors

enum OPDSError: LocalizedError {
    case invalidURL
    case unsupportedScheme
    case authenticationFailed
    case http(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return localized("目錄網址格式無效")
        case .unsupportedScheme:    return localized("僅支援 http / https 網址")
        case .authenticationFailed: return localized("認證失敗，請確認帳號和密碼")
        case .http(let code):       return String(format: localized("連線失敗（HTTP %d）"), code)
        case .noData:               return localized("伺服器未返回資料")
        }
    }
}

// MARK: Client

struct OPDSClient {
    let username: String?
    let password: String?

    private var authHeader: String? {
        guard let username, !username.isEmpty else { return nil }
        let credentials = "\(username):\(password ?? "")"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    /// Headers to use when loading cover images so authenticated catalogs work.
    var coverHeaders: [String: String] {
        guard let authHeader else { return [:] }
        return ["Authorization": authHeader]
    }

    /// Trim and validate a user-supplied catalog URL (http/https only).
    static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: Fetch

    func fetchFeed(_ url: URL) async throws -> OPDSFeed {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw OPDSError.unsupportedScheme
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/atom+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OPDSError.noData }
        if http.statusCode == 401 { throw OPDSError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else { throw OPDSError.http(http.statusCode) }

        return Self.parseFeed(data: data, feedURL: url)
    }

    /// Parse an OPDS Atom document into a feed. Exposed (no network) for testing.
    static func parseFeed(data: Data, feedURL: URL) -> OPDSFeed {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = OPDSFeedParserDelegate(feedURL: feedURL)
        parser.delegate = delegate
        parser.parse()
        return delegate.feed
    }

    // MARK: Download

    func download(_ acquisition: OPDSAcquisition) async throws -> URL {
        var request = URLRequest(url: acquisition.url, timeoutInterval: 120)
        request.httpMethod = "GET"
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OPDSError.noData }
        if http.statusCode == 401 { throw OPDSError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else { throw OPDSError.http(http.statusCode) }

        let ext = acquisition.importExtension ?? "epub"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".\(ext)")
        try data.write(to: tempURL)
        return tempURL
    }

    // MARK: Search

    /// Resolve an OpenSearch description (or already-templated href) into a usable
    /// feed URL for `query`. Returns nil if no `{searchTerms}` template can be found.
    func searchFeedURL(descriptionURL: URL, query: String) async throws -> URL? {
        let template: String?
        if descriptionURL.absoluteString.contains("{searchTerms}") {
            template = descriptionURL.absoluteString
        } else {
            template = try await fetchSearchTemplate(from: descriptionURL)
        }
        guard let template else { return nil }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var filled = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
        // Strip any remaining OpenSearch optional/required placeholders, e.g. {startIndex?}.
        filled = filled.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        return URL(string: filled, relativeTo: descriptionURL)?.absoluteURL
    }

    private func fetchSearchTemplate(from descriptionURL: URL) async throws -> String? {
        var request = URLRequest(url: descriptionURL, timeoutInterval: 30)
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = OpenSearchParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.bestTemplate
    }
}

// MARK: - Atom Feed Parser

/// Collects `<entry>` rows plus feed-level title / next / search links from an
/// OPDS Atom document. Namespace processing is on, so `elementName` is the local
/// name and `rel`/`type` (link attributes) are unprefixed.
private final class OPDSFeedParserDelegate: NSObject, XMLParserDelegate {

    private(set) var feed = OPDSFeed()

    private let feedURL: URL
    private var buffer = ""
    private var inEntry = false
    private var inAuthor = false
    private var current: OPDSEntry?

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        buffer = ""
        switch elementName.lowercased() {
        case "entry":
            inEntry = true
            current = OPDSEntry(id: "", title: "")
        case "author":
            inAuthor = true
        case "link":
            handleLink(attributeDict)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "title":
            if inEntry { current?.title = value }
            else if feed.title.isEmpty { feed.title = value }
        case "id":
            if inEntry, current?.id.isEmpty ?? false { current?.id = value }
        case "name":
            if inEntry, inAuthor, !value.isEmpty { current?.author = value }
        case "summary", "content":
            if inEntry, (current?.summary?.isEmpty ?? true), !value.isEmpty {
                current?.summary = value
            }
        case "author":
            inAuthor = false
        case "entry":
            finalizeEntry()
            inEntry = false
        default:
            break
        }
        buffer = ""
    }

    private func handleLink(_ attrs: [String: String]) {
        guard let href = attrs["href"], !href.isEmpty,
              let resolved = URL(string: href, relativeTo: feedURL)?.absoluteURL else { return }
        let rel = (attrs["rel"] ?? "").lowercased()
        let type = (attrs["type"] ?? "").lowercased()

        if inEntry {
            if rel.hasPrefix("http://opds-spec.org/acquisition") {
                current?.acquisitions.append(OPDSAcquisition(url: resolved, type: attrs["type"] ?? "", rel: rel))
            } else if rel == "http://opds-spec.org/image/thumbnail" || rel.hasSuffix("/image/thumbnail") {
                current?.thumbnailURL = resolved
            } else if rel == "http://opds-spec.org/image" || rel.hasSuffix("/image") {
                current?.coverURL = resolved
            } else if type.contains("application/atom+xml") || rel == "subsection" {
                if current?.navigationURL == nil { current?.navigationURL = resolved }
            }
        } else {
            if rel == "next" {
                feed.nextPageURL = resolved
            } else if rel == "search" {
                feed.searchDescriptionURL = resolved
            }
        }
    }

    private func finalizeEntry() {
        guard var entry = current else { return }
        current = nil
        // Drop entries that are neither books nor navigable.
        guard !entry.acquisitions.isEmpty || entry.navigationURL != nil else { return }
        if entry.id.isEmpty {
            entry.id = entry.bestAcquisition?.url.absoluteString
                ?? entry.navigationURL?.absoluteString
                ?? UUID().uuidString
        }
        feed.entries.append(entry)
    }
}

// MARK: - OpenSearch Description Parser

/// Extracts a usable search URL template (one containing `{searchTerms}`),
/// preferring an Atom result type.
private final class OpenSearchParserDelegate: NSObject, XMLParserDelegate {
    private(set) var bestTemplate: String?
    private var atomTemplate: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        guard elementName.lowercased() == "url",
              let template = attributeDict["template"], template.contains("{searchTerms}") else { return }
        let type = (attributeDict["type"] ?? "").lowercased()
        if type.contains("atom") {
            if atomTemplate == nil { atomTemplate = template }
        } else if bestTemplate == nil {
            bestTemplate = template
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if let atomTemplate { bestTemplate = atomTemplate }
    }
}
