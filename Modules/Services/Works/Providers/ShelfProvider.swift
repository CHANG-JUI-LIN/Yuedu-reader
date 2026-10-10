import Foundation

/// The bookshelf as a collection (unified library 2a): its groups are locations, its books
/// items. Each item's record is the copy's, so it carries both the current source key and,
/// through `copyID`, the copy's own key. Built with the app's `BookStore`, which is not a
/// singleton, so the registry lists it only where a store is supplied.
@MainActor
final class ShelfProvider: CollectionBrowsing {
    private let store: BookStore

    init(store: BookStore) {
        self.store = store
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
        let opened = store.books
            .compactMap { book in book.lastOpenedDate.map { (book, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
        return items(Array(opened))
    }

    private static func cover(of book: ReadingBook) -> CoverReference {
        if let filename = book.coverImagePath, !filename.isEmpty {
            return .copyFile(StorageLocations.coverFileLocation(filename).path)
        }
        if let url = book.coverUrl.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true { return .remote(url, headers: [:]) }
        return .generated(seed: book.title)
    }
}
