import Foundation

/// The key a book source detail URL is compared by: trimmed, without its fragment,
/// lowercased. The shelf's "already added" lookup (`BookStore.onlineBook(sourceId:bookInfoURL:)`)
/// and a book source record's item key both use it, so the two can never disagree.
enum OnlineBookURLKey {
    static func normalize(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "" }
        if var components = URLComponents(string: trimmed) {
            components.fragment = nil
            return (components.string ?? trimmed).lowercased()
        }
        return trimmed.lowercased()
    }
}

/// What a derivation needs to know beyond the value itself. `live()` reads the app's stores;
/// tests and the work index pass their own answers.
struct SourceRecordContext {
    /// The `bookSourceUrl` of a book source id, nil when it is gone.
    var bookSourceURL: (UUID) -> String?
    /// The kind of a remote library connection, nil when it is gone.
    var connectionKind: (String) -> RemoteLibraryKind?
    /// A WebDAV connection's root URL.
    var webDAVRoot: (String) -> URL?

    @MainActor
    static func live() -> SourceRecordContext {
        let connections = RemoteLibraryConnectionStore.shared
        return SourceRecordContext(
            bookSourceURL: { BookSourceStore.shared.source(id: $0)?.bookSourceUrl },
            connectionKind: { connections.connection(id: $0)?.kind },
            webDAVRoot: { id in connections.connection(id: id).flatMap { connections.webDAVClient(for: $0).rootURL } }
        )
    }
}

extension SourceRecord {
    // MARK: - A copy on this device

    /// The record of a copy's current source. Every copy record also carries the copy's own
    /// key through `copyID` (Phase 1 plan, decision 4).
    static func derived(from book: ReadingBook, context: SourceRecordContext) -> SourceRecord {
        let kind = ContentKind(book.resolvedPipelineKind)
        var record = SourceRecord(
            key: .copy(book.id),
            title: book.title,
            authors: authorList(book.author),
            language: nil,
            contentKind: kind,
            identifiers: [],
            copyID: book.id,
            acquisitions: [.openCopy(book.id)]
        )

        if let remote = book.remoteSource {
            if remote.connectionID == PublicLibraryID.gutenberg.rawValue {
                let number = ExternalIdentifier.gutenbergNumber(from: remote.entryID)
                record.key = SourceItemKey(
                    instance: SourceInstanceKey(type: .gutenberg, id: remote.connectionID),
                    item: number ?? remote.entryID
                )
                record.identifiers = Set([number.flatMap { ExternalIdentifier.normalized(.gutenberg, $0) }].compactMap { $0 })
                return record
            }
            guard let connectionKind = context.connectionKind(remote.connectionID) else {
                // The connection was removed. Its kind, and so the item key's form, is unknown;
                // the copy keeps its own key until the reader adds the connection again.
                return record
            }
            let instance = SourceInstanceKey(type: ProviderType(connectionKind), id: remote.connectionID)
            switch connectionKind {
            case .webDAV:
                let path = URL(string: remote.entryID).flatMap { url in
                    context.webDAVRoot(remote.connectionID).flatMap { webDAVRelativePath(of: url, under: $0) }
                }
                record.key = SourceItemKey(instance: instance, item: path ?? remote.entryID)
            case .opds, .calibre:
                record.key = SourceItemKey(instance: instance, item: remote.entryID)
                record.identifiers = identifiers(inEntryID: remote.entryID, connectionKind: connectionKind)
            }
            return record
        }

        if let aozora = book.aozora {
            if let workID = aozora.catalogWorkID,
               let identifier = ExternalIdentifier.normalized(.aozoraWork, workID) {
                record.key = SourceItemKey(
                    instance: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue),
                    item: identifier.value
                )
                record.identifiers = [identifier]
            }
            return record
        }

        if book.isOnline, let sourceID = book.bookSourceId {
            let sourceURL = context.bookSourceURL(sourceID) ?? "missing:\(sourceID.uuidString.lowercased())"
            record.key = SourceItemKey(
                instance: SourceInstanceKey(type: .bookSource, id: sourceURL),
                item: OnlineBookURLKey.normalize(book.bookInfoURL ?? book.source)
            )
            return record
        }

