import Foundation

/// Where one index entry stands in a series: the series' `WorkMatchKey`, its number there, and
/// the node whose metadata named them, so the series' name can be read back as written.
struct SeriesPlacement: Hashable, Sendable {
    var key: String
    var number: Double?
    var authorKeys: [String]
    /// The entry that holds the series: the entry itself, or another member of its work.
    var namedBy: SourceItemKey
}

extension WorkIndex {
    /// Each member node's position in `works`.
    func workPositions() -> [SourceItemKey: Int] {
        var workOf: [SourceItemKey: Int] = [:]
        for (position, work) in works.enumerated() {
            for member in work.members { workOf[member] = position }
        }
        return workOf
    }

    /// The entry's series and number: its own when it has both; else those of another member
    /// of its work that has both (a WebDAV file of the book whose package has the number the
    /// copy's sidecar lacks); else its own series without a number, or another member's.
    /// 系列下一本 needs the number, 同系列 only the series.
    func seriesPlacement(of entry: WorkIndexEntry, workOf: [SourceItemKey: Int]) -> SeriesPlacement? {
        if let series = entry.seriesKey, let number = entry.seriesIndex {
            return SeriesPlacement(key: series, number: number, authorKeys: entry.authorKeys, namedBy: entry.nodeKey)
        }
        let members = workOf[entry.nodeKey].map { entries(of: works[$0]).sorted { $0.nodeKey.sortKey < $1.nodeKey.sortKey } } ?? []
        let authorKeys = { (member: WorkIndexEntry) in entry.authorKeys.isEmpty ? member.authorKeys : entry.authorKeys }
        if let member = members.first(where: { $0.seriesKey != nil && $0.seriesIndex != nil }), let series = member.seriesKey {
            return SeriesPlacement(key: series, number: member.seriesIndex, authorKeys: authorKeys(member), namedBy: member.nodeKey)
        }
        if let series = entry.seriesKey {
            return SeriesPlacement(key: series, number: nil, authorKeys: entry.authorKeys, namedBy: entry.nodeKey)
        }
        if let member = members.first(where: { $0.seriesKey != nil }), let series = member.seriesKey {
            return SeriesPlacement(key: series, number: nil, authorKeys: authorKeys(member), namedBy: member.nodeKey)
        }
        return nil
    }
}

/// 作品詳情's 同系列 (Editorial Minimalism, 2026-10-12; maintainer, by option: a series link
/// in the hero and a row at the foot, the other volumes by number): the works of the page's
/// series on the shelf and in the WebDAV index, the only places that record a series (an
/// imported book's package, a WebDAV file's). The same rules as 系列下一本: the same series
/// name by another author is another series, and one card stands for a work, a shelf copy
/// before an indexed file.
///
/// Pure, and run off the main actor, as `RelatedWorks` and `NextInSeries` are.
enum SeriesWorks {
    /// How many other volumes the row shows; the series page shows them all.
    static let limit = 12

    struct Volume: Hashable, Sendable {
        let key: SourceItemKey
        let number: Double?
        /// One of the page's own versions' works.
        let isPageWork: Bool
    }

    /// The series of the first of the page's nodes that has one.
    static func placement(of pageNodes: [SourceItemKey], in index: WorkIndex,
                          workOf: [SourceItemKey: Int]) -> (entry: WorkIndexEntry, placement: SeriesPlacement)? {
        var entryAt: [SourceItemKey: WorkIndexEntry] = [:]
        for entry in index.entries { entryAt[entry.nodeKey] = entry }
        for node in pageNodes {
            guard let entry = entryAt[node], let placement = index.seriesPlacement(of: entry, workOf: workOf) else { continue }
            return (entryAt[placement.namedBy] ?? entry, placement)
        }
        return nil
    }

    /// Every work of `series` among `shown`, the page's own included and marked, by number
    /// (fractional ones between their neighbours, unnumbered ones last), then by title.
    static func volumes(in index: WorkIndex, of series: SeriesPlacement, pageNodes: Set<SourceItemKey>,
                        shown: Set<SourceItemKey>, workOf: [SourceItemKey: Int]) -> [Volume] {
        let authors = Set(series.authorKeys)
        let pageWorks = Set(pageNodes.compactMap { workOf[$0] })
        var choice: [Int: (entry: WorkIndexEntry, number: Double?)] = [:]
        var unindexed: [(entry: WorkIndexEntry, number: Double?)] = []
        for entry in index.entries where shown.contains(entry.nodeKey) || pageNodes.contains(entry.nodeKey) {
            guard let placement = index.seriesPlacement(of: entry, workOf: workOf), placement.key == series.key,
                  authors.isEmpty || entry.authorKeys.isEmpty || !authors.isDisjoint(with: entry.authorKeys)
            else { continue }
            let candidate = (entry: entry, number: placement.number)
            guard let work = workOf[entry.nodeKey] else {
                unindexed.append(candidate)
                continue
            }
            if let current = choice[work], !stands(candidate, before: current) { continue }
            choice[work] = candidate
        }
        let volumes = choice.map { work, chosen in
            Volume(key: chosen.entry.nodeKey, number: chosen.number,
                   isPageWork: pageWorks.contains(work) || pageNodes.contains(chosen.entry.nodeKey))
        } + unindexed.map { Volume(key: $0.entry.nodeKey, number: $0.number, isPageWork: pageNodes.contains($0.entry.nodeKey)) }
        let titles = Dictionary(index.entries.map { ($0.nodeKey, $0.titleKey) }, uniquingKeysWith: { first, _ in first })
        return volumes.sorted { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (titles[lhs.key] ?? "", lhs.key.sortKey) < (titles[rhs.key] ?? "", rhs.key.sortKey)
            }
        }
    }

    /// Which entry stands for a work: one with a number, then a shelf copy before an indexed
    /// file, then key order.
    private static func stands(_ lhs: (entry: WorkIndexEntry, number: Double?),
                               before rhs: (entry: WorkIndexEntry, number: Double?)) -> Bool {
        if (lhs.number != nil) != (rhs.number != nil) { return lhs.number != nil }
        let leftCopy = lhs.entry.record.copyID != nil, rightCopy = rhs.entry.record.copyID != nil
        if leftCopy != rightCopy { return leftCopy }
        return lhs.entry.nodeKey.sortKey < rhs.entry.nodeKey.sortKey
    }

    /// 「第 2 冊」, 「第 2.5 冊」: the number as the reader's locale writes it, without a
    /// trailing 「.0」.
    static func numberText(_ number: Double) -> String {
        String(format: localized("第 %@ 冊"), number.formatted(.number.precision(.fractionLength(0...2))))
    }

    /// The hero's and 作品資訊's line: 「三體 · 第 2 冊」, or the name alone without a number.
    static func line(name: String, number: Double?) -> String {
        guard let number else { return name }
        return name + " · " + numberText(number)
    }
}

/// One 作品詳情's series, read in one pass so the hero's link and the row of
/// volumes never disagree.
struct WorkSeriesShelf: Hashable, Sendable {
    struct Volume: Hashable, Sendable {
        let entry: CollectionEntry
        let number: Double?
        let isPageWork: Bool
    }

    /// As the book's metadata writes it, not its match key.
    let name: String
    /// The page's own number in the series.
    let number: Double?
    /// Every volume, the page's own included, in series order: the series page.
    let volumes: [Volume]

    /// The other volumes: 同系列's row.
    var others: [Volume] { volumes.filter { !$0.isPageWork } }
    var line: String { SeriesWorks.line(name: name, number: number) }
}
