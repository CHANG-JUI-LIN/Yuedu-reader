import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// 作品詳情's series fan (maintainer, by option, 2026-10-26): up to two covers a side, the
/// nearest volumes in series order, real artwork only, and nothing for a book alone.
@MainActor
@Suite("Series fan on 作品詳情")
struct SeriesFanTests {
    private static func volume(_ name: String, generated: Bool = false) -> SeriesFan.Volume {
        let cover: CoverReference = generated
            ? .generated(seed: name)
            : .remote(URL(string: "https://example.com/\(name).jpg")!, headers: [:])
        return SeriesFan.Volume(id: name, cover: .reference(cover, session: nil), title: name, author: "")
    }

    private static func names(_ sides: (leading: [SeriesFan.Volume], trailing: [SeriesFan.Volume])) -> [[String]] {
        [sides.leading.map(\.id), sides.trailing.map(\.id)]
    }

    private static let hasArtwork = { (cover: HomeCardContent.Cover) in
        cover.hasArtwork(filledCovers: nil, colorScheme: .light)
    }

    @Test("a middle volume: the two before it lead, the two after it trail, nearest first")
    func middle() {
        let fan = SeriesFan(volumes: ["1", "2", "3", "5", "6", "7"].map { Self.volume($0) }, position: 3)
        #expect(Self.names(fan.sides(hasArtwork: Self.hasArtwork)) == [["3", "2"], ["5", "6"]])
    }

    @Test("the first volume fans out on both sides, the leading one taking the further volumes")
    func first() {
        let fan = SeriesFan(volumes: ["2", "3", "4", "5", "6"].map { Self.volume($0) }, position: 0)
        #expect(Self.names(fan.sides(hasArtwork: Self.hasArtwork)) == [["4", "5"], ["2", "3"]])
    }

    @Test("the last volume fans out on both sides, the trailing one taking the further volumes")
    func last() {
        let fan = SeriesFan(volumes: ["1", "2", "3", "4"].map { Self.volume($0) }, position: 4)
        #expect(Self.names(fan.sides(hasArtwork: Self.hasArtwork)) == [["4", "3"], ["2", "1"]])
    }

    @Test("a generated cover is skipped and the next volume stands in its place")
    func generatedSkipped() {
        let fan = SeriesFan(volumes: [Self.volume("1"), Self.volume("2", generated: true), Self.volume("4", generated: true),
                                      Self.volume("5")], position: 2)
        #expect(Self.names(fan.sides(hasArtwork: Self.hasArtwork)) == [["1"], ["5"]])
    }

    @Test("no other volume with artwork: no fan, the hero keeps its one cover")
    func onlyOneCover() {
        let alone = SeriesFan(volumes: [], position: 0)
        #expect(Self.names(alone.sides(hasArtwork: Self.hasArtwork)) == [[], []])
        let generated = SeriesFan(volumes: [Self.volume("1", generated: true), Self.volume("3", generated: true)], position: 1)
        #expect(Self.names(generated.sides(hasArtwork: Self.hasArtwork)) == [[], []])
    }

    @Test("a shelf copy has artwork with a saved or catalog cover, not with a 預設封面 or 強制使用預設封面")
    func shelfArtwork() {
        var saved = ReadingBook(title: "三體", author: "劉慈欣", contentFilename: "a.epub")
        saved.coverImagePath = "cover.jpg"
        let bare = ReadingBook(title: "黑暗森林", author: "劉慈欣", contentFilename: "b.epub")
        #expect(HomeCardContent.Cover.shelf(saved).hasArtwork(filledCovers: nil, colorScheme: .light))
        #expect(!HomeCardContent.Cover.shelf(bare).hasArtwork(filledCovers: nil, colorScheme: .light))
        #expect(!HomeCardContent.Cover.reference(nil, session: nil).hasArtwork(filledCovers: nil, colorScheme: .light))
        #expect(HomeCardContent.Cover.reference(.copyFile("/tmp/cover.jpg"), session: nil)
            .hasArtwork(filledCovers: nil, colorScheme: .light))
        let plan = BookshelfCoverPlan.shelf(for: saved, colorScheme: .light, forcesDefaultCover: true)
        #expect(plan.ownCover == nil && plan.catalogFallback == nil, "the rule hasArtwork reads")
    }

    @Test("a series read on this device: the others in order, counted before the page's volume")
    func fromShelf() throws {
        let index = SeriesCardsTests.catalog(titles: ["三體", "黑暗森林", "死神永生"])
        let works = index.newWorks
        try #require(works.count == 3)
        let volumes = works.enumerated().map { offset, work in
            WorkSeriesShelf.Volume(entry: .aozora(work, index: index), number: Double(offset + 1), isPageWork: offset == 1)
        }
        let fan = try #require(SeriesFan(WorkSeriesShelf(name: "地球往事", number: 2, volumes: volumes), store: BookStore()))
        #expect(fan.volumes.map(\.title) == [volumes[0], volumes[2]].compactMap {
            HomeRowContent(entries: [$0.entry], store: BookStore()).cards.first?.title
        })
        #expect(fan.position == 1)
        let elsewhere = volumes.map { WorkSeriesShelf.Volume(entry: $0.entry, number: $0.number, isPageWork: false) }
        #expect(SeriesFan(WorkSeriesShelf(name: "地球往事", number: nil, volumes: elsewhere), store: BookStore()) == nil,
                "the page's own volume is not in the series")
    }
}

/// 趨勢's series: the other books' covers its list gives, which the fan stands after the item.
@Suite("Series fan of a list's series")
struct ListSeriesFanTests {
    private static func cover(_ name: String) -> CoverReference {
        .remote(URL(string: "https://upload.wikimedia.org/\(name).jpg")!, headers: [:])
    }

    @Test("the item is the series' first book: the next two trail, the two after lead")
    func firstBook() throws {
        let summary = WorkSummary(title: "Mistborn: The Final Empire", authors: ["Brandon Sanderson"], cover: Self.cover("1"),
                                  blurb: nil, language: "en", contentKind: .text, series: "Mistborn",
                                  seriesCovers: ["2", "3", "4", "5", "6"].map(Self.cover))
        #expect(summary.seriesCovers.count == WorkSummary.seriesCoverLimit, "the fan shows four")
        let fan = try #require(SeriesFan(summary, session: nil))
        #expect(fan.position == 0)
        let sides = fan.sides { _ in true }
        #expect([sides.leading.map(\.id), sides.trailing.map(\.id)] == [["2", "3"], ["0", "1"]])
    }

    @Test("no series, or no other covers: no fan")
    func noFan() {
        let alone = WorkSummary(title: "Good Omens", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text,
                                seriesCovers: [Self.cover("2")])
        #expect(alone.seriesCovers.isEmpty, "covers of a series need the series")
        #expect(SeriesFan(alone, session: nil) == nil)
        let bare = WorkSummary(title: "Mistborn", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text,
                               series: "Mistborn")
        #expect(SeriesFan(bare, session: nil) == nil)
    }
}
