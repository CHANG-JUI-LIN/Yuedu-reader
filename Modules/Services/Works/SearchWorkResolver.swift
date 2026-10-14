import Foundation

/// One thing a part of 搜索 found, as the resolver compares it (unified search 4c-2): plain
/// values only, so the merge runs off the main actor. What opening it needs (a frozen route,
/// a book-source row's snapshot) stays with the search page, found again by `id`.
struct SearchCandidate: Hashable, Sendable {
    /// Where it was found. Also the order a work takes its cover and title from (design §12.2:
    /// the shelf, then a library, then a source, then data).
    enum Kind: Int, Comparable, Hashable, Sendable {
        case shelf, library, publicLibrary, bookSource, bibliographic

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum ID: Hashable, Sendable {
        /// A shelf copy, a library's or a public library's item, an Open Library work: its node key.
        case item(SourceItemKey)
        /// A row of the book sources' results (`SearchBook.id`), which may stand for many origins.
        case bookSourceRow(UUID)
    }

    let id: ID
    let kind: Kind
    let title: String
    let titleKey: String
    let authorKeys: [String]
    let contentKind: ContentKind
    /// The language code alone (`LanguageTag.language`); nil when unknown.
    let language: String?
    let identifiers: Set<ExternalIdentifier>
    /// The items it stands for: its own, or each origin of a book-source row. A shelf copy's is
    /// the item it was taken from, so it meets that item's result (A level).
    let itemKeys: Set<SourceItemKey>
    let isReadable: Bool
    /// The places it counts as: one, or a book-source row's origins.
    let sourceCount: Int
}

extension SearchCandidate {
    /// An item as its part's frozen route has it.
    /// - Parameters:
    ///   - identifiers: what is known of it beyond its record: a shelf copy's sidecar (an ISBN
    ///     read from the package, the Open Library work its metadata was filled from).
    ///   - language: the work index's language for it, when its record names none.
    init(route: WorkDetailRoute, kind: Kind, identifiers: Set<ExternalIdentifier> = [], language: String? = nil) {
        self.init(
            id: .item(route.nodeKey),
            kind: kind,
            title: route.summary.title,
            titleKey: WorkMatchKey.title(route.summary.title),
            authorKeys: route.summary.authors.map(WorkMatchKey.author).filter { !$0.isEmpty },
            contentKind: route.record.contentKind,
            language: LanguageTag(route.record.language ?? route.summary.language)?.language ?? language,
            identifiers: route.record.identifiers.union(identifiers),
            itemKeys: [route.record.key],
            isReadable: route.isReadable,
            sourceCount: 1
        )
    }

    /// A row of the book sources' results, from its publication snapshot. Its keys were folded
    /// when its first book arrived (`SearchWorkKeys`).
    ///
    /// - Parameter sourceURL: a source's `bookSourceUrl` by id, nil when it is gone.
    @MainActor
    init(bookSourceRow row: SearchBook, sourceURL: (UUID) -> String?) {
        let keys = row.workKeys ?? SearchWorkKeys(name: row.name, author: row.author)
        self.init(
            id: .bookSourceRow(row.id),
            kind: .bookSource,
            title: row.displayName,
            titleKey: keys.title,
            authorKeys: keys.author.isEmpty ? [] : [keys.author],
            contentKind: ContentKind(row.inferredContentKind()),
            language: nil,
            identifiers: [],
            itemKeys: Set(row.origins.compactMap { origin in
                sourceURL(origin.sourceId).map {
                    SourceItemKey(instance: SourceInstanceKey(type: .bookSource, id: $0),
                                  item: OnlineBookURLKey.normalize(origin.bookUrl))
                }
            }),
            isReadable: true,
            sourceCount: max(row.origins.count, 1)
        )
    }
}

/// A work 搜索 found, made of every candidate that is the same work (unified search 4c-2).
struct UnifiedSearchResult: Identifiable, Hashable, Sendable {
    /// What the row's badge says (§12.2).
    enum Availability: Int, Comparable, Hashable, Sendable {
        case onShelf, readable, dataOnly

        static func < (lhs: Availability, rhs: Availability) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// In `Kind` order, then the order they were found in; the first gives the row its title
    /// and cover.
    let members: [SearchCandidate]
    let availability: Availability
    /// The places it can be read from, the shelf not among them, nor a place of data only
    /// (Open Library): the row's 「N 源」.
    let sourceCount: Int
    /// 3 the title is the query, 2 it starts with it, 1 it contains it (or the query contains
    /// the title), 0 otherwise (an author match).
    let score: Int

