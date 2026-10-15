import Foundation
import Testing
@testable import yuedu_app

/// 範圍's public library as a home of its own sections (decision 35, revised 2026-10-12): the
/// home's layouts, the library's content and titles.
@Suite("Library home page")
struct LibraryHomePageTests {
    private let aozora = SourceInstanceKey(type: .aozora, id: "aozora")
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: "gutenberg")

    @Test("青空文庫 shows 新上架作品, then its three indexes")
    func aozoraSections() throws {
        let page = try #require(LibraryHomePage.page(for: aozora, languages: ["ja"]))
        #expect(page.sections.map(\.binding) == [.aozoraNew, .aozoraIndex(kind: "authors"), .aozoraIndex(kind: "titles"),
                                                  .aozoraIndex(kind: "categories")])
        #expect(page.sections[0].displayTitle(sourceName: "") == localized(AozoraBrowseMode.newest.titleKey))
        #expect(page.sections.allSatisfy { $0.layout == .row })
    }

    @Test("Gutenberg shows its shelves in the reader's languages, then its bundled lists")
    func gutenbergSections() throws {
        let page = try #require(LibraryHomePage.page(for: gutenberg, languages: ["zh"]))
        let bindings = page.sections.map(\.binding)
        #expect(bindings.first == .gutenbergShelf(id: "popular"))
        #expect(bindings.contains(.gutenbergShelf(id: "latest")))
        #expect(bindings.contains(.gutenbergShelf(id: "zh")))
        // 精選書單 leads the bundled lists (專題集合, a338bbea), so they are one more than the lists.
        #expect(Array(bindings.suffix(HomeSectionBinding.gutenbergCollections.count)) == HomeSectionBinding.gutenbergCollections)
        #expect(bindings.filter { $0 == .gutenbergLists }.count == 1)
    }

    /// A row's id is its section's: an id made anew on every build would load every row again
    /// whenever the page is built again.
    @Test("the same library builds the same section ids")
    func stableIDs() throws {
        let first = try #require(LibraryHomePage.page(for: aozora, languages: ["ja"]))
        let second = try #require(LibraryHomePage.page(for: aozora, languages: ["ja"]))
        #expect(first.sections.map(\.id) == second.sections.map(\.id))
        #expect(Set(first.sections.map(\.id)).count == first.sections.count)
        let other = try #require(LibraryHomePage.page(for: gutenberg, languages: ["ja"]))
        #expect(Set(first.sections.map(\.id)).isDisjoint(with: other.sections.map(\.id)))
    }

    @Test("a connection or a book source keeps its own page")
    func othersHaveNone() {
        #expect(LibraryHomePage.page(for: SourceInstanceKey(type: .opds, id: "c1"), languages: []) == nil)
        #expect(LibraryHomePage.page(for: SourceInstanceKey(type: .webDAV, id: "c2"), languages: []) == nil)
        #expect(LibraryHomePage.page(for: SourceInstanceKey(type: .bookSource, id: "https://s.example"), languages: []) == nil)
    }
}
