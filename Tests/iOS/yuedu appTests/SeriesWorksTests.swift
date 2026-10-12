import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情's 同系列 (Editorial Minimalism, 2026-10-12): the page's series and its volumes on
/// the shelf and in the WebDAV index, by the rules 系列下一本 uses.
@Suite("Series works on 作品詳情")
struct SeriesWorksTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private static func copy(_ title: String, _ number: Double?, author: String = "劉慈欣",
                             series: String? = "地球往事") -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: series, seriesIndex: number)
    }

    private static func file(_ title: String, _ number: Double?, author: String = "劉慈欣",
                             series: String? = "地球往事") -> WorkIndexEntry {
        let record = SourceRecord(key: SourceItemKey(instance: dav, item: "\(title).epub"), title: title, authors: [author],
                                  language: nil, contentKind: .text, identifiers: [], copyID: nil,
                                  acquisitions: [.download(format: "epub")])
        return WorkIndexEntry(record: record, series: series, seriesIndex: number)
    }

    private func volumes(_ entries: [WorkIndexEntry], page: WorkIndexEntry) -> [SeriesWorks.Volume] {
        let index = WorkIndex.build(entries: entries)
        let workOf = index.workPositions()
        guard let (_, placement) = SeriesWorks.placement(of: [page.nodeKey], in: index, workOf: workOf) else { return [] }
        return SeriesWorks.volumes(in: index, of: placement, pageNodes: [page.nodeKey],
                                   shown: Set(entries.map(\.nodeKey)), workOf: workOf)
    }

    @Test("every volume by number, a fractional one between its neighbours, unnumbered ones last; the page's own marked")
    func seriesOrder() {
        let first = Self.copy("三體", 1)
        let second = Self.copy("黑暗森林", 2)
        let between = Self.copy("外傳", 1.5)
        let third = Self.file("死神永生", 3)
        let loose = Self.copy("地球往事散篇", nil)
        let found = volumes([third, loose, second, first, between], page: second)
        #expect(found.map(\.key) == [first, between, second, third, loose].map(\.nodeKey))
        #expect(found.map(\.number) == [1, 1.5, 2, 3, nil])
        #expect(found.filter(\.isPageWork).map(\.key) == [second.nodeKey])
    }

    @Test("the same series name by another author is another series; a book of no series has none")
    func sameAuthorOnly() {
        let seed = Self.copy("基地", 1, author: "艾西莫夫", series: "基地")
        let otherAuthor = Self.copy("基地前奏", 2, author: "別人", series: "基地")
        #expect(volumes([seed, otherAuthor], page: seed).map(\.key) == [seed.nodeKey])
        let alone = Self.copy("單行本", nil, series: nil)
        #expect(volumes([alone, seed], page: alone).isEmpty)
    }

    @Test("a shelf copy stands for its work before a file of it; a copy without a series takes its work's")
    func oneCardAWork() {
        let seed = Self.copy("三體", 1)
        let file = Self.file("黑暗森林", 2)
        let shelfCopy = Self.copy("黑暗森林", 2)
        #expect(volumes([seed, file, shelfCopy], page: seed).map(\.key) == [seed.nodeKey, shelfCopy.nodeKey])

        // The copy's sidecar names no series; the WebDAV file of the same book does, and names it.
        let bareCopy = Self.copy("三體", nil, series: nil)
        let namedFile = Self.file("三體", 1)
        let sequel = Self.file("黑暗森林", 2)
        let index = WorkIndex.build(entries: [bareCopy, namedFile, sequel])
        let placement = SeriesWorks.placement(of: [bareCopy.nodeKey], in: index, workOf: index.workPositions())
        #expect(placement?.entry.nodeKey == namedFile.nodeKey, "the series' name is read from the file's metadata")
        #expect(placement?.placement.number == 1)
        let found = volumes([bareCopy, namedFile, sequel], page: bareCopy)
        #expect(found.filter { !$0.isPageWork }.map(\.key) == [sequel.nodeKey])
    }

    @Test("作者其他作品 leaves out the page's series, which 同系列 shows")
    func authorRowSkipsTheSeries() {
        let page = Self.copy("三體", 1)
        let sequel = Self.copy("黑暗森林", 2)
        let other = Self.copy("球狀閃電", nil, series: nil)
        let index = WorkIndex.build(entries: [page, sequel, other])
        let shown = Set([page, sequel, other].map(\.nodeKey))
        let author = [WorkMatchKey.author("劉慈欣")]
        #expect(Set(RelatedWorks.byAuthors(in: index, authorKeys: author, excluding: [page.nodeKey], shown: shown, limit: 10))
                == [other.nodeKey, sequel.nodeKey], "without the series named, its volumes are the author's too")
        let picked = RelatedWorks.byAuthors(in: index, authorKeys: author, excluding: [page.nodeKey], shown: shown,
                                            excludingSeries: WorkMatchKey.title("地球往事"), limit: 10)
        #expect(picked == [other.nodeKey])
    }

    @Test("a volume's number reads 「第 2 冊」 or 「第 2.5 冊」; a series without one is its name alone")
    func numberWording() {
        #expect(SeriesWorks.numberText(2) == String(format: localized("第 %@ 冊"), "2"))
        #expect(SeriesWorks.numberText(2.5) == String(format: localized("第 %@ 冊"), 2.5.formatted(.number.precision(.fractionLength(0...2)))))
        #expect(SeriesWorks.line(name: "地球往事", number: nil) == "地球往事")
        #expect(SeriesWorks.line(name: "地球往事", number: 2) == "地球往事 · " + SeriesWorks.numberText(2))
    }
}

/// 同系列's cards: each says its number where the author would be, on screen and to VoiceOver.
@MainActor
@Suite("Series cards on 作品詳情")
struct SeriesCardsTests {
    @Test("a numbered volume says 「第 2 冊」 for its author; an unnumbered one keeps its author")
    func numberedCards() throws {
        let index = Self.catalog(titles: ["三體", "黑暗森林"])
        let works = index.newWorks
        try #require(works.count == 2)
        let volumes = [WorkSeriesShelf.Volume(entry: .aozora(works[0], index: index), number: 2, isPageWork: false),
                       WorkSeriesShelf.Volume(entry: .aozora(works[1], index: index), number: nil, isPageWork: false)]
        let cards = WorkSeriesShelf.cards(volumes, store: BookStore())
        try #require(cards.count == 2)
        #expect(cards[0].author == SeriesWorks.numberText(2))
        #expect(cards[0].accessibilityValue.hasPrefix(SeriesWorks.numberText(2)))
        #expect(!cards[0].accessibilityValue.contains(works[0].title), "the label has the title")
        let author = HomeRowContent(entries: [volumes[1].entry], store: BookStore()).cards[0].author
        #expect(cards[1].author == author)
    }

    /// A catalog of one author's works, one per title.
    static func catalog(titles: [String]) -> AozoraCatalogIndex {
        let person = AozoraPerson(id: "1", name: "劉 慈欣", yomi: "りゅう じきん", sortYomi: "りゆうしきん", born: "", died: "")
        let works = titles.enumerated().map { offset, title in
            AozoraWork(id: "\(offset + 1)", title: title, yomi: title, sortYomi: title, subtitle: "", kanaStyle: "新字新仮名",
                       ndc: "NDC 923", published: "2000-01-0\(offset + 1)", updated: "2000-01-01", card: "https://www.aozora.gr.jp/",
                       text: "https://www.aozora.gr.jp/\(offset + 1).zip", textUpdated: "2000-01-01",
                       credits: [.init(person: "1", role: "著者")], source: "", sourcePublisher: "")
        }
        return AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: works))
    }
}
