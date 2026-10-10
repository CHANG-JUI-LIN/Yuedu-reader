import Foundation

/// Unified library 5c-4: what Explore's 「相關」 row shows (design §13.3: 同作者、同系列, and
/// the same work from another source once the work index exists; open decision 5).
///
/// Seeded by the copies 繼續閱讀 shows, so the two rows agree, and never repeating them. In
/// order of evidence, each seed in recency order within each:
/// 1. the seeds' own works in another place (a WebDAV file of the book being read, another
///    copy of it), each member that is not the seed's own source item;
/// 2. other works of a seed's series;
/// 3. other works by a seed's authors.
/// Steps 2 and 3 show one card per work, a shelf copy before an indexed file.
///
/// Pure, and run off the main actor: at Phase 2's size the index holds 20,000 files.
enum RelatedWorks {
    /// - Parameters:
    ///   - seeds: the 繼續閱讀 copies' node keys (`SourceItemKey.copy`), most recent first.
    ///   - shown: the nodes a card may stand for: shelf copies, and files a connection indexed.
    ///     A reading record off the shelf is in the index and is left out here.
    static func pick(in index: WorkIndex, seeds: [SourceItemKey], shown: Set<SourceItemKey>, limit: Int) -> [SourceItemKey] {
        guard !seeds.isEmpty, limit > 0 else { return [] }
        var entryAt: [SourceItemKey: Int] = [:]
        var bySeries: [String: [Int]] = [:]
        var byAuthor: [String: [Int]] = [:]
        for (position, entry) in index.entries.enumerated() {
            entryAt[entry.nodeKey] = position
            guard shown.contains(entry.nodeKey) else { continue }
            if let series = entry.seriesKey { bySeries[series, default: []].append(position) }
            for author in Set(entry.authorKeys) { byAuthor[author, default: []].append(position) }
        }
        var workOf: [SourceItemKey: Int] = [:]
        for (position, work) in index.works.enumerated() {
            for member in work.members { workOf[member] = position }
        }

        let seedSet = Set(seeds)
        let seedEntries = seeds.compactMap { entryAt[$0].map { index.entries[$0] } }
        // The file a seed was downloaded from is the book being read, not a related one.
        let seedSources = Set(seedEntries.map(\.record.key))
        let seedWorks = Set(seeds.compactMap { workOf[$0] })

        var picked: [SourceItemKey] = []
        var pickedNodes: Set<SourceItemKey> = []
        var pickedWorks: Set<Int> = []
        func add(_ node: SourceItemKey) -> Bool {
            guard pickedNodes.insert(node).inserted else { return picked.count < limit }
            picked.append(node)
            return picked.count < limit
        }

        // 1. The seeds' works, from elsewhere.
        for seed in seeds {
            guard let work = workOf[seed] else { continue }
            for member in index.works[work].members.sorted(by: { $0.sortKey < $1.sortKey })
            where !seedSet.contains(member) && shown.contains(member) {
                guard let at = entryAt[member], !seedSources.contains(index.entries[at].record.key) else { continue }
                if !add(member) { return picked }
            }
        }

        // 2 and 3. Other works: one card each.
        func addWorks(of candidates: [Int]) -> Bool {
            var choice: [Int: Int] = [:]
            var order: [Int] = []
            for position in candidates {
                let entry = index.entries[position]
                guard let work = workOf[entry.nodeKey], !seedWorks.contains(work), !pickedWorks.contains(work) else { continue }
                if let current = choice[work] {
                    // A shelf copy stands for its work before an indexed file does.
                    if index.entries[current].record.copyID == nil, entry.record.copyID != nil { choice[work] = position }
                } else {
                    choice[work] = position
                    order.append(work)
                }
            }
            for work in order {
                pickedWorks.insert(work)
                if let position = choice[work], !add(index.entries[position].nodeKey) { return false }
            }
            return true
        }
        for seed in seedEntries {
            guard let series = seed.seriesKey, let candidates = bySeries[series] else { continue }
            if !addWorks(of: candidates.sorted { index.entries[$0].titleKey < index.entries[$1].titleKey }) { return picked }
        }
        for seed in seedEntries {
            for author in seed.authorKeys {
                guard let candidates = byAuthor[author] else { continue }
                if !addWorks(of: candidates.sorted { index.entries[$0].titleKey < index.entries[$1].titleKey }) { return picked }
            }
        }
        return picked
    }
}
