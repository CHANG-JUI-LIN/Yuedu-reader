import Foundation

/// The bookshelf as a collection (unified library 2a): its groups are locations, its books
/// items. Each item's record is the copy's, so it carries both the current source key and,
/// through `copyID`, the copy's own key. Built with the app's `BookStore`, which is not a
/// singleton, so the registry lists it only where a store is supplied.
@MainActor
final class ShelfProvider: CollectionBrowsing {
    private let store: BookStore
    /// Each WebDAV connection's root, which an indexed file's address is built under.
    private let webDAVRoots: @MainActor () -> [String: URL]

    init(store: BookStore, webDAVRoots: @escaping @MainActor () -> [String: URL] = ShelfProvider.liveWebDAVRoots) {
        self.store = store
        self.webDAVRoots = webDAVRoots
    }

    static func liveWebDAVRoots() -> [String: URL] {
        var roots: [String: URL] = [:]
        for connection in RemoteLibraryConnectionStore.shared.connections where connection.kind == .webDAV {
            roots[connection.id] = RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV)
        }
        return roots
    }

    var instance: SourceInstanceKey { .localLibrary }
    var displayName: String { localized("書架") }
    var availability: ProviderAvailability { .available }

    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .asYouType, paginates: false)
    }

    /// The root lists the groups, then every book on the shelf; a group lists its books.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        let books = store.books
        let shown: [ReadingBook]
        var entries: [CollectionEntry] = []
        if let location {
            let group = String(location.id.dropFirst("group/".count))
            shown = books.filter { $0.group == group }
        } else {
            entries = store.allGroups.map { .location(CollectionLocation(id: "group/\($0)", title: $0)) }
            shown = books
        }
        entries += items(shown)
        return CollectionPage(entries: entries, next: nil)
    }

    /// Each book as an item, its record made with the shelf's live context.
    func items(_ books: [ReadingBook]) -> [CollectionEntry] {
        let context = WorkIndexService.liveContext(for: books)
        return books.map { book in
            let record = SourceRecord.derived(from: book, context: context)
            return .item(record, WorkSummary(title: book.title, authors: record.authors, cover: Self.cover(of: book),
                                             blurb: nil, language: nil, contentKind: record.contentKind), .copy(book.id))
        }
    }

    /// 繼續閱讀: the copies opened most recently, newest first (design §13.3).
    func continueReading(limit: Int) -> [CollectionEntry] {
        items(recentlyOpened(limit: limit))
    }

    private func recentlyOpened(limit: Int) -> [ReadingBook] {
        Array(store.books
            .compactMap { book in book.lastOpenedDate.map { (book, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0))
    }

    /// 相關 (unified library 5c-4): what `RelatedWorks` picks around 繼續閱讀's copies, from
    /// the shelf and the WebDAV index. Empty when nothing has been opened.
    func related(limit: Int) async -> [CollectionEntry] {
        let seeds = recentlyOpened(limit: limit)
        guard !seeds.isEmpty else { return [] }
        let started = SourcePerfTrace.now
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(shelf.keys.map(SourceItemKey.copy)).union(files.keys)
        let seedKeys = seeds.map { SourceItemKey.copy($0.id) }
        let picked = await Task.detached(priority: .userInitiated) {
            RelatedWorks.pick(in: index, seeds: seedKeys, shown: shown, limit: limit)
        }.value

        let roots = webDAVRoots()
        let copies = Dictionary(items(picked.compactMap { key in
            UUID(uuidString: key.item).flatMap { key.instance == .localLibrary ? shelf[$0] : nil }
        }).compactMap { entry -> (SourceItemKey, CollectionEntry)? in
            guard case .item(_, _, .copy(let id)) = entry else { return nil }
            return (.copy(id), entry)
        }, uniquingKeysWith: { first, _ in first })
        let entries = picked.compactMap { key -> CollectionEntry? in
            if let copy = copies[key] { return copy }
            // A file whose connection was removed since the index was built has nowhere to open.
            guard let file = files[key], let root = roots[key.instance.id] else { return nil }
            return WebDAVProvider.item(for: file, root: root, connectionID: key.instance.id)
        }
        SourcePerfTrace.record("home.related", "seeds=\(seeds.count) works=\(index.works.count) shown=\(entries.count)",
                               since: started, thresholdMs: 0)
        return entries
    }

    private static func cover(of book: ReadingBook) -> CoverReference {
        if let filename = book.coverImagePath, !filename.isEmpty {
            return .copyFile(StorageLocations.coverFileLocation(filename).path)
        }
        if let url = book.coverUrl.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true { return .remote(url, headers: [:]) }
        return .generated(seed: book.title)
    }
}
