import Foundation

// Unified library 1c: works and editions, built from source records by a deterministic
// union-find (design §4, §7.2, §7.3). Everything here is a pure value; `WorkIndexService`
// feeds it the copies on this device and keeps the result.

/// Why two records are one work (design §7.2).
enum MatchEvidence: Hashable, Codable, Sendable {
    /// A-level: a shared external identifier.
    case identifier(ExternalIdentifier)
    /// A-level: the same item of the same place, e.g. two copies of one OPDS entry.
    case sameSourceItem
    /// B-level: equal `WorkMatchKey` titles and compatible authors. Shown as
    /// 「依書名與作者判斷」 and splittable.
    case titleAuthor
    /// The reader said so (`WorkDecision.sameWork`).
    case decision

    fileprivate var sortKey: String {
        switch self {
        case .identifier(let identifier): "0\(identifier.scheme.rawValue):\(identifier.value)"
        case .sameSourceItem: "1"
        case .titleAuthor: "2"
        case .decision: "3"
        }
    }
}

/// One piece of evidence between two records of a work.
struct MatchLink: Hashable, Codable, Sendable {
    var from: SourceItemKey
    var to: SourceItemKey
    var evidence: MatchEvidence
}

/// A decision of the reader's. They refer only to `SourceItemKey`s (design D3, §5). 1c
/// reads `sameWork` and `differentWorks`; the field decisions are 1d's.
enum WorkDecision: Hashable, Codable, Sendable {
    case sameWork(SourceItemKey, SourceItemKey, decidedAt: Date)
    case differentWorks(SourceItemKey, SourceItemKey, decidedAt: Date)
    case override(anchor: SourceItemKey, field: MetadataField, value: MetadataPayload, decidedAt: Date)
    /// `value` is the effective value when the lock was set, for fields `ReadingBook` does not
    /// hold: 1b's sidecar keeps only the newest value per field and place, so the locked one
    /// would not survive there. For title and authors it is nil: the lock stops the automatic
    /// paths from writing the copy, so the copy's own value is the frozen one, and a manual
    /// edit still shows.
    case lock(anchor: SourceItemKey, field: MetadataField, value: MetadataPayload?, decidedAt: Date)
    case chooseCandidate(anchor: SourceItemKey, field: MetadataField, from: SourceItemKey, decidedAt: Date)
}

/// What the index knows about one record: the record, every identifier known for it (its
/// own and its copy's sidecar), and its language.
struct WorkIndexEntry: Hashable, Codable, Sendable {
    var record: SourceRecord
    /// Sorted, so an entry encodes the same way every time.
    var identifiers: [ExternalIdentifier]
    var language: LanguageTag?
    /// `WorkMatchKey` of the title and of each author, computed once: folding goes through
    /// ICU's Traditional-Simplified transform (about 50 µs a string), and an unchanged copy
    /// keeps its entry, keys included, from one refresh to the next.
    var titleKey: String
    var authorKeys: [String]
    /// `WorkMatchKey` of the series the record's metadata names, for 相關 (unified library
    /// 5c-4). It never merges works: two books of a series are two works.
    var seriesKey: String?
    /// The record's number in that series, for 系列下一本 (5d-6b): from the same place as the
    /// series name, so a name and a number never come from two different series.
    var seriesIndex: Double?

    init(record: SourceRecord, extraIdentifiers: [ExternalIdentifier] = [], language: LanguageTag? = nil,
         series: String? = nil, seriesIndex: Double? = nil) {
        self.record = record
        self.identifiers = Set(record.identifiers).union(extraIdentifiers).sorted { $0.sortKey < $1.sortKey }
        self.language = language
        self.titleKey = WorkMatchKey.title(record.title)
        // 「未知作者」 is no author: the copies that name none are not one author's works.
        self.authorKeys = WorkMatchKey.knownAuthors(record.authors).map(WorkMatchKey.author).filter { !$0.isEmpty }
        self.seriesKey = series.map(WorkMatchKey.title).flatMap { $0.isEmpty ? nil : $0 }
        self.seriesIndex = seriesKey == nil ? nil : seriesIndex
    }

    /// The record's node in the index: a copy's own key, which is unique and does not change
    /// on 換源; otherwise the record's key.
    var nodeKey: SourceItemKey { record.copyKey ?? record.key }
}

