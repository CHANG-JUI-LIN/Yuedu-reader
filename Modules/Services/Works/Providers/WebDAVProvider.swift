import Foundation

/// A saved WebDAV connection (unified library 2a). `list` is the call `WebDAVBrowseModel`
/// makes; `browse` is built on it, so there is one listing path.
@MainActor
final class WebDAVProvider: CollectionBrowsing {
    let connection: OPDSCatalog
    private let client: WebDAVBrowseClient

    convenience init(connection: OPDSCatalog, store: OPDSCatalogStore) {
        self.init(connection: connection, client: store.webDAVClient(for: connection))
    }

    init(connection: OPDSCatalog, client: WebDAVBrowseClient) {
        self.connection = connection
        self.client = client
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: .webDAV, id: connection.id) }
    var displayName: String { connection.name }
    var availability: ProviderAvailability { .available }
    /// The connection's root, normalized as `WebDAVBrowseClient.rootURL` is.
    var rootURL: URL? { RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV) }

    /// WebDAV has no server search; the folder view filters what it listed.
    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .none, paginates: false)
    }

    /// One folder, `PROPFIND Depth: 1`.
    func list(_ url: URL) async throws -> [WebDAVBrowseClient.Entry] {
        do { return try await client.list(url) }
        catch { throw try SourceFailure.classify(error) }
    }

    /// Folders are locations; every file is an item. A file that is not an importable book has
    /// no acquisitions (1a's derivation), and one outside the root is left out.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let root = rootURL, let url = location.flatMap({ URL(string: $0.id) }) ?? rootURL else {
            throw SourceFailure(kind: .invalidAddress, underlying: OPDSError.invalidURL)
        }
        let listing = try await list(url)
        let connectionID = connection.id
        var entries: [CollectionEntry] = []
        for entry in listing {
            if entry.isDirectory {
                entries.append(.location(CollectionLocation(id: entry.url.absoluteString, title: entry.name)))
            } else if let record = SourceRecord.derived(from: entry, connectionID: connectionID, root: root) {
                entries.append(.item(record, WorkSummary(title: record.title, authors: [], cover: .generated(seed: record.title),
                                                         blurb: nil, language: nil, contentKind: record.contentKind)))
            }
        }
        return CollectionPage(entries: entries, next: nil)
    }
}
