import Foundation
import Testing
@testable import yuedu_app

// 排行榜 (maintainer, 2026-10-27: 「排行榜也照著圖片1比1復刻」「每欄一份排行」「每欄 3 名」): Top Charts'
// columns, a ranking each, which replaced 顯示排名; and 大圖卡片's photos, which follow the card.

private func book(_ title: String) -> CollectionEntry {
    let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .module, id: "m"), item: title),
                              title: title, authors: [], language: "zh", contentKind: .text, identifiers: [],
                              copyID: nil, acquisitions: [.viewOnly])
    return .item(record, WorkSummary(title: title, authors: [], cover: .generated(seed: title), blurb: nil,
                                     language: "zh", contentKind: .text), .bibliographic)
}

@MainActor
@Suite("排行榜")
struct HomeChartTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)

    /// The section's rows as the model makes them: a row per card.
    private func group(_ section: HomeSection) -> HomeSectionGroup {
        let rows = section.listCards.enumerated().map { index, card in
            HomeModel.Row(id: HomeModel.rowID(section: section.id, card: index, source: gutenberg), section: section,
                          source: gutenberg, sourceName: "古騰堡", policy: .local, state: .idle, card: card, cardIndex: index)
        }
        return HomeSectionGroup(section: section, rows: rows, entries: [:])
    }

    @Test("one ranking's header opens that ranking, as its ranked row's did; several rankings' their source's page")
    func header() {
        let chinese = HomeSectionBinding.gutenbergCollection(id: "chinese")
        let one = group(HomeSection(layout: .rankedRow, binding: chinese))
        #expect(one.rows.count == 1)
        #expect(ExplorePlace.sectionPage(one, aozoraIndex: nil) == .publicLibrary(.collection(id: "chinese")))

        // The same list as 專題集合 is a card among a section of lists, which opens its source's page.
        let asCards = group(HomeSection(layout: .collection, binding: chinese))
        #expect(ExplorePlace.sectionPage(asCards, aozoraIndex: nil) == .explore(.library(gutenberg)))

        let several = group(HomeSection(layout: .rankedRow, binding: .lists([HomeListCard(binding: chinese),
                                                                               HomeListCard(binding: .gutenbergShelf(id: "popular"))])))
        #expect(several.rows.count == 2)
        #expect(ExplorePlace.sectionPage(several, aozoraIndex: nil) == .explore(.library(gutenberg)))
    }

    @Test("a column is its ranking's books in order: a card's, frozen when its row loaded, or a bundled list's own")
    func columns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeChart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))

        let section = HomeSection(layout: .rankedRow, binding: .module(moduleID: "m", entryID: "hot"))
        let opening = HomeListOpening(section: section, source: SourceInstanceKey(type: .module, id: "m"), sourceName: "m",
                                      title: "熱門", entries: ["甲", "乙", "丙", "丁"].map(book))
        let ranking = CollectionSummary(id: "hot", title: "熱門", books: [], languages: [], opening: .list(opening))
        let bundled = try #require(PublicLibraryCollection.all.first)
        let classics = CollectionSummary.bundledGutenberg(bundled)
        let entries: [CollectionEntry] = [.collection(ranking), .collection(classics)]

        let content = HomeRowContent(entries: entries, store: store, withLists: true)
        #expect(content.lists["hot"]?.cards.map(\.title) == ["甲", "乙", "丙", "丁"])
        #expect(content.lists[classics.id]?.cards.map(\.title) == bundled.books.map(\.title))
        #expect(HomeRowContent(entries: entries, store: store).lists.isEmpty, "made only for 排行榜")
        #expect(HomeChartColumns.places == 3)
    }

    @Test("a 大圖卡片 card's photo is its card's in its section, on every list the card gives")
    func photoFollowsTheCard() throws {
        let hot = HomeSectionBinding.module(moduleID: "m", entryID: "hot")
        let section = HomeSection(layout: .bannerCards, binding: .lists([HomeListCard(binding: hot, parameters: ["地區": "jp"]),
                                                                        HomeListCard(binding: .gutenbergLists)]))
        let cards = section.listCards
        let rows = cards.enumerated().map { index, card in
            HomeModel.Row(id: HomeModel.rowID(section: section.id, card: index, source: gutenberg), section: section,
                          source: gutenberg, sourceName: "", policy: .local, state: .idle, card: card, cardIndex: index)
        }
        let books = CollectionSummary.cards(of: rows[0], entries: [book("甲")], languages: nil)
        let expected = try #require(HomeListCardPhotoID(section: section.id, binding: hot, parameters: ["地區": "jp"]))
        #expect(books.map(\.photoID) == [expected])

        let lists = CollectionSummary.cards(of: rows[1], entries: PublicLibraryCollection.all.prefix(2).map {
            .collection(.bundledGutenberg($0))
        }, languages: nil)
        let listsPhoto = try #require(HomeListCardPhotoID(section: section.id, binding: .gutenbergLists, parameters: [:]))
        #expect(lists.count == 2)
        #expect(lists.allSatisfy { $0.photoID == listsPhoto })
        #expect(expected != listsPhoto)
    }
}
