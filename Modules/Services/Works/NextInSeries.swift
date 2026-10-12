import Foundation

/// Unified library 5d-6b: what Explore's 系列下一本 row shows (design §13.3; Phase 5 plan,
/// decisions 16 and 25).
///
/// For each book being read or read to the end, most recently opened first: the work of the
/// same series, by the same author, with the smallest number after the book's own. Only books
/// with a number count (decision 24): a series name alone does not say which book comes next.
/// - A book read to the end counts although 標記為已讀完 takes it out of 繼續閱讀: finishing
///   one is when the next is wanted. One taken out of 繼續閱讀 unfinished does not.
/// - A work 繼續閱讀 shows, or one read to the end on this device, is never offered; the next
///   number after it is.
/// - One card per series and per work, a shelf copy before an indexed file.
///
/// Pure, and run off the main actor, as `RelatedWorks` is.
enum NextInSeries {
    /// - Parameters:
    ///   - seeds: 繼續閱讀's copies and the copies read to the end (`SourceItemKey.copy`), most
    ///     recently opened first.
    ///   - continueReading: 繼續閱讀's copies.
    ///   - finished: shelf copies read to the end (`ReadingBook.isReadToEnd`).
    ///   - shown: the nodes a card may stand for: shelf copies, and files a connection indexed.
    static func pick(in index: WorkIndex, seeds: [SourceItemKey], continueReading: Set<SourceItemKey>,
                     finished: Set<SourceItemKey>, shown: Set<SourceItemKey>, limit: Int) -> [SourceItemKey] {
        guard limit > 0 else { return [] }
        var entryAt: [SourceItemKey: Int] = [:]
        for (position, entry) in index.entries.enumerated() { entryAt[entry.nodeKey] = position }
        var workOf: [SourceItemKey: Int] = [:]
        for (position, work) in index.works.enumerated() {
            for member in work.members { workOf[member] = position }
        }
        // The numbered books a card may stand for, by series.
        var bySeries: [String: [Int]] = [:]
        for (position, entry) in index.entries.enumerated()
        where shown.contains(entry.nodeKey) && entry.seriesIndex != nil {
            if let series = entry.seriesKey { bySeries[series, default: []].append(position) }
        }
        let excludedWorks = Set(continueReading.union(finished).compactMap { workOf[$0] })

        var picked: [SourceItemKey] = []
        var pickedWorks: Set<Int> = []
        var pickedSeries: Set<String> = []
        for copy in seeds {
            guard let position = entryAt[copy],
                  let placement = index.seriesPlacement(of: index.entries[position], workOf: workOf),
                  let number = placement.number, !pickedSeries.contains(placement.key),
                  let candidates = bySeries[placement.key] else { continue }
            let current = (series: placement.key, number: number, authorKeys: placement.authorKeys)
            let authors = Set(current.authorKeys)
            var best: Int?
            for candidate in candidates {
                let entry = index.entries[candidate]
                guard let number = entry.seriesIndex, number > current.number,
                      let work = workOf[entry.nodeKey], !excludedWorks.contains(work), !pickedWorks.contains(work),
                      authors.isEmpty || entry.authorKeys.isEmpty || !authors.isDisjoint(with: entry.authorKeys)
                else { continue }
                if let chosen = best, !precedes(entry, index.entries[chosen]) { continue }
                best = candidate
            }
            guard let best, let work = workOf[index.entries[best].nodeKey] else { continue }
            pickedSeries.insert(current.series)
            pickedWorks.insert(work)
            picked.append(index.entries[best].nodeKey)
            if picked.count == limit { break }
        }
        return picked
    }

    /// The smaller number first; for one number, a shelf copy before an indexed file, then key order.
    private static func precedes(_ lhs: WorkIndexEntry, _ rhs: WorkIndexEntry) -> Bool {
        guard let left = lhs.seriesIndex, let right = rhs.seriesIndex else { return false }
        if left != right { return left < right }
        let leftCopy = lhs.record.copyID != nil, rightCopy = rhs.record.copyID != nil
        if leftCopy != rightCopy { return leftCopy }
        return lhs.nodeKey.sortKey < rhs.nodeKey.sortKey
    }
}
