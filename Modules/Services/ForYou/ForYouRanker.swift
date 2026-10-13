import Foundation

/// A book an input offered 為你推薦: a book-source category's, or a library row's on the home.
struct ForYouCandidate: Sendable {
    let entry: CollectionEntry
    /// The source it came from; a source's categories count as one for the mix.
    let source: String
    /// Its place in the input's own order.
    let position: Int
    /// Normalized (`ReadingGenreProfile.normalizedTags`).
    let tags: [String]
}

/// 為你推薦's order (Discovery Phase 7a-3), pure: dedupe, score, mix, explore, languages. It
/// only orders books; no rank or score is shown (`docs/design.md`: 不捏造排行或評分).
enum ForYouRanker {
    /// What 繼續閱讀 holds now.
    struct Recent: Sendable {
        var authors: [String] = []
        var tags: [String] = []
    }

    /// A shelf copy, as compared: `WorkMatchKey`'s keys.
    struct ShelfWork: Sendable {
        let title: String
        let authors: [String]
    }

    // Placeholders until measured (7a-5), in one place.
    static let recentAuthorBonus = 1.0
    static let recentTagBonus = 0.5
    /// The most a book gains from its place in its source's own order.
    static let positionBonus = 0.2
    /// Positions past this get no position bonus.
    static let positionSpan = Double(ForYouCandidates.limit)
    /// Books within one band take turns by source.
    static let bandWidth = 0.25
    /// The share of the section given to books not shown lately.
    static let explorationShare = 4

    /// Every shelf copy, online ones included (`CopyLookup` leaves book-source copies out).
    static func shelfWorks(_ books: [ReadingBook]) -> [ShelfWork] {
        books.map { ShelfWork(title: WorkMatchKey.title($0.title), authors: [WorkMatchKey.author($0.author)]) }
    }

    /// The key a work is remembered by in `ForYouExposureLog`.
    static func workKey(of entry: CollectionEntry) -> String? {
        guard case .item(_, let summary, _) = entry else { return nil }
        return ([WorkMatchKey.title(summary.title)] + summary.authors.map(WorkMatchKey.author).sorted())
            .joined(separator: "\u{1F}")
    }

    /// - Parameters:
    ///   - candidates: in input order; of two books of one work, the earlier is kept.
    ///   - weights: `ReadingGenreProfile.weights(at:)`.
    ///   - recentlyShown: `ForYouExposureLog.recentlyShown(at:)`.
    ///   - seed: the day, so a refresh within it keeps the explored books.
    static func rank(
        candidates: [ForYouCandidate],
        shelf: [ShelfWork],
        weights: [String: Double],
        recent: Recent,
        recentlyShown: Set<String>,
        languages: ReadingLanguagePreferences,
        seed: UInt64,
        limit: Int
    ) -> [CollectionEntry] {
        let recentAuthors = recent.authors.map(WorkMatchKey.author)
        let recentTags = Set(ReadingGenreProfile.normalizedTags(recent.tags))

        // 1. Dedupe; the shelf and, under 只推薦, other languages left out.
        var kept: [Scored] = []
        for candidate in candidates {
            guard case .item(let record, let summary, _) = candidate.entry else { continue }
            if languages.scope == .only, languages.rank(of: summary.language ?? record.language) == .other { continue }
            let title = WorkMatchKey.title(summary.title)
            let authors = summary.authors.map(WorkMatchKey.author)
            if shelf.contains(where: { $0.title == title && WorkMatchKey.authorKeysCompatible($0.authors, authors) }) { continue }
            if kept.contains(where: { $0.title == title && WorkMatchKey.authorKeysCompatible($0.authors, authors) }) { continue }
            // 2. Score.
            var score = candidate.tags.reduce(0) { $0 + (weights[$1] ?? 0) }
            if WorkMatchKey.authorKeysCompatible(recentAuthors, authors) { score += recentAuthorBonus }
            if !recentTags.isDisjoint(with: candidate.tags) { score += recentTagBonus }
            score += positionBonus * max(0, 1 - Double(candidate.position) / positionSpan)
            kept.append(Scored(candidate: candidate, title: title, authors: authors, score: score, index: kept.count))
        }

        // 3. Mix, 4. explore.
        let cap = Int((Double(limit) / 3).rounded(.up))
        let exploreCount = limit / explorationShare
        var perSource: [String: Int] = [:]
        var main: [Scored] = []
        for book in mixed(kept) where main.count < limit - exploreCount {
            guard perSource[book.candidate.source, default: 0] < cap else { continue }
            perSource[book.candidate.source, default: 0] += 1
            main.append(book)
        }
        var taken = Set(main.map(\.index))
        var generator = SplitMix64(seed: seed)
        let unseen = kept.filter { !taken.contains($0.index) && !recentlyShown.contains(workKey(of: $0.candidate.entry) ?? "") }
            .shuffled(using: &generator)
        let leftovers = mixed(kept).filter { !taken.contains($0.index) }
        var explored: [Scored] = []
        for book in unseen + leftovers where explored.count < exploreCount {
            guard !taken.contains(book.index), perSource[book.candidate.source, default: 0] < cap else { continue }
            perSource[book.candidate.source, default: 0] += 1
            taken.insert(book.index)
            explored.append(book)
        }

        // Explored books take every fourth place.
        var result: [CollectionEntry] = []
        var mainBooks = main[...], exploredBooks = explored[...]
        while !mainBooks.isEmpty || !exploredBooks.isEmpty {
            if (result.count + 1) % explorationShare == 0, let book = exploredBooks.popFirst() {
                result.append(book.candidate.entry)
            } else if let book = mainBooks.popFirst() ?? exploredBooks.popFirst() {
                result.append(book.candidate.entry)
            }
        }
        // 5. Languages, as the home's other sections.
        return languages.arrange(result)
    }

    private struct Scored {
        let candidate: ForYouCandidate
        let title: String
        let authors: [String]
        let score: Double
        /// Its place among the kept books.
        let index: Int
    }

    /// Highest band first; within a band, sources take turns, each giving its best first.
    private static func mixed(_ books: [Scored]) -> [Scored] {
        let bands = Dictionary(grouping: books) { Int(($0.score / bandWidth).rounded(.down)) }
        return bands.keys.sorted(by: >).flatMap { band -> [Scored] in
            let ordered = bands[band]!.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
            var queues: [String: ArraySlice<Scored>] = [:]
            var sources: [String] = []
            for book in ordered {
                if queues[book.candidate.source] == nil { sources.append(book.candidate.source) }
                queues[book.candidate.source, default: []].append(book)
            }
            var turns: [Scored] = []
            while turns.count < ordered.count {
                for source in sources {
                    if let book = queues[source]?.popFirst() { turns.append(book) }
                }
            }
            return turns
        }
    }
}

/// The works 為你推薦 has shown, so a refresh brings unseen ones (Discovery Phase 7a-3).
struct ForYouExposureLog: Codable, Equatable, Sendable {
    /// How long a shown work counts as seen.
    static let window: TimeInterval = 7 * 24 * 60 * 60

    private var shown: [String: Date] = [:]

    mutating func record(_ keys: [String], at date: Date) {
        shown = shown.filter { date.timeIntervalSince($0.value) <= Self.window }
        for key in keys { shown[key] = date }
    }

    /// Shown in the 7 days before today. Today's showings do not count yet: every load of the
    /// day (a relaunch, a pull to refresh, the form's preview) then gives the same section.
    func recentlyShown(at date: Date, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: date)
        return Set(shown.filter { $0.value < today && date.timeIntervalSince($0.value) <= Self.window }.keys)
    }
}
