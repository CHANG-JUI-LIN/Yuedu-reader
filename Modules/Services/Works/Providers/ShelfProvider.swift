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
    /// What the home's categories fetched, which 作品詳情's versions read (7b-1).
    private let candidates: ForYouCandidateStore
    /// The installed sources, turned on or not.
    private let sources: @MainActor () -> [BookSource]

    init(store: BookStore, webDAVRoots: @escaping @MainActor () -> [String: URL] = ShelfProvider.liveWebDAVRoots,
         candidates: ForYouCandidateStore = .shared, sources: @escaping @MainActor () -> [BookSource] = { BookSourceStore.shared.sources }) {
        self.store = store
        self.webDAVRoots = webDAVRoots
        self.candidates = candidates
        self.sources = sources
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

    /// 搜索's 書架 section (unified search 4b-1): the shelf copies of the works whose title or
    /// author matches `query` by `WorkMatchKey`, works with an equal title first. Reads the
    /// index as last refreshed: `WorkIndexService.current()` before the first search, and
    /// again when the shelf changes.
    func searchCopies(_ query: String) -> [ReadingBook] {
        let works = store.workIndex.search(query)
        guard !works.isEmpty else { return [] }
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return works.flatMap(\.members).compactMap { key in
            guard key.instance == .localLibrary, let id = UUID(uuidString: key.item),
                  let book = shelf[id], seen.insert(id).inserted else { return nil }
            return book
        }
    }

    /// 繼續閱讀: the copies opened most recently, newest first (design §13.3), leaving out
    /// those taken out since they were last opened (5d-3c).
    func continueReading(limit: Int) -> [CollectionEntry] {
        items(recentlyOpened(limit: limit))
    }

    private func recentlyOpened(limit: Int, where included: (ReadingBook) -> Bool = \.isInContinueReading) -> [ReadingBook] {
        Array(store.books
            .compactMap { book in included(book) ? book.lastOpenedDate.map { (book, $0) } : nil }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0))
    }

    /// 相關 (unified library 5c-4): what `RelatedWorks` picks around the copy opened most
    /// recently, from the shelf and the WebDAV index, leaving out 繼續閱讀's copies. Empty when
    /// nothing has been opened.
    func related(limit: Int) async -> [CollectionEntry] {
        let opened = recentlyOpened(limit: limit)
        guard let seed = opened.first.map({ SourceItemKey.copy($0.id) }) else { return [] }
        let started = SourcePerfTrace.now
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(shelf.keys.map(SourceItemKey.copy)).union(files.keys)
        let continueReading = Set(opened.map { SourceItemKey.copy($0.id) })
        let picked = await Task.detached(priority: .userInitiated) {
            RelatedWorks.pick(in: index, seed: seed, continueReading: continueReading, shown: shown, limit: limit)
        }.value
        let entries = entries(for: picked, shelf: shelf, files: files)
        SourcePerfTrace.record("home.related", "continueReading=\(opened.count) works=\(index.works.count) shown=\(entries.count)",
                               since: started, thresholdMs: 0)
        return entries
    }

    /// 作品詳情's 作者其他作品 (Editorial Minimalism, 2026-10-12): what `RelatedWorks.byAuthors`
    /// picks for the authors of the page's versions, from the shelf and the WebDAV index,
    /// leaving out the works of those versions.
    func otherWorks(byAuthorsOf versions: [WorkDetailRoute], limit: Int) async -> [CollectionEntry] {
        let authorKeys = Array(Set(versions.flatMap(\.summary.authors).map(WorkMatchKey.author)))
        guard !authorKeys.isEmpty else { return [] }
        let started = SourcePerfTrace.now
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(shelf.keys.map(SourceItemKey.copy)).union(files.keys)
        let excluding = Set(versions.map(\.nodeKey))
        let pageNodes = versions.map(\.nodeKey)
        let picked = await Task.detached(priority: .userInitiated) {
            // 同系列 shows the page's series; this row leaves it out.
            let series = SeriesWorks.placement(of: pageNodes, in: index, workOf: index.workPositions())?.placement.key
            return RelatedWorks.byAuthors(in: index, authorKeys: authorKeys, excluding: excluding, shown: shown,
                                          excludingSeries: series, limit: limit)
        }.value
        let entries = entries(for: picked, shelf: shelf, files: files)
        SourcePerfTrace.record("works.detail.authorWorks.shelf", "authors=\(authorKeys.count) shown=\(entries.count)",
                               since: started, thresholdMs: 0)
        return entries
    }

    /// 作品詳情's 同系列 (Editorial Minimalism, 2026-10-12): the series of the page's versions
    /// and its volumes on the shelf and in the WebDAV index, by `SeriesWorks`; nil when no
    /// version records a series. The series' name is read back from the metadata that named
    /// it (a copy's sidecar, a file's package values), never its match key. Like 系列下一本, the
    /// first load waits for the one pass that reads the local copies' series
    /// (`SeriesNumberBackfill`): copies imported before 5d-6b recorded none.
    func series(of versions: [WorkDetailRoute]) async -> WorkSeriesShelf? {
        guard !versions.isEmpty else { return nil }
        await store.seriesNumberBackfill.runOnce()
        let started = SourcePerfTrace.now
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(shelf.keys.map(SourceItemKey.copy)).union(files.keys)
        let pageNodes = versions.map(\.nodeKey)
        let metadata = store.importedMetadata
        let found = await Task.detached(priority: .userInitiated) { () -> (name: String, number: Double?, volumes: [SeriesWorks.Volume])? in
            let workOf = index.workPositions()
            guard let (entry, placement) = SeriesWorks.placement(of: pageNodes, in: index, workOf: workOf) else { return nil }
            let values: [MetadataValue]
            if entry.record.copyID != nil, let id = UUID(uuidString: entry.nodeKey.item) {
                values = metadata.read(copyID: id)?.values ?? []
            } else {
                values = files[entry.nodeKey]?.values ?? []
            }
            guard let name = WorkIndexService.series(in: values, for: entry.record)?.name else {
                AppLogger.cache("⟐ a series in the work index has no name in its metadata",
                                context: ["node": entry.nodeKey.sortKey])
                return nil
            }
            let volumes = SeriesWorks.volumes(in: index, of: placement, pageNodes: Set(pageNodes), shown: shown, workOf: workOf)
            return (name, placement.number, volumes)
        }.value
        guard let found else { return nil }
        let volumes = found.volumes.compactMap { volume -> WorkSeriesShelf.Volume? in
            entries(for: [volume.key], shelf: shelf, files: files).first.map {
                WorkSeriesShelf.Volume(entry: $0, number: volume.number, isPageWork: volume.isPageWork)
            }
        }
        SourcePerfTrace.record("works.detail.series", "volumes=\(volumes.count)", since: started, thresholdMs: 0)
        return WorkSeriesShelf(name: found.name, number: found.number, volumes: volumes)
    }

    /// 系列下一本 (unified library 5d-6b): what `NextInSeries` picks after each book being read
    /// or read to the end, from the shelf and the WebDAV index. The first load reads the local
    /// copies' series numbers once (`SeriesNumberBackfill`), so it waits for that pass.
    func nextInSeries(limit: Int) async -> [CollectionEntry] {
        let opened = recentlyOpened(limit: limit) { $0.isInContinueReading || $0.isReadToEnd }
        guard !opened.isEmpty else { return [] }
        await store.seriesNumberBackfill.runOnce()
        let started = SourcePerfTrace.now
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let books = store.books
        let shelf = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = Set(shelf.keys.map(SourceItemKey.copy)).union(files.keys)
        let seeds = opened.map { SourceItemKey.copy($0.id) }
        let continueReading = Set(books.filter(\.isInContinueReading).map { SourceItemKey.copy($0.id) })
        let finished = Set(books.filter(\.isReadToEnd).map { SourceItemKey.copy($0.id) })
        let picked = await Task.detached(priority: .userInitiated) {
            NextInSeries.pick(in: index, seeds: seeds, continueReading: continueReading, finished: finished,
                              shown: shown, limit: limit)
        }.value
        let entries = entries(for: picked, shelf: shelf, files: files)
        SourcePerfTrace.record("home.nextInSeries", "seeds=\(seeds.count) works=\(index.works.count) shown=\(entries.count)",
                               since: started, thresholdMs: 0)
        return entries
    }

    /// 作品詳情's versions (5f): the tapped item, its copies on the shelf, and the other members
    /// of the works those belong to in the index that the reader knows (`WorkVersions.merge`,
    /// `WorkVersions.known`). Only shelf copies and WebDAV files are indexed, so a library or
    /// public-library book reaches its work through a copy of it.
    ///
    /// Then, with no request (7b-1, maintainer 2026-10-13): 青空文庫's work of the same title
    /// and author, and the books of it the reader's sources listed on the home (`WorkOffers`).
    ///
    /// A copy taken from a public library is listed as the library's book even when nothing
    /// else lists it — opened from 書架 or 繼續閱讀, its work holds no public-library item
    /// (2026-10-12: ホノルル from 書架 showed only 來源 書架).
    /// - Parameter aozora: 青空文庫's catalog, which a 青空文庫 copy's work is read from; without
    ///   it (not read yet, or no cache offline) the copy stands for itself.
    func versions(of tapped: WorkDetailRoute, aozora: AozoraCatalogIndex?) async -> [WorkDetailRoute] {
        let started = SourcePerfTrace.now
        let lookup = store.copyLookup()
        var copies = lookup.copies(for: tapped.record.key).filter(\.isInBookshelf)
        if case .copy(let id) = tapped.opening, !copies.contains(where: { $0.id == id }),
           let book = store.shelfRecord(id: id) {
            copies.append(book)
        }
        let index = await store.workIndex.current()
        let files = store.workIndex.indexedFiles
        // Read after the refresh, so a copy removed meanwhile is not offered.
        let shelf = Dictionary(store.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        copies = copies.filter { shelf[$0.id] != nil || $0.id == tapped.record.copyID }
        let seeds = [tapped.nodeKey] + copies.map { SourceItemKey.copy($0.id) }
        var members: [SourceItemKey] = []
        var seenWorks = Set<String>()
        for seed in seeds {
            guard let work = index.work(containing: seed), seenWorks.insert(work.id).inserted else { continue }
            members += index.entries(of: work).map(\.nodeKey)
        }
        let copyRoutes = items(copies).compactMap(WorkDetailRoute.init)
        let memberRoutes = WorkVersions.known(entries(for: members, shelf: shelf, files: files).compactMap(WorkDetailRoute.init),
                                              readFrom: { key in
            lookup.copies(for: key).contains { $0.isInBookshelf || $0.lastOpenedDate != nil }
        })
        let versions = WorkVersions.merge(
            tapped: tapped,
            copies: zip(copyRoutes, copies.map(\.lastOpenedDate)).map { ($0, $1) },
            members: memberRoutes + Self.publicLibraryOrigins(of: [tapped] + copyRoutes + memberRoutes, aozora: aozora)
                + (await offers(of: tapped, aozora: aozora)))
        SourcePerfTrace.record("works.detail.versions", "copies=\(copies.count) members=\(members.count) versions=\(versions.count)",
                               since: started, thresholdMs: 0)
        return versions
    }

    /// `WorkOffers`' versions of the tapped work, matched off the main actor: a full cache is
    /// a few thousand titles to fold.
    private func offers(of tapped: WorkDetailRoute, aozora: AozoraCatalogIndex?) async -> [WorkDetailRoute] {
        let started = SourcePerfTrace.now
        let installed = Dictionary(sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Dictionary(installed.values.map { ($0.bookSourceUrl, $0.id) }, uniquingKeysWith: { first, _ in first })
        let books = await candidates.savedBooks(sources: ids)
        let offers = await Task.detached(priority: .userInitiated) {
            (aozora.map { WorkOffers.aozora(of: tapped, in: $0) } ?? []) + WorkOffers.books(of: tapped, in: books, sources: installed)
        }.value
        SourcePerfTrace.record("works.detail.offers", "cached=\(books.count) offers=\(offers.count)", since: started, thresholdMs: 0)
        return offers
    }

    /// The public-library book each copy was taken from, where no version lists it already:
    /// a Gutenberg book by its number, a 青空文庫 work from the catalog.
    private static func publicLibraryOrigins(of versions: [WorkDetailRoute],
                                             aozora: AozoraCatalogIndex?) -> [WorkDetailRoute] {
        var listed = Set(versions.filter(\.readsItsCopies).map(\.record.key))
        var origins: [WorkDetailRoute] = []
        for copy in versions where copy.record.copyID != nil && !listed.contains(copy.record.key) {
            let key = copy.record.key
            let origin: WorkDetailRoute?
            switch key.instance.type {
            case .aozora:
                origin = aozora.flatMap { index in index.worksByID[key.item].map { WorkDetailRoute(.aozora($0, index)) } }
            case .gutenberg:
                origin = Int(key.item).map { number in
                    WorkDetailRoute(.gutenberg(GutenbergBook(id: number, title: copy.record.title,
                                                             author: copy.record.authors.first ?? "")))
                }
            case .opds, .calibre, .webDAV, .bookSource, .library, .bibliographic:
                // A remote library's item is listed through its connection's index or feed.
                origin = nil
            }
            if let origin, listed.insert(key).inserted { origins.append(origin) }
        }
        return origins
    }

    /// The picked nodes as items: a shelf copy as the shelf shows it, an indexed file as its
    /// connection does.
    private func entries(for picked: [SourceItemKey], shelf: [UUID: ReadingBook],
                         files: [SourceItemKey: IndexedFile]) -> [CollectionEntry] {
        let roots = webDAVRoots()
        let copies = Dictionary(items(picked.compactMap { key in
            UUID(uuidString: key.item).flatMap { key.instance == .localLibrary ? shelf[$0] : nil }
        }).compactMap { entry -> (SourceItemKey, CollectionEntry)? in
            guard case .item(_, _, .copy(let id)) = entry else { return nil }
            return (.copy(id), entry)
        }, uniquingKeysWith: { first, _ in first })
        return picked.compactMap { key -> CollectionEntry? in
            if let copy = copies[key] { return copy }
            // A file whose connection was removed since the index was built has nowhere to open.
            guard let file = files[key], let root = roots[key.instance.id] else { return nil }
            return WebDAVProvider.item(for: file, root: root, connectionID: key.instance.id)
        }
    }

    private static func cover(of book: ReadingBook) -> CoverReference {
        if let filename = book.coverImagePath, !filename.isEmpty {
            return .copyFile(StorageLocations.coverFileLocation(filename).path)
        }
        if let url = book.coverUrl.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true { return .remote(url, headers: [:]) }
        return .generated(seed: book.title)
    }
}
