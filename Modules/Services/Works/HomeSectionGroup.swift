import Foundation

// Unified library 5d-3b: the home as Emby aggregates it (Phase 5 plan, decision 19).
// - The home draws one group per section. 最新's rows, one per source because each source
//   loads on its own terms (`SectionLoadPolicy`), draw as one: their books take turns, since
//   no source gives dates to sort them by.
// - 範圍 filters the same home: a source's own rows stay, the shelf's rows (繼續閱讀, 相關)
//   keep that source's copies, and every other row goes. Nothing names a source on the home.
// - 中繼資料語言偏好推薦 (2026-10-21; 偏好閱讀語言 in 5d-3d, decision 21) orders each section's
//   books, after 最新's turns, and leaves none out. 繼續閱讀 keeps its own order: most recently
//   opened first.
// - 隱藏已讀 (5d-3g) leaves read books out of 最新 and 相關 before anything else.
// - A section's rows keep the model's order, so 最新's books take turns in the libraries' order
//   (`LibraryKeys`); 書庫順序 (5d-3e), which reordered them, went on 2026-10-25.

/// One section as the home draws it.
struct HomeSectionGroup: Identifiable, Equatable {
    let section: HomeSection
    /// The section's rows that 範圍 keeps: the shelf's, the libraries', then the book sources'
    /// in 探索's order.
    let rows: [HomeModel.Row]
    /// What each row shows under 範圍, by row id; a row not yet loaded has none.
    let entries: [String: [CollectionEntry]]
    /// The reader's languages, which order the section's books; nil leaves them as loaded.
    var languages: ReadingLanguagePreferences?

    var id: String { section.id.uuidString }

    /// The section's name. A row of one source titled by that source (a feed, a category
    /// list with no title) keeps the source's name as its title.
    var title: String {
        section.displayTitle(sourceName: rows.count == 1 ? rows[0].sourceName : "")
    }

    /// The rows' states as one:
    /// - any row with books shows them, the others joining as they load;
    /// - else, while any row is still to load, it is loading;
    /// - else, if any failed, the first failure, which 重試 asks of every failed row;
    /// - else it is empty, and takes no room.
    /// A failed row beside one with books is not shown; the model logs its failure.
    var state: HomeModel.RowState {
        let alternated = Self.alternate(rows.compactMap { row in
            guard case .loaded = row.state else { return nil }
            return entries[row.id]
        })
        let merged = languages?.arrange(alternated) ?? alternated
        if !merged.isEmpty { return .loaded(merged) }
        if rows.contains(where: { if case .idle = $0.state { true } else if case .loading = $0.state { true } else { false } }) {
            return .loading
        }
        for row in rows { if case .failed(let message) = row.state { return .failed(message) } }
        return .loaded([])
    }

    /// Loaded with nothing in it: the home gives it no room. AI 推薦 is never settled empty:
    /// with no list yet it offers 產生推薦 (AI 推薦 plan 8c).
    var isSettledEmpty: Bool {
        if section.binding == .aiRecommendations { return false }
        if case .loaded(let entries) = state { return entries.isEmpty }
        return false
    }

    /// One from each list in turn: 最新 has no dates to sort by.
    static func alternate(_ lists: [[CollectionEntry]]) -> [CollectionEntry] {
        var merged: [CollectionEntry] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { merged.append(list[index]) }
        }
        return merged
    }
}

extension HomeModel {
    /// The home's groups under 範圍 (`scope` nil is 全部), one per section with a row kept,
    /// their books in the reader's languages' order.
    func groups(in scope: SourceInstanceKey?, languages: ReadingLanguagePreferences? = nil,
                readFilter: HomeReadFilter? = nil) -> [HomeSectionGroup] {
        HomeScopeFilter.groups(rows, in: scope, languages: languages, readFilter: readFilter)
    }

    /// The home is on screen: the rows that load with it start now, also those below the
    /// fold, whose views have not been made yet. Only those 範圍 keeps: choosing 青空文庫
    /// sends nothing to Gutenberg.
    func homeAppeared(in scope: SourceInstanceKey?) {
        for row in rows where row.policy == .withHome && HomeScopeFilter.keeps(row, in: scope) { load(row.id) }
    }
}

enum HomeScopeFilter {
    /// Whether 範圍 keeps a row at all: its own source's, or the shelf's, whose copies it
    /// filters.
    static func keeps(_ row: HomeModel.Row, in scope: SourceInstanceKey?) -> Bool {
        guard let scope else { return true }
        return row.source == scope || row.source == .localLibrary
    }

    /// What a row shows under 範圍. The shelf's rows keep the copies whose current source is
    /// the chosen one (`SourceRecord.derived(from:)` names it); their groups are not places of
    /// that source, so they go.
    static func entries(_ entries: [CollectionEntry], of row: HomeModel.Row, in scope: SourceInstanceKey?) -> [CollectionEntry] {
        guard let scope, row.source != scope else { return entries }
        return entries.filter { entry in
            if case .item(let record, _, _) = entry { return record.key.instance == scope }
            return false
        }
    }

    static func groups(_ rows: [HomeModel.Row], in scope: SourceInstanceKey?,
                       languages: ReadingLanguagePreferences? = nil,
                       readFilter: HomeReadFilter? = nil) -> [HomeSectionGroup] {
        var order: [UUID] = []
        var sections: [UUID: HomeSection] = [:]
        var kept: [UUID: [HomeModel.Row]] = [:]
        for row in rows where keeps(row, in: scope) {
            let id = row.section.id
            if kept[id] == nil { order.append(id); sections[id] = row.section }
            kept[id, default: []].append(row)
        }
        return order.compactMap { id in
            guard let section = sections[id], let rows = kept[id] else { return nil }
            let hidesRead = readFilter.map { $0.hides(in: section.binding) } ?? false
            var entries: [String: [CollectionEntry]] = [:]
            for row in rows {
                guard case .loaded(let loaded) = row.state else { continue }
                let kept = Self.entries(loaded, of: row, in: scope)
                entries[row.id] = hidesRead ? kept.filter { !(readFilter?.isRead($0) ?? false) } : kept
            }
            // 繼續閱讀 and 系列下一本 keep the order the books were opened in; 書架, the 書架 tab's;
            // 訂閱的最新文章, the newest first.
            let ordered = [.continueReading, .bookshelf, .nextInSeries, .subscriptionArticles].contains(section.binding)
                ? nil : languages
            return HomeSectionGroup(section: section, rows: rows, entries: entries, languages: ordered)
        }
    }
}
