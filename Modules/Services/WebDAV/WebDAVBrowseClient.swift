import Foundation

// MARK: - WebDAV Browse Client
//
// Lightweight read-only WebDAV client used by the bookshelf "import from WebDAV"
// flow. It reuses the credentials configured for WebDAV *sync* (`WebDAVManager`)
// but adds directory listing (PROPFIND, Depth: 1) and file download (GET) so the
// user can browse a remote folder tree and pull EPUB/TXT/Markdown files into the
// library. Persistence and backup logic still live in `WebDAVManager`.

struct WebDAVBrowseClient {

    struct Entry: Identifiable, Hashable {
        var id: String { url.absoluteString }
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64

        var fileExtension: String { url.pathExtension.lowercased() }

        /// Whether this file is a format the library importer can ingest.
        var isImportableBook: Bool {
            ["epub", "txt", "md", "markdown"].contains(fileExtension)
        }
    }

    let serverUrl: String
    let username: String
    let password: String

    private var authHeader: String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    /// Root collection URL derived from the configured server URL (trailing slash enforced).
    var rootURL: URL? {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withSlash = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        return URL(string: withSlash)
    }

    // MARK: - Directory Listing

    /// PROPFIND (Depth: 1) the given collection and return its children, folders first.
    func list(_ url: URL) async throws -> [Entry] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = Self.propfindBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        guard http.statusCode == 207 || http.statusCode == 200 else {
            throw WebDAVError.connectionFailed(http.statusCode)
        }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = WebDAVPropfindParserDelegate()
        parser.delegate = delegate
        parser.parse()

        let selfPath = Self.normalizedPath(url)
        var entries: [Entry] = []
        for item in delegate.items {
            guard let resolved = URL(string: item.href, relativeTo: url)?.absoluteURL else { continue }
            // The first response in a Depth:1 listing is the collection itself — skip it.
            if Self.normalizedPath(resolved) == selfPath { continue }
            let rawName = item.displayName?.isEmpty == false ? item.displayName! : resolved.lastPathComponent
            let name = rawName.removingPercentEncoding ?? rawName
            entries.append(Entry(url: resolved, name: name, isDirectory: item.isCollection, size: item.length))
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - File Download

    /// GET the entry into a temporary file and return its local URL.
    func download(_ entry: Entry) async throws -> URL {
        var request = URLRequest(url: entry.url, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else {
            throw WebDAVError.connectionFailed(http.statusCode)
        }

        let ext = entry.fileExtension.isEmpty ? "dat" : entry.fileExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".\(ext)")
        try data.write(to: tempURL)
        return tempURL
    }

    // MARK: - Helpers

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
    """

    /// Decoded path with any trailing slash removed, used to compare two collection URLs.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path.removingPercentEncoding ?? url.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }
}

// MARK: - PROPFIND XML Parser

/// Collects `<response>` rows from a WebDAV multistatus document. Namespace
/// processing is enabled, so `elementName` is the local name (e.g. "collection").
private final class WebDAVPropfindParserDelegate: NSObject, XMLParserDelegate {

    struct Item {
        var href: String = ""
        var displayName: String?
        var isCollection: Bool = false
        var length: Int64 = 0
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        buffer = ""
        switch elementName.lowercased() {
        case "response":   current = Item()
        case "collection": current?.isCollection = true
        default:           break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href":             if current?.href.isEmpty ?? false { current?.href = value }
        case "displayname":      if !value.isEmpty { current?.displayName = value }
        case "getcontentlength": current?.length = Int64(value) ?? 0
        case "response":
            if let item = current, !item.href.isEmpty { items.append(item) }
            current = nil
        default:                 break
        }
        buffer = ""
    }
}
