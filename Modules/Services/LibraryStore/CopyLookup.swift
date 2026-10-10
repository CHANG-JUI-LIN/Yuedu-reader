import Foundation

/// Unified library 2c: which copies on this device stand for a browse item, without scanning
/// every reading record per row (audit §8.3).
///
/// Keyed by `SourceItemKey`, like 2d's records, the work index and Phase 5's cards. A remote
/// library item, a Gutenberg book and an Aozora work each find their copies by the key 1a
/// derives for them. A second index by `(connection, entry id)` serves
/// `RemoteLibraryService.book(for:format:store:)`, whose match is per format.
///
/// Book-source copies are left out: their key needs `BookSourceStore`, which waits on the main
/// thread until the source library is read, and nothing browses them through this lookup.
struct CopyLookup {
    private var byKey: [SourceItemKey: [ReadingBook]] = [:]
    private var byRemoteEntry: [RemoteEntry: [ReadingBook]] = [:]

    private struct RemoteEntry: Hashable {
        let connectionID: String
        let entryID: String
    }

    /// What a browse row shows of its copies.
    enum Status: Hashable {
        /// Some copy is on the shelf.
        case onShelf
        /// Some copy recorded an offline file and none is on the shelf. Whether that file still
        /// exists is the detail page's question: checking per row would be disk I/O in `body`.
        case downloaded
    }

    init(books: [ReadingBook], context: SourceRecordContext) {
        for book in books {
            byKey[.copy(book.id), default: []].append(book)
            if let remote = book.remoteSource {
                byRemoteEntry[RemoteEntry(connectionID: remote.connectionID, entryID: remote.entryID), default: []].append(book)
            }
            guard !book.isOnline else { continue }
            let key = SourceRecord.derived(from: book, context: context).key
            if key != .copy(book.id) { byKey[key, default: []].append(book) }
        }
    }

    func copies(for key: SourceItemKey) -> [ReadingBook] {
        byKey[key] ?? []
    }

    /// The copies of one remote library entry, any format.
    func copies(connectionID: String, entryID: String) -> [ReadingBook] {
        byRemoteEntry[RemoteEntry(connectionID: connectionID, entryID: entryID)] ?? []
    }

    func status(for key: SourceItemKey) -> Status? {
        let copies = copies(for: key)
        if copies.contains(where: \.isInBookshelf) { return .onShelf }
        if copies.contains(where: { $0.remoteSource?.offlineFilename != nil }) { return .downloaded }
        return nil
    }
}

extension CopyLookup.Status {
    /// The existing strings: 已加入書架, 已下載.
    var title: String {
        switch self {
        case .onShelf: localized("已加入書架")
        case .downloaded: localized("已下載")
        }
    }
}

extension BookStore {
    /// The lookup for the shelf as it is now: built at most once per change of the shelf or of
    /// the remote library connections, on the next read after it.
    @MainActor
    func copyLookup(connections: OPDSCatalogStore = .shared) -> CopyLookup {
        let fingerprint = connections.catalogs.map { "\($0.id)\u{1F}\($0.kind.rawValue)\u{1F}\($0.url)" }
        return copyLookupMemo(fingerprint: fingerprint) {
            var kinds: [String: RemoteLibraryKind] = [:]
            var roots: [String: URL] = [:]
            for connection in connections.catalogs {
                kinds[connection.id] = connection.kind
                if connection.kind == .webDAV {
                    roots[connection.id] = RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV)
                }
            }
            let context = SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { kinds[$0] }, webDAVRoot: { roots[$0] })
            let books = readingBooks
            return SourcePerfTrace.span("library.copyLookup.build", "copies=\(books.count)", thresholdMs: 2) {
                CopyLookup(books: books, context: context)
            }
        }
    }
}