    var lead: SearchCandidate { members[0] }
    var id: SearchCandidate.ID { lead.id }
}

/// Merges 搜索's candidates into works by the work index's rules (design §7.2, unified search
/// 4c-2), deterministically: the same candidates in the same order give the same list.
///
/// - A: a shared identifier (ISBN, Calibre UUID, Open Library work…) or a shared item.
/// - B: the same `WorkMatchKey` title, both sides naming compatible authors, the same content
///   kind, and no two different known languages.
/// - Anything else stays its own work (C never merges).
enum SearchWorkResolver {
    static func resolve(_ candidates: [SearchCandidate], query: String) -> [UnifiedSearchResult] {
        guard !candidates.isEmpty else { return [] }
        var groups = UnionFind(count: candidates.count)

        // A: shared items and identifiers.
        var firstWithItem: [SourceItemKey: Int] = [:]
        var firstWithIdentifier: [ExternalIdentifier: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            for key in candidate.itemKeys {
                if let other = firstWithItem[key] { groups.union(index, other) } else { firstWithItem[key] = index }
            }
            for identifier in candidate.identifiers {
                if let other = firstWithIdentifier[identifier] { groups.union(index, other) } else { firstWithIdentifier[identifier] = index }
            }
        }

        // B: within each title, compatible authors of the same kind and language.
        var byTitle: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() where !candidate.titleKey.isEmpty && !candidate.authorKeys.isEmpty {
            byTitle[candidate.titleKey, default: []].append(index)
        }
        for indices in byTitle.values where indices.count > 1 {
            for (position, i) in indices.enumerated() {
                for j in indices[(position + 1)...] where sameWork(candidates[i], candidates[j]) {
                    groups.union(i, j)
                }
            }
        }

        var members: [Int: [Int]] = [:]
        var firstIndex: [Int: Int] = [:]
        for index in candidates.indices {
            let root = groups.find(index)
            members[root, default: []].append(index)
            if firstIndex[root] == nil { firstIndex[root] = index }
        }

        let queryKey = WorkMatchKey.title(LegadoSearchKeyword.matchingTitle(from: query))
        let results: [(result: UnifiedSearchResult, first: Int)] = members.map { root, indices in
            let ordered = indices.sorted { (candidates[$0].kind, $0) < (candidates[$1].kind, $1) }.map { candidates[$0] }
            let availability: UnifiedSearchResult.Availability =
                ordered.contains { $0.kind == .shelf } ? .onShelf
                : ordered.contains(where: \.isReadable) ? .readable : .dataOnly
            let result = UnifiedSearchResult(
                members: ordered,
                availability: availability,
                sourceCount: ordered.filter { $0.kind != .shelf && $0.isReadable }.reduce(0) { $0 + $1.sourceCount },
                score: ordered.map { score(titleKey: $0.titleKey, query: queryKey) }.max() ?? 0
            )
            return (result, firstIndex[root] ?? 0)
        }
        return results.sorted { a, b in
            if a.result.score != b.result.score { return a.result.score > b.result.score }
            if a.result.availability != b.result.availability { return a.result.availability < b.result.availability }
            let aLength = a.result.lead.title.count, bLength = b.result.lead.title.count
            if aLength != bLength { return aLength < bLength }
            if a.result.sourceCount != b.result.sourceCount { return a.result.sourceCount > b.result.sourceCount }
            return a.first < b.first
        }.map(\.result)
    }

    static func sameWork(_ a: SearchCandidate, _ b: SearchCandidate) -> Bool {
        a.titleKey == b.titleKey
            && a.contentKind == b.contentKind
            && (a.language == nil || b.language == nil || a.language == b.language)
            && WorkMatchKey.authorKeysCompatible(a.authorKeys, b.authorKeys)
    }

    /// The aggregator's tiers (`SearchAggregator.matchScore`) on work keys.
    static func score(titleKey: String, query: String) -> Int {
        guard !query.isEmpty, !titleKey.isEmpty else { return 0 }
        if titleKey == query { return 3 }
        if titleKey.hasPrefix(query) { return 2 }
        if titleKey.contains(query) || query.contains(titleKey) { return 1 }
        return 0
    }

    private struct UnionFind {
        private var parent: [Int]

        init(count: Int) { parent = Array(0..<count) }

        mutating func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        /// The smaller root wins, so the grouping does not depend on the order unions run in.
        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
    }
}