struct Edition: Hashable, Codable, Sendable {
    /// `text/zh-Hant`, `text/zh` (script unknown), `text/und` (language unknown).
    var id: String
    var contentKind: ContentKind
    var language: LanguageTag?
    var members: [SourceItemKey]
}

struct Work: Hashable, Codable, Sendable {
    /// The smallest member node key. Derived, so it may change when members change;
    /// decisions never refer to it.
    var id: String
    var members: [SourceItemKey]
    var editions: [Edition]
    var links: [MatchLink]
    /// `WorkMatchKey` titles and authors of the members, for local search.
    var searchKeys: [String]

    /// Whether some member joined only by title and author, which the work page labels
    /// 「依書名與作者判斷」 and lets the reader split.
    var isMergedByTitleAndAuthor: Bool { links.contains { $0.evidence == .titleAuthor } }
}

struct WorkIndexPolicy: Hashable, Sendable {
    /// B-level merging (settled by the maintainer, 2026-10-10: yes). A policy value for
    /// tests and a later split view, not a feature flag.
    var titleAuthorMerging = true

    static let standard = WorkIndexPolicy()
}

struct WorkIndex: Hashable, Codable, Sendable {
    /// Sorted by node key.
    var entries: [WorkIndexEntry]
    /// Sorted by id.
    var works: [Work]

    static let empty = WorkIndex(entries: [], works: [])

    func work(containing key: SourceItemKey) -> Work? {
        works.first { $0.members.contains(key) }
    }

    func entries(of work: Work) -> [WorkIndexEntry] {
        let members = Set(work.members)
        return entries.filter { members.contains($0.nodeKey) }
    }

    /// Works whose title or author contains the query, compared by `WorkMatchKey`. Works
    /// with an equal title come first; each group stays in id order.
    func search(_ query: String) -> [Work] {
        let key = WorkMatchKey.title(query)
        guard !key.isEmpty else { return [] }
        let matches = works.filter { $0.searchKeys.contains { $0.contains(key) } }
        let exact = matches.filter { $0.searchKeys.contains(key) }
        return exact + matches.filter { !$0.searchKeys.contains(key) }
    }
}

// MARK: - Building

extension WorkIndex {
    /// Identifier schemes that merge (design §7.2's A-level). `epubUniqueIdentifier` is kept
    /// in the data but never merges: EPUB templates and tools reuse package ids.
    static let mergingSchemes: Set<ExternalIdentifier.Scheme> = [
        .isbn13, .calibreUUID, .gutenberg, .aozoraWork, .openLibraryWork, .openLibraryEdition, .wikidata,
    ]

    /// Design §7.3. The same entries and decisions, in any order, give the same index.
    ///
    /// 1. Pairs the reader split (`differentWorks`) are never joined, by any evidence.
    /// 2. A-level: the same source item; then each shared identifier.
    /// 3. B-level (`policy.titleAuthorMerging`): records in one `WorkMatchKey` title bucket,
    ///    with compatible authors on both sides.
    /// 4. `sameWork` decisions.
    ///
    /// Evidence (2, 3) never joins two groups whose content kinds differ, or whose known
    /// languages differ: the check is on the whole group at each join, so A(zh) ~ B(no
    /// language) ~ C(en) cannot chain zh and en together. A `sameWork` decision overrides the
    /// kind and language rules, not a `differentWorks` one: rejection always wins.
    static func build(
        entries input: [WorkIndexEntry],
        decisions: [WorkDecision] = [],
        policy: WorkIndexPolicy = .standard
    ) -> WorkIndex {
        // Node keys are unique (a copy's id). Should two entries share one anyway, the first in
        // a total order is kept, so the input order still does not matter.
        var seen = Set<SourceItemKey>()
        let entries = input
            .sorted { ($0.nodeKey.sortKey, $0.record.key.sortKey, $0.record.title) < ($1.nodeKey.sortKey, $1.record.key.sortKey, $1.record.title) }
            .filter { seen.insert($0.nodeKey).inserted }

        var groups = Groups(entries: entries)
        var links: [(Int, Int, MatchEvidence)] = []

        func indices(matching key: SourceItemKey) -> [Int] {
            entries.indices.filter { entries[$0].nodeKey == key || entries[$0].record.key == key }
        }
        var forbidden: [(Set<Int>, Set<Int>)] = []
        var merges: [([Int], [Int])] = []
        for decision in decisions.sorted(by: { $0.sortKey < $1.sortKey }) {
            switch decision {
            case .differentWorks(let a, let b, _): forbidden.append((Set(indices(matching: a)), Set(indices(matching: b))))
            case .sameWork(let a, let b, _): merges.append((indices(matching: a), indices(matching: b)))
            case .override, .lock, .chooseCandidate: break
            }
        }

        func join(_ a: Int, _ b: Int, _ evidence: MatchEvidence, automatic: Bool) {
            if groups.join(a, b, automatic: automatic, forbidden: forbidden) {
                links.append((a, b, evidence))
            }
        }

        // A-level: the same source item.
        var byItem: [SourceItemKey: [Int]] = [:]
        for index in entries.indices { byItem[entries[index].record.key, default: []].append(index) }
        for key in byItem.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            let members = byItem[key]!
            for other in members.dropFirst() { join(members[0], other, .sameSourceItem, automatic: true) }
        }

