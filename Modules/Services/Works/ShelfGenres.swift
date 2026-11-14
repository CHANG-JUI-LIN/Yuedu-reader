import Combine
import Foundation

extension RelatedWorks {
    /// The works that share a genre (`WorkIndexEntry.tagKeys`): one card per work, a shelf copy
    /// before an indexed file, by title, without the works of `excluding`.
    static func byGenre(in index: WorkIndex, genreKey: String, excluding: Set<SourceItemKey>,
                        shown: Set<SourceItemKey>, limit: Int) -> [SourceItemKey] {
        guard limit > 0, !genreKey.isEmpty else { return [] }
        let workOf = index.workPositions()
        let excludedWorks = Set(excluding.compactMap { workOf[$0] })
        var choice: [Int: Int] = [:]
        var unindexed: [Int] = []
        for (position, entry) in index.entries.enumerated()
        where shown.contains(entry.nodeKey) && !excluding.contains(entry.nodeKey) && entry.tagKeys.contains(genreKey) {
            guard let work = workOf[entry.nodeKey] else {
                unindexed.append(position)
                continue
            }
            guard !excludedWorks.contains(work) else { continue }
            if let current = choice[work] {
                // A shelf copy stands for its work before an indexed file does.
                if index.entries[current].record.copyID == nil, entry.record.copyID != nil { choice[work] = position }
            } else {
                choice[work] = position
            }
        }
        return (Array(choice.values) + unindexed)
            .sorted { (index.entries[$0].titleKey, index.entries[$0].nodeKey.sortKey)
                < (index.entries[$1].titleKey, index.entries[$1].nodeKey.sortKey) }
            .prefix(limit)
            .map { index.entries[$0].nodeKey }
    }
}

/// A copy's genres on 作品詳情 (maintainer, 2026-11-14: a copy's page has what a 來源配置's has):
/// the genres its metadata names, as links, and 同題材 — the other works on this device of the
/// first genre that has any. Read once per set of versions.
@MainActor
final class ShelfGenresModel: ObservableObject {
    struct Related: Equatable {
        let genre: String
        let works: [CollectionEntry]
    }

    @Published private(set) var genres: [String] = []
    /// Nil until read, and when no genre has another work: no section.
    @Published private(set) var related: Related?
    private var loaded: [SourceItemKey]?

    /// How many works 同題材's row shows.
    static let limit = 12

    typealias ReadGenres = @MainActor ([WorkDetailRoute], BookStore) async -> [String]
    typealias ReadWorks = @MainActor (String, [WorkDetailRoute], BookStore) async -> [CollectionEntry]

    private let readGenres: ReadGenres
    private let readWorks: ReadWorks

    init(readGenres: @escaping ReadGenres = { versions, store in await ShelfProvider(store: store).genres(of: versions) },
         readWorks: @escaping ReadWorks = { genre, versions, store in
             await ShelfProvider(store: store).works(ofGenre: genre, excluding: versions, limit: ShelfGenresModel.limit)
         }) {
        self.readGenres = readGenres
        self.readWorks = readWorks
    }

    /// Reads the genres of `versions`; nil (or none) clears them.
    func load(_ versions: [WorkDetailRoute]?, store: BookStore) async {
        let keys = versions?.map(\.nodeKey)
        guard keys != loaded || keys == nil else { return }
        guard let versions, !versions.isEmpty else {
            loaded = nil
            genres = []
            related = nil
            return
        }
        let found = await readGenres(versions, store)
        guard !Task.isCancelled else { return }
        genres = found
        var first: Related?
        for genre in found {
            let works = await readWorks(genre, versions, store)
            guard !Task.isCancelled else { return }
            if !works.isEmpty {
                first = Related(genre: genre, works: works)
                break
            }
        }
        related = first
        loaded = keys
    }
}
