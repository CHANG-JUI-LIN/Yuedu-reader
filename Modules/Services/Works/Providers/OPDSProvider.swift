import Foundation

/// The OPDS calls `OPDSBrowseModel` makes, so that the saved-library list, the Gutenberg
/// storefront and `browse` share one fetch path per source (unified library 2a).
@MainActor
protocol OPDSFeedProviding: CollectionBrowsing {
    var rootURL: URL? { get }
    /// One feed. `isSearch` reaches the client: Calibre answers an empty search with HTTP 404.
    func feed(_ url: URL, isSearch: Bool) async throws -> OPDSFeed
    /// The URL that searches for `query`, or nil when the source has no search. `search` is
    /// what the root feed advertised.
    func searchURL(query: String, search: OPDSSearch?) async throws -> URL?
    /// The record of an item entry. A requirement, so Gutenberg's own is the one `browse` uses.
    var makeRecord: @Sendable (OPDSEntry) -> SourceRecord? { get }
    /// What opening an item entry needs; a requirement for the same reason.
    var makeOpening: @Sendable (OPDSEntry) -> ItemOpening { get }
}

extension OPDSFeedProviding {
    /// Entries the provider makes a record of are items (for OPDS, those with an acquisition;
    /// for Gutenberg, also its navigation links to a book); other navigation entries are
    /// locations. An entry with neither leads nowhere and is left out.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let url = cursor.flatMap({ URL(string: $0.value) }) ?? location.flatMap({ URL(string: $0.id) }) ?? rootURL else {
            throw SourceFailure(kind: .invalidAddress, underlying: OPDSError.invalidURL)
        }
        let feed = try await feed(url, isSearch: false)
        return await Self.page(from: feed, connectionID: instance.id, record: makeRecord, opening: makeOpening)
    }

    /// The mapping runs off the main actor: summaries are HTML until `plainMetadata` reads them.
    nonisolated static func page(from feed: OPDSFeed, connectionID: String, record: @Sendable (OPDSEntry) -> SourceRecord?,
                                 opening: @Sendable (OPDSEntry) -> ItemOpening) async -> CollectionPage {
        var entries: [CollectionEntry] = []
        for entry in feed.entries {
            if let made = record(entry) {
                entries.append(.item(made, .opds(entry, record: made, connectionID: connectionID), opening(entry)))
            } else if let navigation = entry.navigationURL {
                entries.append(.location(CollectionLocation(id: navigation.absoluteString, title: entry.title)))
            }
        }
        return CollectionPage(entries: entries, next: feed.nextPageURL.map { CollectionCursor(value: $0.absoluteString) })
    }

    var makeRecord: @Sendable (OPDSEntry) -> SourceRecord? {
        let id = instance.id
        let kind: RemoteLibraryKind = instance.type == .calibre ? .calibre : .opds
        return { $0.isBook ? SourceRecord.derived(from: $0, connectionID: id, connectionKind: kind) : nil }
    }

    var makeOpening: @Sendable (OPDSEntry) -> ItemOpening {
        let id = instance.id
        return { .opdsEntry($0, connectionID: id) }
    }
}

extension WorkSummary {
    /// What a card and 作品詳情 show of an OPDS item entry.
    nonisolated static func opds(_ entry: OPDSEntry, record: SourceRecord, connectionID: String) -> WorkSummary {
        WorkSummary(
            title: entry.title,
            authors: record.authors,
            cover: PublicLibrary.listCoverURL(for: entry, connectionID: connectionID)
                .map { .remote($0, headers: [:]) } ?? .generated(seed: entry.title),
            // A Gutenberg list entry's content is its creator or a download count
            // (`GutenbergBook.init?(entry:)`), never a description.
            blurb: connectionID == PublicLibraryID.gutenberg.rawValue
                ? nil : entry.summary.map { OPDSClient.plainMetadata($0, limit: WorkSummary.blurbLimit) },
            language: entry.language,
            contentKind: record.contentKind,
            category: entry.category
        )
    }
}

/// A saved OPDS or Calibre connection.
@MainActor
final class OPDSProvider: OPDSFeedProviding {
    let connection: OPDSCatalog
    /// Built on first use: making one reads the keychain, and listing providers must not.
    private lazy var client: OPDSClient = makeClient()
    private let makeClient: () -> OPDSClient

    convenience init(connection: OPDSCatalog, store: OPDSCatalogStore) {
        self.init(connection: connection) { store.client(for: connection) }
    }

    init(connection: OPDSCatalog, client: @escaping () -> OPDSClient) {
        self.connection = connection
        makeClient = client
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: ProviderType(connection.kind), id: connection.id) }
    var displayName: String { connection.name }
    var availability: ProviderAvailability { .available }
    var rootURL: URL? { URL(string: connection.url) }

    /// An OPDS feed advertises its search only once fetched, and this answers without a
    /// request; Calibre and Calibre-Web are not told apart here either (`libraryInfo()` would
    /// be one).
    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .unknown, paginates: true)
    }

    func feed(_ url: URL, isSearch: Bool) async throws -> OPDSFeed {
        do { return try await client.fetchFeed(url, isSearch: isSearch) }
        catch { throw try SourceFailure.classify(error) }
    }

    func searchURL(query: String, search: OPDSSearch?) async throws -> URL? {
        guard let search else { return nil }
        do { return try await client.searchFeedURL(search: search, query: query) }
        catch { throw try SourceFailure.classify(error) }
    }
}

/// The built-in Project Gutenberg catalog. Its transport (with the UI-test fixtures) and its
/// search URL live here, not as special cases in `OPDSBrowseModel` (design §9, audit §9).
@MainActor
final class GutenbergProvider: OPDSFeedProviding {
    private let availabilitySource: PublicLibraryAvailability
    private let transport: (URL) async throws -> OPDSFeed

    init(availability: PublicLibraryAvailability, transport: @escaping (URL) async throws -> OPDSFeed = PublicLibraryFeedTransport.fetch) {
        availabilitySource = availability
        self.transport = transport
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue) }
    var displayName: String { PublicLibrary.gutenberg.name }
    var availability: ProviderAvailability { availabilitySource.isAvailable ? .available : .hiddenInRegion }
    var rootURL: URL? { URL(string: PublicLibrary.gutenberg.url) }

    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .explicitRequestOnly, paginates: true)
    }

    func feed(_ url: URL, isSearch: Bool) async throws -> OPDSFeed {
        do { return try await transport(url) }
        catch { throw try SourceFailure.classify(error) }
    }

    func searchURL(query: String, search: OPDSSearch?) async throws -> URL? {
        PublicLibrary.gutenbergSearchURL(query: query)
    }

    /// Gutenberg's items are `GutenbergBook`s, keyed by ebook number (1a).
    var makeRecord: @Sendable (OPDSEntry) -> SourceRecord? {
        { GutenbergBook(entry: $0).map(SourceRecord.derived(from:)) }
    }

    /// Only called for entries `makeRecord` made a record of, which are `GutenbergBook`s.
    var makeOpening: @Sendable (OPDSEntry) -> ItemOpening {
        { entry in GutenbergBook(entry: entry).map(ItemOpening.gutenberg) ?? .opdsEntry(entry, connectionID: PublicLibraryID.gutenberg.rawValue) }
    }
}
