import Foundation
import Testing
@testable import yuedu_app

/// Unified search 4c-2: every part's candidates merged into works by the work index's rules
/// (design §7.2), ranked by §12.2, deterministically.
@Suite("Search work resolver")
struct SearchWorkResolverTests {
    @Test("§16: the shelf's EPUB, a Calibre book, an OPDS zh-Hant entry and a source's 三体 are one work; 三體II is another")
    func sixteenFixture() {
        let shelf = candidate(.shelf, "三體", ["劉慈欣"], key: .copy(UUID()))
        let calibre = candidate(.library, "三體", ["劉慈欣"], key: item(.calibre, "calibre-1"),
                                identifiers: [isbn("9787536692930")])
        let opds = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "urn:uuid:1"), language: "zh-Hant")
        let source = row("三体", "刘慈欣", origins: 2)
        let sequel = row("三體II：黑暗森林", "劉慈欣", origins: 1)

        let results = SearchWorkResolver.resolve([shelf, calibre, opds, source, sequel], query: "三體")

        #expect(results.count == 2)
        let work = results[0]
        #expect(work.members.map(\.id) == [shelf.id, calibre.id, opds.id, source.id], "shelf, libraries, then sources")
        #expect(work.lead == shelf)
        #expect(work.availability == .onShelf)
        #expect(work.sourceCount == 4, "Calibre, OPDS and the row's two sources; the shelf is not a source")
        #expect(work.score == 3)
        #expect(results[1].members.map(\.id) == [sequel.id])
        #expect(results[1].score == 2)
    }

    @Test("A: a shelf copy taken from a library item meets that item's result, whatever its title")
    func sharedItem() {
        let key = item(.calibre, "calibre-7")
        let copy = candidate(.shelf, "三體（典藏版）", [], key: key)
        let result = candidate(.library, "三體", ["劉慈欣"], key: key)
        #expect(SearchWorkResolver.resolve([copy, result], query: "三體").count == 1)
    }

    @Test("A: a shared ISBN merges without authors")
    func sharedIdentifier() {
        let a = candidate(.library, "三體", [], key: item(.opds, "a"), identifiers: [isbn("9787536692930")])
        let b = candidate(.bibliographic, "The Three-Body Problem", ["Liu Cixin"], key: openLibrary("OL1W"),
                          identifiers: [isbn("9787536692930")], readable: false)
        let results = SearchWorkResolver.resolve([a, b], query: "三體")
        #expect(results.count == 1)
        #expect(results[0].availability == .readable)
    }

    @Test("C: no author, another kind or another language stays apart")
    func neverMerged() {
        let named = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "named"), language: "zh-Hant")
        let anonymous = candidate(.library, "三體", [], key: item(.opds, "anonymous"))
        let audio = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "audio"), kind: .audio)
        let japanese = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "ja"), language: "ja")
        let chinese = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "zh"), language: "zh-Hans")
        let results = SearchWorkResolver.resolve([named, anonymous, audio, japanese, chinese], query: "三體")
        #expect(results.count == 4, "zh-Hant and zh-Hans are one language; ja, audio and the anonymous one stay apart")
        #expect(results.contains { Set($0.members.map(\.id)) == [named.id, chinese.id] })
    }

    @Test("Open Library alone is data only; with a source it is readable and the source leads")
    func availability() {
        let data = candidate(.bibliographic, "球狀閃電", ["劉慈欣"], key: openLibrary("OL2W"), readable: false)
        #expect(SearchWorkResolver.resolve([data], query: "球狀閃電")[0].availability == .dataOnly)
        let source = row("球状闪电", "刘慈欣", origins: 1)
        let merged = SearchWorkResolver.resolve([data, source], query: "球狀閃電")
        #expect(merged.count == 1)
        #expect(merged[0].availability == .readable)
        #expect(merged[0].lead == source)
    }

    @Test("ties: score, then on the shelf, readable, data only; then the shorter title; then more sources")
    func ordering() {
        let dataOnly = candidate(.bibliographic, "三體", ["甲"], key: openLibrary("OL3W"), readable: false)
        let readable = row("三體", "乙", origins: 1)
        let onShelf = candidate(.shelf, "三體", ["丙"], key: .copy(UUID()))
        let prefixLong = row("三體前傳", "丁", origins: 1)
        let prefixShortFew = row("三體一", "戊", origins: 1)
        let prefixShortMany = row("三體二", "己", origins: 3)
        let input = [dataOnly, readable, prefixLong, onShelf, prefixShortFew, prefixShortMany]
        let ordered = SearchWorkResolver.resolve(input, query: "三体").map(\.lead.id)
        #expect(ordered == [onShelf.id, readable.id, dataOnly.id, prefixShortMany.id, prefixShortFew.id, prefixLong.id])
        #expect(SearchWorkResolver.resolve(input, query: "三体").map(\.lead.id) == ordered, "the same input gives the same list")
    }

    @Test("the grouping does not depend on the order candidates arrive in")
    func orderIndependentGrouping() {
        let a = candidate(.library, "三體", ["劉慈欣"], key: item(.opds, "a"))
        let b = row("三体", "刘慈欣", origins: 1)
        let c = candidate(.shelf, "三體", ["劉慈欣著"], key: .copy(UUID()))
        let forward = Set(SearchWorkResolver.resolve([a, b, c], query: "三體").map { Set($0.members.map(\.id)) })
        let backward = Set(SearchWorkResolver.resolve([c, b, a], query: "三體").map { Set($0.members.map(\.id)) })
        #expect(forward == backward)
        #expect(forward.count == 1)
    }

    // MARK: - Helpers

    private func candidate(_ kind: SearchCandidate.Kind, _ title: String, _ authors: [String], key: SourceItemKey,
                           identifiers: Set<ExternalIdentifier> = [], language: String? = nil,
                           kind contentKind: ContentKind = .text, readable: Bool = true) -> SearchCandidate {
        SearchCandidate(id: .item(key), kind: kind, title: title, titleKey: WorkMatchKey.title(title),
                        authorKeys: authors.map(WorkMatchKey.author), contentKind: contentKind,
                        language: LanguageTag(language)?.language, identifiers: identifiers, itemKeys: [key],
                        isReadable: readable, sourceCount: 1)
    }

    private func row(_ title: String, _ author: String, origins: Int) -> SearchCandidate {
        let id = UUID()
        let keys = SearchWorkKeys(name: title, author: author)
        return SearchCandidate(id: .bookSourceRow(id), kind: .bookSource, title: title, titleKey: keys.title,
                               authorKeys: keys.author.isEmpty ? [] : [keys.author], contentKind: .text, language: nil,
                               identifiers: [],
                               itemKeys: Set((0..<origins).map { item(.bookSource, "\(id)-\($0)") }),
                               isReadable: true, sourceCount: origins)
    }

    private func item(_ type: ProviderType, _ id: String) -> SourceItemKey {
        SourceItemKey(instance: SourceInstanceKey(type: type, id: "fixture-\(type)"), item: id)
    }

    private func openLibrary(_ work: String) -> SourceItemKey {
        SourceItemKey(instance: OpenLibrary.key, item: "/works/\(work)")
    }

    private func isbn(_ value: String) -> ExternalIdentifier {
        ExternalIdentifier.normalized(.isbn13, value)!
    }
}
