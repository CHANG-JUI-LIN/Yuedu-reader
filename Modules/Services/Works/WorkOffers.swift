import Foundation

/// Discovery 7b-1 (maintainer, 2026-10-13): where else the reader can read a work, known
/// without a request — the books their own sources already listed of it (what the home's
/// categories fetched, `ForYouCandidateStore`) and 青空文庫's catalog. 作品詳情 lists them among
/// its versions (`ShelfProvider.versions(of:aozora:)`).
///
/// A book is the work's when its title folds to the same `WorkMatchKey` and both name a
/// compatible author (the design's confidence B, `Technotes/UnifiedLibrary-2026-10-08-design.md`
/// §7). A work that names no author (none, or 「未知作者」) is matched by title when the books of
/// that title agree on an author (`WorkMatchKey.agreedAuthor`); only the agreeing ones are
/// offered.
enum WorkOffers {
    /// The tapped work's books among `books`, one per source (its first), each as its source's
    /// own version; a source not in `sources`, or turned off, offers nothing.
    static func books(of work: WorkDetailRoute, in books: [OnlineBook], sources: [UUID: BookSource]) -> [WorkDetailRoute] {
        guard let key = Key(work.summary.title, authors: work.summary.authors) else { return [] }
        var offered = Set<UUID>()
        var offers: [WorkDetailRoute] = []
        var matched: [(witness: String, authors: [String])] = []
        for book in books where !offered.contains(book.sourceId) {
            // The title first: folding costs ICU transforms (7a-5), and most books differ there.
            guard let source = sources[book.sourceId], source.enabled, key.matchesTitle(book.name),
                  let route = WorkDetailRoute(.onlineBook(book, source: source)),
                  key.matchesAuthors(route.record.authors),
                  route.record.contentKind == work.record.contentKind else { continue }
            offered.insert(book.sourceId)
            // The tapped book itself, met again, is not a witness to its own author.
            guard route.record.key != work.record.key else { continue }
            matched.append((book.sourceId.uuidString, route.record.authors))
            offers.append(route)
        }
        return key.agreeing(offers, authors: matched)
    }

    /// 青空文庫's works of the tapped work's title and author.
    static func aozora(of work: WorkDetailRoute, in index: AozoraCatalogIndex) -> [WorkDetailRoute] {
        guard work.record.key.instance.type != .aozora, work.record.contentKind == .text,
              let key = Key(work.summary.title, authors: work.summary.authors) else { return [] }
        let found = index.search(work.summary.title).compactMap { found in
            let route = WorkDetailRoute(.aozora(found, index: index))
            return route.flatMap { key.matchesTitle($0.summary.title) && key.matchesAuthors($0.summary.authors) ? $0 : nil }
        }
        // One catalog: its books are one place's word.
        return key.agreeing(found, authors: found.map { ("aozora", $0.summary.authors) })
    }

    /// A work's title and authors, folded once.
    private struct Key {
        let title: String
        let authors: [String]

        /// Nil without a title: such a work matches nothing. With no author (none, or only
        /// 「未知作者」), the title's books are matched when they agree on an author (`agreeing`).
        init?(_ title: String, authors: [String]) {
            self.title = WorkMatchKey.title(title)
            self.authors = WorkMatchKey.knownAuthors(authors).map(WorkMatchKey.author).filter { !$0.isEmpty }
            guard !self.title.isEmpty else { return nil }
        }

        func matchesTitle(_ title: String) -> Bool {
            WorkMatchKey.title(title) == self.title
        }

        /// A work with no author takes any book here; `agreeing` decides on them together.
        func matchesAuthors(_ authors: [String]) -> Bool {
            self.authors.isEmpty || WorkMatchKey.authorKeysCompatible(self.authors, authors.map(WorkMatchKey.author))
        }

        /// The books matched that are this work's: all of them with an author, each already
        /// compared; without one, those naming the author they agree on.
        func agreeing(_ offers: [WorkDetailRoute], authors matched: [(witness: String, authors: [String])]) -> [WorkDetailRoute] {
            guard authors.isEmpty, !offers.isEmpty else { return offers }
            guard let agreed = WorkMatchKey.agreedAuthor(matched) else { return [] }
            return agreed.agreeing.map { offers[$0] }
        }
    }
}
