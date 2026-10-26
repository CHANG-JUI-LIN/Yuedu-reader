import Foundation
import Testing
@testable import yuedu_app

// 分類卡片 of a 來源配置's section (maintainer, 2026-10-26): a card per category the section keeps,
// each its first page's first covers, through the home's one first-page fetcher.

private actor Requests {
    private(set) var log: [String] = []
    func add(_ entry: String) { log.append(entry) }
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SourceCategoryCards-\(UUID().uuidString)", isDirectory: true)
}

private func book(_ name: String) -> OnlineBook {
    OnlineBook(name: name, author: "作者", intro: "", coverUrl: "/cover/\(name).jpg", bookUrl: "https://cards.test/book/\(name)",
               tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: "S")
}

@MainActor
@Suite("Source category cards", .serialized)
struct SourceCategoryCardsTests {
    private let sourceURL = "https://cards.test"

    private func source() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "卡片源"
        source.bookSourceUrl = sourceURL
        return source
    }

    private func category(_ title: String) -> ExploreCategoryReference {
        ExploreCategoryReference(sourceURL: sourceURL, title: title, url: "/\(title)")
    }

    /// A provider whose category pages are `pages[url]`; a URL not in it fails.
    private func provider(_ requests: Requests, pages: [String: [OnlineBook]]) -> BookSourceProvider {
        let firstPages = DiscoverFirstPages(
            pageLoader: SectionPageLoader { item, _, _ in
                let url = item.url ?? ""
                await requests.add(url)
                guard let books = pages[url] else { throw URLError(.badServerResponse) }
                return books
            },
            primeCookies: { _ in }, store: ForYouCandidateStore(directory: scratch()), lanes: DiscoverRequestLanes())
        return BookSourceProvider(source: source(), firstPages: firstPages)
    }

    @Test("分類卡片 is offered for a 來源配置's categories, beside the layouts of books")
    func choices() {
        let choices = HomeLayoutStyle.choices(for: .sourceCategories([category("玄幻")]))
        #expect(choices == HomeLayoutStyle.allCases.filter { !$0.drawsLists } + [.categoryCards])
        #expect(HomeLayoutStyle.choices(for: .gutenbergLists) == [.collection, .categoryCards, .collageCards])
    }

    @Test("a card per category, in the section's order, each its first page's first three covers, one request each")
    func cards() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": ["甲", "乙", "丙", "丁"].map(book), "/都市": [book("戊")]])
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻"), category("都市")]))
        #expect(provider.loadPolicy(for: section) == .serialPerSource)

        let cards = try await provider.load(section).compactMap { entry -> CollectionSummary? in
            if case .collection(let card) = entry { return card }
            return nil
        }
        #expect(cards.map(\.title) == ["玄幻", "都市"])
        #expect(cards.first?.books.map(\.title) == ["甲", "乙", "丙"])
        #expect(cards.last?.books.map(\.title) == ["戊"])
        #expect(cards.first?.opening == .sourceCategory(category("玄幻")))
        #expect(cards.first?.books.first?.cover == .remote(URL(string: "https://cards.test/cover/%E7%94%B2.jpg")!, headers: [:]))
        #expect(await requests.log.sorted() == ["/玄幻", "/都市"].sorted())
    }

    @Test("a category that fails or holds nothing has no card; the section fails only when no card is left and one failed")
    func failures() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": [book("甲")], "/空": []])
        let mixed = HomeSection(layout: .categoryCards,
                                binding: .sourceCategories([category("壞"), category("玄幻"), category("空")]))
        let entries = try await provider.load(mixed)
        #expect(entries.count == 1)

        let broken = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("壞"), category("空")]))
        await #expect(throws: (any Error).self) { try await provider.load(broken) }

        let empty = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("空")]))
        #expect(try await provider.load(empty).isEmpty)
    }

    @Test("at most eight cards, so eight requests")
    func limit() async throws {
        let requests = Requests()
        let titles = (1...10).map { "分類\($0)" }
        let provider = provider(requests, pages: Dictionary(uniqueKeysWithValues: titles.map { ("/\($0)", [book($0)]) }))
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories(titles.map(category)))
        #expect(section.shownCategories.count == HomeSection.categoryCardLimit)
        #expect(try await provider.load(section).count == HomeSection.categoryCardLimit)
        #expect(await requests.log.count == HomeSection.categoryCardLimit)
    }

    @Test("the same section as a row draws the first category's books and asks for it alone")
    func rowLayout() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": [book("甲")], "/都市": [book("乙")]])
        let section = HomeSection(layout: .row, binding: .sourceCategories([category("玄幻"), category("都市")]))
        #expect(!section.drawsCategoryCards)
        #expect(section.shownCategories == [category("玄幻")])
        guard case .item(_, let summary, _) = try await provider.load(section).first else {
            Issue.record("expected a book"); return
        }
        #expect(summary.title == "甲")
        #expect(await requests.log == ["/玄幻"])
    }

    @Test("a card and a row of the same category share one request")
    func sharedRequest() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": [book("甲")]])
        async let row = provider.load(HomeSection(layout: .row, binding: .sourceCategories([category("玄幻")])))
        async let cards = provider.load(HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻")])))
        let (rowEntries, cardEntries) = try await (row, cards)
        #expect(rowEntries.count == 1 && cardEntries.count == 1)
        #expect(await requests.log == ["/玄幻"])
    }

    @Test("switching between a row and 分類卡片 loads again; 為你推薦 mixes only the categories drawn")
    func reloadAndForYou() {
        let references = [category("玄幻"), category("都市")]
        let row = HomeSection(layout: .row, binding: .sourceCategories(references))
        var cards = row
        cards.layout = .categoryCards
        var list = row
        list.layout = .list
        #expect(!row.loadsSameContent(as: cards))
        #expect(row.loadsSameContent(as: list))

        let forYou = HomeSection(layout: .row, binding: .forYou)
        #expect(ForYouInputs.categories(on: [row], for: forYou) == [references[0]])
        #expect(ForYouInputs.categories(on: [cards], for: forYou) == references)
    }

    @Test("a card opens its category, the header the source's own page; the section is titled by its source")
    func places() {
        let reference = category("玄幻")
        let card = CollectionSummary.sourceCategory(reference, firstPage: [book("甲")], source: source())
        #expect(ExplorePlace.page(of: card) == .explore(.sourceCategory(reference)))
        #expect(card.homeIdentifier == "home.collection.sourceCategory.玄幻")

        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([reference]))
        let row = HomeModel.Row(id: "row", section: section, source: SourceInstanceKey(type: .bookSource, id: sourceURL),
                                sourceName: "卡片源", policy: .serialPerSource, state: .idle)
        #expect(ExplorePlace.showAll(row, aozoraIndex: nil) == .explore(.source(sourceURL: sourceURL)))
        #expect(section.displayTitle(sourceName: "卡片源") == "卡片源")
        var asRow = section
        asRow.layout = .row
        #expect(asRow.displayTitle(sourceName: "卡片源") == "玄幻")
    }

    @Test("a 分類卡片 section round-trips with every category")
    func roundTrip() throws {
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻"), category("都市")]))
        let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
        #expect(decoded == section)
        #expect(decoded.shownCategories == [category("玄幻"), category("都市")])
    }

    @Test("加入分類 ticks a category on at the end and off again, never the last one, nor another source's, nor a ninth")
    func editor() {
        let store = HomePageStore(fileURL: scratch().appendingPathComponent("explore_home.json"))
        let editor = HomeSectionEditor(newSectionIn: store, layout: .categoryCards,
                                       preview: HomeModel(providers: { [] }, waitForSources: {}))
        let first = category("玄幻")
        editor.choose(.sourceCategories([first]))
        #expect(editor.draft.layout == .categoryCards)
        #expect(editor.cardCategories == [first])

        editor.toggleCardCategory(category("都市"), filterValues: ["发现页类型": "男频"])
        #expect(editor.cardCategories == [first, category("都市")])
        #expect(editor.filterValues(forSourceURL: sourceURL) == ["发现页类型": "男频"])
        editor.toggleCardCategory(category("都市"), filterValues: [:])
        #expect(editor.cardCategories == [first])

        editor.removeCardCategory(first)
        #expect(editor.cardCategories == [first], "the last category stays")
        editor.toggleCardCategory(ExploreCategoryReference(sourceURL: "https://other.test", title: "外", url: "/外"), filterValues: [:])
        #expect(editor.cardCategories == [first], "another source's category is not added")

        for index in 2...10 { editor.toggleCardCategory(category("分類\(index)"), filterValues: [:]) }
        #expect(editor.cardCategories.count == HomeSection.categoryCardLimit)
        #expect(!editor.canAddCardCategory)
    }
}
