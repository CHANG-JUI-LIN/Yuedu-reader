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
        let context = WorkIndexService.liveContext(for: shown)
        entries += shown.map { book in
            let record = SourceRecord.derived(from: book, context: context)
            return .item(record, WorkSummary(title: book.title, authors: record.authors, cover: Self.cover(of: book),
                                             blurb: nil, language: nil, contentKind: record.contentKind))
        }
        return CollectionPage(entries: entries, next: nil)
    }

    private static func cover(of book: ReadingBook) -> CoverReference {
        if let path = book.coverImagePath, !path.isEmpty { return .copyFile(path) }
        if let url = book.coverUrl.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true { return .remote(url, headers: [:]) }
        return .generated(seed: book.title)
    }
}