        // A local file, a browser import or an `importWeb` page: the copy is all there is.
        return record
    }

    // MARK: - Items not yet on the shelf

    static func derived(from entry: OPDSEntry, connectionID: String, connectionKind: RemoteLibraryKind) -> SourceRecord {
        let instance = SourceInstanceKey(type: ProviderType(connectionKind), id: connectionID)
        let formats = entry.acquisitions.compactMap(\.importExtension)
        return SourceRecord(
            key: SourceItemKey(instance: instance, item: entry.id),
            title: entry.title,
            authors: entry.authorNames.isEmpty ? authorList(entry.author ?? "") : entry.authorNames,
            language: nil,
            contentKind: contentKind(forExtensions: formats),
            identifiers: identifiers(inEntryID: entry.id, connectionKind: connectionKind),
            copyID: nil,
            acquisitions: uniqueFormats(formats).flatMap { [.readRemote(format: $0), .download(format: $0)] }
        )
    }

    /// Nil for a folder, and for an entry outside the connection's root.
    static func derived(from entry: WebDAVBrowseClient.Entry, connectionID: String, root: URL) -> SourceRecord? {
        guard !entry.isDirectory, let path = webDAVRelativePath(of: entry.url, under: root) else { return nil }
        let format = entry.fileExtension
        return SourceRecord(
            key: SourceItemKey(instance: SourceInstanceKey(type: .webDAV, id: connectionID), item: path),
            title: (entry.name as NSString).deletingPathExtension,
            authors: [],
            language: nil,
            contentKind: contentKind(forExtensions: [format]),
            identifiers: [],
            copyID: nil,
            acquisitions: entry.isImportableBook ? [.readRemote(format: format), .download(format: format)] : []
        )
    }

    /// - Parameter contentKind: a search result's kind, snapshotted when it arrived; nil infers it.
    static func derived(from book: OnlineBook, source: BookSource, contentKind: OnlineBookContentKind? = nil) -> SourceRecord {
        SourceRecord(
            key: SourceItemKey(
                instance: SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl),
                item: OnlineBookURLKey.normalize(book.bookUrl)
            ),
            title: book.name,
            authors: authorList(book.author),
            language: nil,
            contentKind: ContentKind(contentKind ?? book.inferredContentKind(source: source)),
            identifiers: [],
            copyID: nil,
            acquisitions: [.readOnline]
        )
    }

    static func derived(from work: AozoraWork) -> SourceRecord {
        let identifier = ExternalIdentifier.normalized(.aozoraWork, work.id)
        return SourceRecord(
            key: SourceItemKey(
                instance: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue),
                item: identifier?.value ?? work.id
            ),
            title: work.title,
            // Credits name people by id; their names need the catalog index (unified library 1b).
            authors: [],
            language: "ja",
            contentKind: .text,
            identifiers: Set([identifier].compactMap { $0 }),
            copyID: nil,
            acquisitions: [.download(format: "epub")]
        )
    }

    static func derived(from book: GutenbergBook) -> SourceRecord {
        let number = ExternalIdentifier.gutenbergNumber(from: book.id)
        let formats = book.entry?.acquisitions.compactMap(\.importExtension) ?? []
        return SourceRecord(
            key: SourceItemKey(
                instance: SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue),
                item: number ?? book.id
            ),
            title: book.title,
            authors: authorList(book.author),
            language: book.language,
            contentKind: .text,
            identifiers: Set([number.flatMap { ExternalIdentifier.normalized(.gutenberg, $0) }].compactMap { $0 }),
            copyID: nil,
            acquisitions: uniqueFormats(formats).flatMap { [.readRemote(format: $0), .download(format: $0)] }
        )
    }

    // MARK: - Helpers

    /// The path of `url` below `root`, percent-decoded so that two spellings of one path
    /// give one key. Nil, and logged, for a URL on another host or outside the root.
    static func webDAVRelativePath(of url: URL, under root: URL) -> String? {
        let decodedPath = { (url: URL) -> String in
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            return path.removingPercentEncoding ?? path
        }
        var rootPath = decodedPath(root)
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        let path = decodedPath(url)
        guard url.host?.lowercased() == root.host?.lowercased(), path.hasPrefix(rootPath), path.count > rootPath.count else {
            AppLogger.cache("⟐ WebDAV entry outside its connection's root; keeping its full URL as the key")
            return nil
        }
        return String(path.dropFirst(rootPath.count))
    }

    /// Identifiers an entry id carries: `urn:isbn:` anywhere, `urn:uuid:` as a Calibre uuid
    /// only on a Calibre connection (other OPDS servers mint uuids of their own).
    static func identifiers(inEntryID entryID: String, connectionKind: RemoteLibraryKind) -> Set<ExternalIdentifier> {
        let lowered = entryID.lowercased()
        var result = Set<ExternalIdentifier>()
        if lowered.hasPrefix("urn:isbn:"), let isbn = ExternalIdentifier.normalized(.isbn13, entryID) {
            result.insert(isbn)
        }
        if connectionKind == .calibre, lowered.hasPrefix("urn:uuid:"),
           let uuid = ExternalIdentifier.normalized(.calibreUUID, entryID) {
            result.insert(uuid)
        }
        return result
    }

    private static func authorList(_ author: String) -> [String] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private static func uniqueFormats(_ formats: [String]) -> [String] {
        var seen = Set<String>()
        return formats.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    private static func contentKind(forExtensions formats: [String]) -> ContentKind {
        let audio: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav"]
        let comic: Set<String> = ["cbz", "cbr", "cb7"]
        let lowered = Set(formats.map { $0.lowercased() })
        if !lowered.isEmpty, lowered.isSubset(of: audio) { return .audio }
        if !lowered.isEmpty, lowered.isSubset(of: comic) { return .comic }
        return .text
    }
}

extension ContentKind {
    init(_ pipeline: BookPipelineKind) {
        switch pipeline {
        case .manga: self = .comic
        case .audio: self = .audio
        case .epub, .txt, .html, .fixedPage: self = .text
        }
    }

    init(_ kind: OnlineBookContentKind) {
        switch kind {
        case .text: self = .text
        case .audio: self = .audio
        case .manga: self = .comic
        }
    }
}

extension ProviderType {
    init(_ kind: RemoteLibraryKind) {
        switch kind {
        case .opds: self = .opds
        case .webDAV: self = .webDAV
        case .calibre: self = .calibre
        }
    }
}
