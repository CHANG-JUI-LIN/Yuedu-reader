import Foundation

/// Read-only remote library browsing; backup configuration is owned separately.
struct WebDAVBrowseClient {
    struct Entry: Identifiable, Hashable {
        var id: String { url.absoluteString }
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64
        var etag: String? = nil
        var lastModified: String? = nil
        var fileExtension: String { url.pathExtension.lowercased() }
        var isImportableBook: Bool { ["epub", "pdf", "txt", "md", "markdown"].contains(fileExtension) }
    }

    let serverUrl: String
    let username: String
    let password: String
    let httpClient: RemoteLibraryHTTPClient

    init(serverUrl: String, username: String, password: String, httpClient: RemoteLibraryHTTPClient? = nil) {
        self.serverUrl = serverUrl
        self.username = username
        self.password = password
        self.httpClient = httpClient ?? RemoteLibraryHTTPClient(baseURL: OPDSClient.url(from: serverUrl) ?? URL(string: "https://invalid.invalid")!, username: username, password: password)
    }

    var rootURL: URL? { OPDSCatalog.normalizedURL(serverUrl, kind: .webDAV) }

    func list(_ url: URL) async throws -> [Entry] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody.data(using: .utf8)
        let (data, response) = try await httpClient.data(for: request)
        try RemoteLibraryHTTPClient.validate(response)
        return try Self.parseListing(data: data, collectionURL: response.url ?? url)
    }

    static func parseListing(data: Data, collectionURL: URL) throws -> [Entry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = WebDAVPropfindParserDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.isMultistatus else { throw OPDSError.invalidFeed }
        let selfPath = normalizedPath(collectionURL)
        var seen = Set<URL>()
        return delegate.items.compactMap { item -> Entry? in
            guard let resolved = URL(string: item.href, relativeTo: collectionURL)?.absoluteURL,
                  OPDSClient.url(from: resolved.absoluteString) != nil,
                  normalizedPath(resolved) != selfPath, seen.insert(resolved).inserted else { return nil }
            let name = item.displayName?.isEmpty == false ? item.displayName! : resolved.lastPathComponent
            return Entry(url: resolved, name: name, isDirectory: item.isCollection, size: item.length,
                         etag: item.etag, lastModified: item.lastModified)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func download(_ entry: Entry) async throws -> URL {
        let (file, _) = try await httpClient.download(for: URLRequest(url: entry.url, timeoutInterval: 120))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(entry.fileExtension.isEmpty ? "dat" : entry.fileExtension)
        do { try FileManager.default.moveItem(at: file, to: destination) }
        catch {
            do { try FileManager.default.removeItem(at: file) }
            catch { AppLogger.error("Unable to clean WebDAV download: \(error)") }
            throw error
        }
        return destination
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>
    """

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }
}

private final class WebDAVPropfindParserDelegate: NSObject, XMLParserDelegate {
    struct Item {
        var href = ""
        var displayName: String?
        var isCollection = false
        var length: Int64 = 0
        var etag: String?
        var lastModified: String?
    }
    private(set) var items: [Item] = []
    private(set) var isMultistatus = false
    private var current: Item?
    private var properties: Item?
    private var status: Int?
    private var hasSuccessfulProperties = false
    private var stack: [(name: String, text: String)] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        if stack.isEmpty { isMultistatus = name == "multistatus" }
        stack.append((name, ""))
        switch name {
        case "response": current = Item(); hasSuccessfulProperties = false
        case "propstat": properties = Item(); status = nil
        case "collection": properties?.isCollection = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let item = stack.popLast() else { return }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.name {
        case "href": if stack.last?.name == "response" { current?.href = text }
        case "displayname": properties?.displayName = text
        case "getcontentlength": properties?.length = Int64(text) ?? 0
        case "getetag": properties?.etag = text
        case "getlastmodified": properties?.lastModified = text
        case "status": if stack.last?.name == "propstat" { status = text.split(separator: " ").dropFirst().first.flatMap { Int($0) } }
        case "propstat":
            if let status, (200...299).contains(status), let values = properties {
                hasSuccessfulProperties = true
                if let name = values.displayName { current?.displayName = name }
                if values.isCollection { current?.isCollection = true }
                if values.length > 0 { current?.length = values.length }
                if let etag = values.etag { current?.etag = etag }
                if let modified = values.lastModified { current?.lastModified = modified }
            }
            properties = nil
        case "response":
            if let current, !current.href.isEmpty, hasSuccessfulProperties { items.append(current) }
            current = nil
        default: break
        }
    }
}