        // A-level: shared identifiers.
        var byIdentifier: [ExternalIdentifier: [Int]] = [:]
        for index in entries.indices {
            for identifier in entries[index].identifiers where mergingSchemes.contains(identifier.scheme) {
                byIdentifier[identifier, default: []].append(index)
            }
        }
        for identifier in byIdentifier.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            let members = byIdentifier[identifier]!
            for other in members.dropFirst() { join(members[0], other, .identifier(identifier), automatic: true) }
        }

        // B-level: title and author.
        if policy.titleAuthorMerging {
            var byTitle: [String: [Int]] = [:]
            for index in entries.indices where !entries[index].titleKey.isEmpty {
                byTitle[entries[index].titleKey, default: []].append(index)
            }
            for key in byTitle.keys.sorted() {
                let members = byTitle[key]!
                for (position, a) in members.enumerated() {
                    for b in members[(position + 1)...]
                    where WorkMatchKey.authorKeysCompatible(entries[a].authorKeys, entries[b].authorKeys) {
                        join(a, b, .titleAuthor, automatic: true)
                    }
                }
            }
        }

        // The reader's merges.
        for (left, right) in merges {
            for a in left { for b in right where a != b { join(a, b, .decision, automatic: false) } }
        }

        // Each group is a work.
        var membersByRoot: [Int: [Int]] = [:]
        for index in entries.indices { membersByRoot[groups.root(index), default: []].append(index) }
        var linksByRoot: [Int: [MatchLink]] = [:]
        for (a, b, evidence) in links {
            let (from, to) = entries[a].nodeKey.sortKey <= entries[b].nodeKey.sortKey ? (a, b) : (b, a)
            linksByRoot[groups.root(a), default: []].append(
                MatchLink(from: entries[from].nodeKey, to: entries[to].nodeKey, evidence: evidence)
            )
        }
        let works = membersByRoot.map { root, members -> Work in
            let memberEntries = members.map { entries[$0] }
            let searchKeys = Set(memberEntries.flatMap { [$0.titleKey] + $0.authorKeys }).filter { !$0.isEmpty }.sorted()
            return Work(
                id: memberEntries[0].nodeKey.sortKey,
                members: memberEntries.map(\.nodeKey),
                editions: editions(of: memberEntries),
                links: (linksByRoot[root] ?? []).sorted {
                    ($0.from.sortKey, $0.to.sortKey, $0.evidence.sortKey) < ($1.from.sortKey, $1.to.sortKey, $1.evidence.sortKey)
                },
                searchKeys: searchKeys
            )
        }.sorted { $0.id < $1.id }
        return WorkIndex(entries: entries, works: works)
    }

    /// Editions: language or script plus content kind (design §4). Calibre formats of one
    /// book have one language, so they share an edition.
    ///
    /// A record whose tag has no script joins the only edition of its language that has
    /// one (an `en` copy beside an `en-US` one); with none or several, the script-less
    /// records form their own edition. A record with no language joins the only edition of
    /// its kind; otherwise it goes to `und`. Neither guess ever splits a work.
    static func editions(of entries: [WorkIndexEntry]) -> [Edition] {
        var editions: [Edition] = []
        let kinds = Set(entries.map(\.record.contentKind)).sorted { $0.rawValue < $1.rawValue }
        for kind in kinds {
            let ofKind = entries.filter { $0.record.contentKind == kind }
            var byID: [String: Edition] = [:]
            func add(_ entry: WorkIndexEntry, to language: LanguageTag?) {
                let id = "\(kind.rawValue)/\(language?.identifier ?? "und")"
                byID[id, default: Edition(id: id, contentKind: kind, language: language, members: [])].members.append(entry.nodeKey)
            }
            for entry in ofKind { if let language = entry.language, language.script != nil { add(entry, to: language) } }
            let scripted = byID.values.compactMap(\.language)
            for entry in ofKind {
                guard let language = entry.language, language.script == nil else { continue }
                let candidates = scripted.filter { $0.language == language.language }
                add(entry, to: candidates.count == 1 ? candidates[0] : language)
            }
            for entry in ofKind where entry.language == nil {
                add(entry, to: byID.count == 1 ? byID.values.first!.language : nil)
            }
            editions += byID.values.sorted { $0.id < $1.id }
        }
        return editions
    }
}

