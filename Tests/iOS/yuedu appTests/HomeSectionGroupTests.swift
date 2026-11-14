import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3b: one section per group, 最新's sources in turn, and 範圍 as a filter
/// over the same home (Phase 5 plan, decision 19).
@MainActor
@Suite("Home section groups")
struct HomeSectionGroupTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)

    private func row(_ section: HomeSection, _ source: SourceInstanceKey, _ state: HomeModel.RowState) -> HomeModel.Row {
        HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                      sourceName: source.id, policy: .parallel, state: state)
    }

    private func gutenbergItem(_ number: Int) -> CollectionEntry {
        CollectionEntry.bundledGutenberg(GutenbergBook(id: number, title: "\(number)", author: "A"))
    }

    private func aozoraItem(_ id: String) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: aozora, item: id), title: id, authors: [], language: "ja",
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [])
        return .item(record, WorkSummary(title: id, authors: [], cover: nil, blurb: nil, language: "ja", contentKind: .text),
                     .copy(UUID()))
    }

    /// A shelf copy whose current source is `source`, as `SourceRecord.derived(from:)` keys it.
    private func shelfCopy(of source: SourceInstanceKey?, title: String) -> CollectionEntry {
        let id = UUID()
        let key = source.map { SourceItemKey(instance: $0, item: title) } ?? .copy(id)
        let record = SourceRecord(key: key, title: title, authors: [], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [.openCopy(id)])
        return .item(record, WorkSummary(title: title, authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text),
                     .copy(id))
    }

    private func titles(_ state: HomeModel.RowState) -> [String] {
        guard case .loaded(let entries) = state else { return [] }
        return entries.compactMap { entry in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
    }

    @Test("最新's rows are one section, their books taking turns in provider order")
    func latestIsOneSection() {
        let latest = HomeSection(layout: .row, binding: .latest)
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let rows = [
            row(reading, .localLibrary, .loaded([])),
            row(latest, gutenberg, .loaded([gutenbergItem(1), gutenbergItem(2), gutenbergItem(3)])),
            row(latest, aozora, .loaded([aozoraItem("a"), aozoraItem("b")])),
        ]
        let groups = HomeScopeFilter.groups(rows, in: nil)
        #expect(groups.map(\.section.id) == [reading.id, latest.id])
        #expect(groups[1].rows.count == 2)
        #expect(titles(groups[1].state) == ["1", "a", "2", "b", "3"])
        #expect(groups[1].title == localized("最新"))
    }

    /// A module's ranking as the model makes its row: named by the list, its module's name beside.
    private func ranking(_ section: HomeSection, card: HomeListCard, index: Int, name: String) -> HomeModel.Row {
        let module = SourceInstanceKey(type: .module, id: "bangumi")
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, card: index, source: module), section: section,
                             source: module, sourceName: name, policy: .parallel, state: .loading, card: card,
                             cardIndex: index, providerName: "Bangumi 番組計劃")
    }

    @Test("排行榜 of one ranking is named by the ranking, which its column does not head; of several, 熱門排行榜; no module is named")
    func chartOfOneRankingIsNamedByIt() throws {
        // The defaults' 漫畫排行: one list of a module, drawn as 排行榜.
        let manga = HomeSectionBinding.module(moduleID: "bangumi", entryID: "manga-rank")
        let one = HomeSection(layout: .rankedRow, binding: manga)
        #expect(one.headerNamesItsList)
        let lone = HomeScopeFilter.groups([ranking(one, card: try #require(one.listCards.first), index: 0, name: "漫畫排行")], in: nil)
        #expect(lone.map(\.title) == ["漫畫排行"])

        // Two rankings head their own columns: the section is 熱門排行榜, as the store's, not their module's.
        let cards = [HomeListCard(binding: manga), HomeListCard(binding: .module(moduleID: "bangumi", entryID: "novel-rank"))]
        let two = HomeSection(layout: .rankedRow, binding: .lists(cards))
        #expect(!two.headerNamesItsList)
        func rows(of section: HomeSection) -> [HomeModel.Row] {
            [ranking(section, card: cards[0], index: 0, name: "漫畫排行"), ranking(section, card: cards[1], index: 1, name: "小說排行")]
        }
        #expect(HomeScopeFilter.groups(rows(of: two), in: nil).map(\.title) == [localized("熱門排行榜")])
        // 類型清單's rows name themselves too: 類型.
        let genres = HomeSection(layout: .genreList, binding: .lists(cards))
        #expect(HomeScopeFilter.groups(rows(of: genres), in: nil).map(\.title) == [localized("欄目：類型")])
        // The reader's own title stays.
        let titled = HomeSection(layout: .rankedRow, title: "我的排行", binding: .lists(cards))
        #expect(HomeScopeFilter.groups(rows(of: titled), in: nil).map(\.title) == ["我的排行"])

        // A card names its list in the other layouts of lists, and the section is named as the
        // store names such a section, never by the module: 熱門精選 over collages, 探索更多 over cards.
        for (layout, name) in [(HomeSectionLayout.categoryCards, "探索更多"), (.bannerCards, "探索更多"), (.collection, "探索更多"),
                               (.collageCards, "熱門精選"), (.groupedShelves, "分類瀏覽")] {
            let card = HomeSection(layout: layout, binding: manga)
            #expect(!card.headerNamesItsList)
            let carded = HomeScopeFilter.groups([ranking(card, card: try #require(card.listCards.first), index: 0, name: "漫畫排行")],
                                                in: nil)
            #expect(carded.map(\.title) == [localized(name)], "\(layout.rawValue)")
        }
        // A 來源配置's categories stay under the 來源配置's own name, as before.
        let reference = ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "https://source.test/xuanhuan")
        let categories = HomeSection(layout: .categoryCards, binding: .sourceCategories([reference, reference]))
        let source = SourceInstanceKey(type: .bookSource, id: "https://source.test")
        let sourced = HomeModel.Row(id: "category", section: categories, source: source, sourceName: "某書源", policy: .parallel,
                                    state: .loading, card: categories.listCards.first, cardIndex: 0, providerName: "某書源")
        #expect(HomeScopeFilter.groups([sourced], in: nil).map(\.title) == ["某書源"])
    }

    @Test("色帶書架's band is its section's own ground while it loads and once it has books; not failed, not AI 推薦's")
    func colorBandIsItsOwnGround() {
        func group(_ section: HomeSection, _ state: HomeModel.RowState) -> HomeSectionGroup {
            HomeScopeFilter.groups([row(section, gutenberg, state)], in: nil)[0]
        }
        let band = HomeSection(layout: .colorBand, binding: .gutenbergShelf(id: "popular"))
        #expect(group(band, .idle).drawsColorBand)
        #expect(group(band, .loading).drawsColorBand)
        #expect(group(band, .loaded([gutenbergItem(1)])).drawsColorBand)
        #expect(!group(band, .failed("offline")).drawsColorBand)
        // Nothing in it: no band, and the home gives it no room anyway.
        #expect(!group(band, .loaded([])).drawsColorBand)
        // Another layout shades as every section does.
        #expect(!group(HomeSection(layout: .largeRow, binding: .gutenbergShelf(id: "popular")), .loading).drawsColorBand)
        // AI 推薦's header stays on the page, over its covers' own band.
        #expect(!group(HomeSection(layout: .colorBand, binding: .aiRecommendations), .loading).drawsColorBand)
    }

    @Test("a section shows books as soon as one source has some; else it loads, fails, or takes no room")
    func mergedState() {
        let latest = HomeSection(layout: .row, binding: .latest)
        func state(_ states: [HomeModel.RowState]) -> HomeModel.RowState {
            let sources = [gutenberg, aozora, SourceInstanceKey(type: .opds, id: "c")]
            return HomeScopeFilter.groups(zip(sources, states).map { row(latest, $0, $1) }, in: nil)[0].state
        }
        #expect(titles(state([.loading, .loaded([gutenbergItem(7)]), .failed("x")])) == ["7"])
        #expect(state([.loading, .loaded([]), .failed("x")]) == .loading)
        #expect(state([.idle, .failed("x")]) == .loading)
        #expect(state([.loaded([]), .failed("first"), .failed("second")]) == .failed("first"))
        #expect(state([.loaded([]), .loaded([])]) == .loaded([]))
        #expect(HomeScopeFilter.groups([row(latest, gutenberg, .loaded([]))], in: nil)[0].isSettledEmpty)
    }

    @Test("範圍 keeps the chosen source's rows and its copies in the shelf's rows; the rest goes")
    func scopeFilters() {
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let featured = HomeSection(layout: .row, binding: .gutenbergCollection(id: "chinese"))
        let latest = HomeSection(layout: .row, binding: .latest)
        let rows = [
            row(reading, .localLibrary, .loaded([
                shelfCopy(of: gutenberg, title: "紅樓夢"), shelfCopy(of: aozora, title: "こころ"),
                shelfCopy(of: nil, title: "本機檔案"), .location(CollectionLocation(id: "group/x", title: "分組")),
            ])),
            row(featured, gutenberg, .loaded([gutenbergItem(24264)])),
            row(latest, gutenberg, .loaded([gutenbergItem(1)])),
            row(latest, aozora, .loaded([aozoraItem("a")])),
        ]

        let all = HomeScopeFilter.groups(rows, in: nil)
        #expect(all.count == 3)
        #expect(titles(all[0].state) == ["紅樓夢", "こころ", "本機檔案"])

        let onlyAozora = HomeScopeFilter.groups(rows, in: aozora)
        #expect(onlyAozora.map(\.section.id) == [reading.id, latest.id])
        #expect(titles(onlyAozora[0].state) == ["こころ"])
        #expect(titles(onlyAozora[1].state) == ["a"])
        #expect(onlyAozora[1].rows.map(\.source) == [aozora])

        let onlyGutenberg = HomeScopeFilter.groups(rows, in: gutenberg)
        #expect(onlyGutenberg.map(\.section.id) == [reading.id, featured.id, latest.id])
        #expect(titles(onlyGutenberg[0].state) == ["紅樓夢"])

        // A source no section draws from: the shelf's rows stay, with nothing of it in them.
        let other = HomeScopeFilter.groups(rows, in: SourceInstanceKey(type: .opds, id: "nas"))
        #expect(other.map(\.section.id) == [reading.id])
        #expect(other[0].isSettledEmpty)
    }
}
