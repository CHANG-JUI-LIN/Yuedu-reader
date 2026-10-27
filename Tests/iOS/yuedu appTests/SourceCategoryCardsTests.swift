import Combine
import Foundation
import Testing
@testable import yuedu_app

// 分類卡片 of a 來源配置's section (maintainer, 2026-10-26): a card per category the section keeps,
// each its first page's first covers, through the home's one first-page fetcher. Since 2026-10-27
// each card is a row of its own (`HomeListCards.swift`).

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
private func until(_ model: HomeModel, _ condition: @escaping ([HomeModel.Row]) -> Bool) async {
    for await rows in model.$rows.values where condition(rows) { break }
}

private func isSettled(_ row: HomeModel.Row) -> Bool {
    switch row.state {
    case .loaded, .failed: true
    default: false
    }
}

@MainActor
@Suite("Source category cards", .serialized, .timeLimit(.minutes(1)))
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

    /// The section as the home draws it, once every card's row has loaded.
    private func loaded(_ section: HomeSection, by provider: BookSourceProvider) async -> (HomeModel, HomeSectionGroup?) {
        let home = HomeModel(providers: { [provider] }, waitForSources: {})
        await home.sync(with: HomePage(sections: [section]))
        for row in home.rows { home.load(row.id) }
        await until(home) { $0.allSatisfy(isSettled) }
        return (home, home.groups(in: nil).first)
    }

    private func cards(_ group: HomeSectionGroup?) -> [CollectionSummary]? {
        guard case .loaded(let entries) = group?.state else { return nil }
        return entries.compactMap { entry in
            if case .collection(let card) = entry { return card }
            return nil
        }
    }

    @Test("a 來源配置's categories are offered every layout, 分類卡片 among them")
    func choices() {
        #expect(HomeLayoutStyle.choices(for: .sourceCategories([category("玄幻")])) == HomeLayoutStyle.allCases)
    }

    @Test("a card per category, in the section's order, each its first page's first covers, one request each")
    func cards() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": ["甲", "乙", "丙", "丁"].map(book), "/都市": [book("戊")]])
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻"), category("都市")]))
        let (home, group) = await loaded(section, by: provider)
        #expect(home.rows.map(\.policy) == [.serialPerSource, .serialPerSource])

        let cards = try #require(cards(group))
        #expect(cards.map(\.title) == ["玄幻", "都市"])
        #expect(cards.first?.books.prefix(3).map(\.title) == ["甲", "乙", "丙"])
        #expect(cards.first?.bookCount == 4)
        #expect(cards.last?.books.map(\.title) == ["戊"])
        guard case .list(let opening) = cards.first?.opening else {
            Issue.record("expected the category's list"); return
        }
        #expect(opening.section.binding == .sourceCategories([category("玄幻")]))
        #expect(cards.first?.books.first?.cover == .remote(URL(string: "https://cards.test/cover/%E7%94%B2.jpg")!, headers: [:]))
        #expect(await requests.log.sorted() == ["/玄幻", "/都市"].sorted())
    }

    @Test("a category that fails or holds nothing has no card; the section fails only when no card is left and one failed")
    func failures() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": [book("甲")], "/空": []])
        let mixed = HomeSection(layout: .categoryCards,
                                binding: .sourceCategories([category("壞"), category("玄幻"), category("空")]))
        let mixedGroup = await loaded(mixed, by: provider).1
        #expect(cards(mixedGroup)?.map(\.title) == ["玄幻"])

        let broken = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("壞"), category("空")]))
        guard case .failed = await loaded(broken, by: provider).1?.state else {
            Issue.record("expected the section to fail"); return
        }

        let empty = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("空")]))
        let emptyGroup = await loaded(empty, by: provider).1
        #expect(cards(emptyGroup) == [])
    }

    @Test("at most eight cards, so eight requests")
    func limit() async throws {
        let requests = Requests()
        let titles = (1...10).map { "分類\($0)" }
        let provider = provider(requests, pages: Dictionary(uniqueKeysWithValues: titles.map { ("/\($0)", [book($0)]) }))
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories(titles.map(category)))
        #expect(section.listCards.count == HomeSection.listCardLimit)
        let (home, group) = await loaded(section, by: provider)
        #expect(home.rows.count == HomeSection.listCardLimit)
        #expect(cards(group)?.count == HomeSection.listCardLimit)
        #expect(await requests.log.count == HomeSection.listCardLimit)
    }

    @Test("the same section as a row draws the first category's books and asks for it alone")
    func rowLayout() async throws {
        let requests = Requests()
        let provider = provider(requests, pages: ["/玄幻": [book("甲")], "/都市": [book("乙")]])
        let section = HomeSection(layout: .row, binding: .sourceCategories([category("玄幻"), category("都市")]))
        #expect(section.listCards.isEmpty)
        #expect(section.drawnCategories == [category("玄幻")])
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
        let cardSection = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻")]))
        async let row = provider.load(HomeSection(layout: .row, binding: .sourceCategories([category("玄幻")])))
        async let card = provider.load(cardSection.cardSection(cardSection.listCards[0]))
        let (rowEntries, cardEntries) = try await (row, card)
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
    func places() async throws {
        let reference = category("玄幻")
        let provider = provider(Requests(), pages: ["/玄幻": [book("甲")]])
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([reference]))
        let (home, group) = await loaded(section, by: provider)
        let card = try #require(cards(group)?.first)
        #expect(ExplorePlace.page(of: card, aozoraIndex: nil) == .explore(.sourceCategory(reference)))
        #expect(card.homeIdentifier == "home.collection.sourceCategory.玄幻")
        #expect(ExplorePlace.listsPage(home.rows) == .explore(.source(sourceURL: sourceURL)))
        #expect(group?.title == "卡片源")
        var asRow = section
        asRow.layout = .row
        #expect(asRow.displayTitle(sourceName: "卡片源") == "玄幻")
    }

    @Test("a 分類卡片 section round-trips with every category")
    func roundTrip() throws {
        let section = HomeSection(layout: .categoryCards, binding: .sourceCategories([category("玄幻"), category("都市")]))
        let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
        #expect(decoded == section)
        #expect(decoded.drawnCategories == [category("玄幻"), category("都市")])
    }

    @Test("加入清單 adds categories at the end, never one twice nor a ninth; one source's stay 分類卡片, another's mixes")
    func editor() {
        let store = HomePageStore(fileURL: scratch().appendingPathComponent("explore_home.json"))
        let editor = HomeSectionEditor(newSectionIn: store, layout: .categoryCards,
                                       preview: HomeModel(providers: { [] }, waitForSources: {}))
        let first = category("玄幻")
        editor.choose(.sourceCategories([first]))
        #expect(editor.draft.layout == .categoryCards)

        editor.addCards([HomeListCard(binding: .sourceCategories([category("都市")]))])
        #expect(editor.draft.binding == .sourceCategories([first, category("都市")]))
        editor.addCards([HomeListCard(binding: .sourceCategories([category("都市")]))])
        #expect(editor.listCards.count == 2)

        editor.removeCard(at: 1)
        editor.removeCard(at: 0)
        #expect(editor.draft.binding == .sourceCategories([first]), "the last category stays")

        let other = ExploreCategoryReference(sourceURL: "https://other.test", title: "外", url: "/外")
        editor.addCards([HomeListCard(binding: .sourceCategories([other]))])
        guard case .lists(let cards) = editor.draft.binding else {
            Issue.record("another source's category mixes in"); return
        }
        #expect(cards.map(\.binding) == [.sourceCategories([first]), .sourceCategories([other])])

        editor.addCards((2...10).map { HomeListCard(binding: .sourceCategories([category("分類\($0)")])) })
        #expect(editor.listCards.count == HomeSection.listCardLimit)
        #expect(!editor.canAddCard)
    }
}