/// The union-find, with what each group already holds so a join can be refused.
private struct Groups {
    private var parent: [Int]
    private var members: [[Int]]
    private var kinds: [Set<ContentKind>]
    private var languages: [Set<String>]

    init(entries: [WorkIndexEntry]) {
        parent = Array(entries.indices)
        members = entries.indices.map { [$0] }
        kinds = entries.map { [$0.record.contentKind] }
        languages = entries.map { Set([$0.language?.language].compactMap { $0 }) }
    }

    mutating func root(_ index: Int) -> Int {
        var current = index
        while parent[current] != current {
            parent[current] = parent[parent[current]]
            current = parent[current]
        }
        return current
    }

    /// Joins the groups of `a` and `b`, unless the reader split something across them or,
    /// for automatic evidence, their content kinds or known languages differ. Returns
    /// whether `a` and `b` are now in one group: true also when they already were, so
    /// redundant evidence is still recorded.
    mutating func join(_ a: Int, _ b: Int, automatic: Bool, forbidden: [(Set<Int>, Set<Int>)]) -> Bool {
        let ra = root(a), rb = root(b)
        if ra == rb { return true }
        for (left, right) in forbidden {
            let aHasLeft = members[ra].contains(where: left.contains), aHasRight = members[ra].contains(where: right.contains)
            let bHasLeft = members[rb].contains(where: left.contains), bHasRight = members[rb].contains(where: right.contains)
            if (aHasLeft && bHasRight) || (aHasRight && bHasLeft) { return false }
        }
        if automatic {
            guard kinds[ra].union(kinds[rb]).count <= 1, languages[ra].union(languages[rb]).count <= 1 else { return false }
        }
        let (keep, merge) = members[ra].count >= members[rb].count ? (ra, rb) : (rb, ra)
        parent[merge] = keep
        members[keep] += members[merge]
        kinds[keep].formUnion(kinds[merge])
        languages[keep].formUnion(languages[merge])
        members[merge] = []
        return true
    }
}

// MARK: - Orderings

extension SourceItemKey {
    /// A total order for deterministic output, joined by a control character no key part uses.
    var sortKey: String { "\(instance.type.rawValue)\u{1F}\(instance.id)\u{1F}\(item)" }
}

extension ExternalIdentifier {
    var sortKey: String { "\(scheme.rawValue):\(value)" }
}

private extension WorkDecision {
    var sortKey: String {
        switch self {
        case .differentWorks(let a, let b, _): "0\(a.sortKey)\u{1E}\(b.sortKey)"
        case .sameWork(let a, let b, _): "1\(a.sortKey)\u{1E}\(b.sortKey)"
        case .override(let anchor, let field, _, _): "2\(anchor.sortKey)\u{1E}\(field.rawValue)"
        case .lock(let anchor, let field, _, _): "3\(anchor.sortKey)\u{1E}\(field.rawValue)"
        case .chooseCandidate(let anchor, let field, let from, _): "4\(anchor.sortKey)\u{1E}\(field.rawValue)\u{1E}\(from.sortKey)"
        }
    }
}
