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
        return SeriesFan.Volume(id: name, cover: .reference(cover, session: nil))
    }

    private static func names(_ sides: (leading: [SeriesFan.Volume], trailing: [SeriesFan.Volume])) -> [[String]] {
        [sides.leading.map(\.id), sides.trailing.map(\.id)]
    }

    private static let pixels = CoverPixelSize.fitting(pointSize: CGSize(width: 120, height: 180), scale: 2)!

    private static func source(_ cover: HomeCardContent.Cover, forcesDefaultCover: Bool = false) -> SeriesFanArtwork? {
        cover.artworkSource(pixels: pixels, filledCovers: nil, colorScheme: .light, forcesDefaultCover: forcesDefaultCover)
    }

    private static let hasArtwork = { (volume: SeriesFan.Volume) in source(volume.cover) != nil }

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

    @Test("a shelf copy's artwork is its saved cover, at the page cover's size; a 預設封面 is none")
    func shelfArtwork() throws {
        var saved = ReadingBook(title: "三體", author: "劉慈欣", contentFilename: "a.epub")
        saved.coverImagePath = "cover.jpg"
        let bare = ReadingBook(title: "黑暗森林", author: "劉慈欣", contentFilename: "b.epub")
        let file = try #require(Self.source(.shelf(saved))?.file)
        #expect(file == CoverImageRequest(source: .bookCover(filename: "cover.jpg"), size: Self.pixels))
        #expect(Self.source(.shelf(bare)) == nil)
        #expect(Self.source(.reference(nil, session: nil)) == nil)
        #expect(Self.source(.placeholder) == nil)
        #expect(Self.source(.reference(.copyFile("/tmp/cover.jpg"), session: nil))?.file
            == CoverImageRequest(source: .indexedCover(path: "/tmp/cover.jpg"), size: Self.pixels))
    }

    @Test("強制使用預設封面: no volume's own artwork is drawn, so there is no fan")
    func forcedDefaultCover() {
        var saved = ReadingBook(title: "三體", author: "劉慈欣", contentFilename: "a.epub")
        saved.coverImagePath = "cover.jpg"
        #expect(Self.source(.shelf(saved), forcesDefaultCover: true) == nil)
        #expect(Self.source(Self.volume("1").cover, forcesDefaultCover: true) == nil)
        #expect(Self.source(.reference(.copyFile("/tmp/cover.jpg"), session: nil), forcesDefaultCover: true) == nil)
    }

    /// A volume whose cover is a bundled sample, or a file that is not there.
    private static func file(_ name: String, sample: String?) -> SeriesFan.Volume {
        let path = sample.flatMap { Bundle.main.path(forResource: "layout-sample-\($0)", ofType: "jpg") }
            ?? "/nonexistent/series-fan-\(name).jpg"
        return SeriesFan.Volume(id: name, cover: .reference(.copyFile(path), session: nil))
    }

    @Test("the fan's covers load before it draws; one that cannot be read gives its place to the next")
    func unreadableSkipped() async {
        let fan = SeriesFan(volumes: [Self.file("1", sample: "frankenstein"), Self.file("2", sample: nil),
                                      Self.file("4", sample: "dracula"), Self.file("5", sample: "jane-eyre"),
                                      Self.file("6", sample: "moby-dick")], position: 2)
        let artwork = await fan.artwork(pipeline: CoverImagePipeline(logsSummaries: false)) { Self.source($0.cover) }
        #expect(Set(artwork.keys) == ["1", "4", "5", "6"], "2 was tried and failed; 6 stands in")
        #expect(Self.names(fan.sides { artwork[$0.id] != nil }) == [["1", "6"], ["4", "5"]])
    }

    @Test("no volume's cover loads: nothing is drawn")
    func nothingLoads() async {
        let fan = SeriesFan(volumes: [Self.file("1", sample: nil), Self.file("3", sample: nil)], position: 1)
        let artwork = await fan.artwork(pipeline: CoverImagePipeline(logsSummaries: false)) { Self.source($0.cover) }
        #expect(artwork.isEmpty)
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
        #expect(fan.volumes.map(\.id) == [volumes[0], volumes[2]].compactMap {
            HomeRowContent(entries: [$0.entry], store: BookStore()).cards.first?.id.sortKey
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

    @Test("an item that is the whole series fans the covers it was given, naming no series")
    func wholeSeries() throws {
        let summary = WorkSummary(title: "薬屋のひとりごと", authors: ["日向夏"], cover: Self.cover("1"), blurb: nil, language: "ja",
                                  contentKind: .text, seriesCovers: ["2", "3"].map(Self.cover))
        #expect(summary.series == nil, "its title is the series' name")
        let fan = try #require(SeriesFan(summary, session: nil))
        #expect(fan.position == 0)
        #expect(fan.volumes.map(\.id) == ["0", "1"])
    }

    @Test("no other covers: no fan")
    func noFan() {
        let alone = WorkSummary(title: "Good Omens", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text)
        #expect(SeriesFan(alone, session: nil) == nil)
        let bare = WorkSummary(title: "Mistborn", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text,
                               series: "Mistborn")
        #expect(SeriesFan(bare, session: nil) == nil)
    }
}
