import Combine
import Foundation
import Testing
@testable import yuedu_app

// Every source in every layout of lists (maintainer, 2026-10-27): a card per list, from any
// sources, each its own row, loaded as a section of its list is.

/// A source that serves the bindings in `lists`, names each list by `names`, and records every load.
@MainActor
private final class ListProvider: HomeSectionProviding {
    let instance: SourceInstanceKey
    let displayName: String
    let availability: ProviderAvailability = .available
    let hosts: [String] = []
    /// What a list gives, by its binding; a binding served but not in it fails.
    var lists: [HomeSectionBinding: [CollectionEntry]]
    var names: [HomeSectionBinding: String] = [:]
    let serves: (HomeSectionBinding) -> Bool
    private(set) var loads: [HomeSection] = []

    init(_ id: String, type: ProviderType, lists: [HomeSectionBinding: [CollectionEntry]] = [:],
         serves: @escaping (HomeSectionBinding) -> Bool) {
        instance = SourceInstanceKey(type: type, id: id)
        displayName = id
        self.lists = lists
        self.serves = serves
    }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? { serves(section.binding) ? .parallel : nil }

    func rowName(for section: HomeSection) -> String { names[section.binding] ?? displayName }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        loads.append(section)
        guard let entries = lists[section.binding] else { throw URLError(.badServerResponse) }
        return entries
    }
}

private func book(_ title: String) -> CollectionEntry {
    let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .module, id: "m"), item: title),
                              title: title, authors: [], language: "zh", contentKind: .text, identifiers: [],
                              copyID: nil, acquisitions: [.viewOnly])
    return .item(record, WorkSummary(title: title, authors: [], cover: .generated(seed: title), blurb: nil,
                                     language: "zh", contentKind: .text), .bibliographic)
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("HomeListCards-\(UUID().uuidString)", isDirectory: true)
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

private func collections(_ state: HomeModel.RowState) -> [CollectionSummary]? {
    guard case .loaded(let entries) = state else { return nil }
    return entries.compactMap { entry in
        if case .collection(let summary) = entry { return summary }
        return nil
    }
}

@MainActor
@Suite("Home list cards", .serialized, .timeLimit(.minutes(1)))
struct HomeListCardsTests {
    private let hot = HomeSectionBinding.module(moduleID: "m", entryID: "hot")
    private let new = HomeSectionBinding.module(moduleID: "m", entryID: "new")
    private let empty = HomeSectionBinding.module(moduleID: "m", entryID: "empty")
    private let broken = HomeSectionBinding.module(moduleID: "m", entryID: "broken")

    private func category(_ title: String, source: String = "https://cards.test") -> ExploreCategoryReference {
        ExploreCategoryReference(sourceURL: source, title: title, url: "/\(title)")
    }

    private func module() -> ListProvider {
        let provider = ListProvider("m", type: .module, lists: [hot: [book("甲"), book("乙")], new: [book("丙")], empty: [], .latest: [book("丁")]]) {
            if case .module = $0 { return true }
            return $0 == .latest
        }
        provider.names = [hot: "熱門", new: "新書", empty: "空", broken: "壞"]
        return provider
    }

    // MARK: Choosing

    @Test("every layout for every source; what is lists alone, the layouts of lists")
    func choices() {
        for binding: HomeSectionBinding in [.latest, .continueReading, .bookshelf, .related, .aiRecommendations, .aozoraNew,
                                            .gutenbergCollection(id: "chinese"), hot,
                                            .sourceCategories([category("玄幻")]), .opdsFeed(connectionID: "c", url: "/new")] {
            #expect(HomeLayoutStyle.choices(for: binding) == HomeLayoutStyle.allCases, "\(binding)")
        }
        let lists = HomeLayoutStyle.allCases.filter(\.drawsLists)
        #expect(HomeLayoutStyle.choices(for: .gutenbergLists) == lists)
        #expect(HomeLayoutStyle.choices(for: .lists([HomeListCard(binding: hot)])) == lists)
    }

    @Test("a section's cards: none in a layout of books; its list as one card; a 來源配置's categories a card each, up to eight")
    func listCards() {
        #expect(HomeSection(layout: .row, binding: hot).listCards.isEmpty)
        #expect(HomeSection(layout: .collageCards, binding: hot, parameters: ["sort": "new"]).listCards
                == [HomeListCard(binding: hot, parameters: ["sort": "new"])])
        // A feed cannot name itself: its card keeps the name 選擇內容來源 gave the section.
        let feed = HomeSectionBinding.opdsFeed(connectionID: "c", url: "/new")
        #expect(HomeSection(layout: .collection, title: "新書", binding: feed).listCards == [HomeListCard(binding: feed, title: "新書")])

        let references = (1...10).map { category("分類\($0)") }
        let cards = HomeSection(layout: .categoryCards, binding: .sourceCategories(references), parameters: ["f": "1"]).listCards
        #expect(cards.count == HomeSection.listCardLimit)
        #expect(cards.first == HomeListCard(binding: .sourceCategories([references[0]]), parameters: ["f": "1"]))
        #expect(HomeSection(layout: .collection, binding: .lists((1...10).map { HomeListCard(binding: .module(moduleID: "m", entryID: "\($0)")) }))
                .listCards.count == HomeSection.listCardLimit)
    }

    @Test("cards are written in the oldest form that says them")
    func settingCards() {
        let section = HomeSection(layout: .collageCards, binding: .continueReading)
        let one = section.settingCards([HomeListCard(binding: hot, parameters: ["sort": "hot"])])
        #expect(one.binding == hot && one.parameters == ["sort": "hot"])

        let filters = HomeSection.filterParameters(["類型": "男頻"], sourceURL: "https://cards.test")
        let sameSource = section.settingCards([category("玄幻"), category("都市")].map {
            HomeListCard(binding: .sourceCategories([$0]), parameters: filters)
        })
        #expect(sameSource.binding == .sourceCategories([category("玄幻"), category("都市")]))
        #expect(sameSource.parameters == filters)

        let otherFilters = section.settingCards([
            HomeListCard(binding: .sourceCategories([category("玄幻")]), parameters: filters),
            HomeListCard(binding: .sourceCategories([category("都市")])),
        ])
        if case .lists(let cards) = otherFilters.binding { #expect(cards.count == 2) } else { Issue.record("expected .lists") }

        let mixed = section.settingCards([HomeListCard(binding: hot), HomeListCard(binding: .gutenbergShelf(id: "popular"))])
        #expect(mixed.binding == .lists([HomeListCard(binding: hot), HomeListCard(binding: .gutenbergShelf(id: "popular"))]))
        #expect(mixed.parameters.isEmpty)
        #expect(mixed.binding.contentOwner == nil)
        #expect(HomeSection(layout: .collection, binding: .lists([HomeListCard(binding: hot), HomeListCard(binding: new)]))
            .binding.contentOwner == .module(id: "m"))
    }

    // MARK: Stored

    @Test("a section of lists round-trips, a later build's card kept through an edit")
    func roundTripKeepsUnknown() throws {
        let section = HomeSection(layout: .collageCards, binding: .lists([
            HomeListCard(binding: hot, parameters: ["sort": "hot"]), HomeListCard(binding: .continueReading),
        ]))
        let data = try JSONEncoder().encode(section)
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == section)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var binding = try #require(json["binding"] as? [String: Any])
        var cards = try #require(binding["cards"] as? [[String: Any]])
        cards.append(["binding": ["type": "futureList", "shelf": "x"], "parameters": ["k": "v"]])
        binding["cards"] = cards
        json["binding"] = binding
        let later = try JSONDecoder().decode(HomeSection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(later.listCards.count == 2, "a card this build cannot draw is not drawn")

        let store = HomePageStore(fileURL: scratch().appendingPathComponent("explore_home.json"))
        let editor = HomeSectionEditor(section: later, store: store, preview: HomeModel(providers: { [] }, waitForSources: {}))
        editor.moveCards(fromOffsets: [1], toOffset: 0)
        guard case .lists(let edited) = editor.draft.binding else {
            Issue.record("expected .lists"); return
        }
        #expect(Array(edited.map(\.binding).prefix(2)) == [.continueReading, hot])
        #expect(edited.count == 3)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited[2])) as? [String: Any]
        #expect((written?["binding"] as? [String: Any])?["type"] as? String == "futureList")
        #expect((written?["binding"] as? [String: Any])?["shelf"] as? String == "x")
        #expect(written?["parameters"] as? [String: String] == ["k": "v"])
    }

    // MARK: The form

    @Test("加入清單 adds each list once, up to eight; the last card stays; a card's own values and order")
    func editor() {
        let store = HomePageStore(fileURL: scratch().appendingPathComponent("explore_home.json"))
        let editor = HomeSectionEditor(newSectionIn: store, layout: .collageCards,
                                       preview: HomeModel(providers: { [] }, waitForSources: {}))
        editor.addCards([.picked(hot, name: "熱門")])
        #expect(editor.draft.binding == hot, "one list is written as that list")
        #expect(editor.draft.layout == .collageCards)

        editor.addCards([.picked(hot, name: "熱門"), .picked(.gutenbergShelf(id: "popular"), name: "熱門")])
        #expect(editor.listCards.map(\.binding) == [hot, .gutenbergShelf(id: "popular")])

        editor.setCardParameter(at: 0, "sort", to: "new")
        #expect(editor.listCards[0].parameters == ["sort": "new"])
        editor.moveCards(fromOffsets: [0], toOffset: 2)
        #expect(editor.listCards.map(\.binding) == [.gutenbergShelf(id: "popular"), hot])

        editor.addCards((1...10).map { .picked(.module(moduleID: "m", entryID: "\($0)"), name: "") })
        #expect(editor.listCards.count == HomeSection.listCardLimit)
        #expect(!editor.canAddCard)

        for _ in 0..<HomeSection.listCardLimit { editor.removeCard(at: 0) }
        #expect(editor.listCards.count == 1, "the last card stays")

        // A feed picked alone titles the section, as 選擇內容來源 does; with more cards, the source does.
        let feed = HomeSectionBinding.opdsFeed(connectionID: "c", url: "/new")
        editor.replaceCard(at: 0, with: .picked(feed, name: "新書"))
        #expect(editor.draft.title == "新書")
        editor.addCards([.picked(hot, name: "熱門")])
        #expect(editor.draft.title.isEmpty)
        #expect(editor.listCards.first == HomeListCard(binding: feed, title: "新書"))
    }

    @Test("what is lists alone, chosen in a layout of books, turns the section to 專題集合")
    func chooseLists() {
        let store = HomePageStore(fileURL: scratch().appendingPathComponent("explore_home.json"))
        let editor = HomeSectionEditor(newSectionIn: store, layout: .row, preview: HomeModel(providers: { [] }, waitForSources: {}))
        editor.choose(.gutenbergLists)
        #expect(editor.draft.layout == .collection)
        editor.setLayout(.bannerCards)
        editor.choose(hot)
        #expect(editor.draft.layout == .bannerCards, "every source is drawn in a layout of lists")
    }

    // MARK: Loading

    @Test("a row per card, a card of 最新 a row per library; the cards come together, in order, the empty and the failed left out")
    func rowsAndCards() async {
        let module = module()
        let library = ListProvider("o", type: .opds) { $0 == .latest }
        let home = HomeModel(providers: { [module, library] }, waitForSources: {})
        let section = HomeSection(layout: .collageCards, binding: .lists([
            HomeListCard(binding: hot), HomeListCard(binding: empty), HomeListCard(binding: .latest),
            HomeListCard(binding: broken), HomeListCard(binding: new, parameters: ["sort": "new"]),
        ]))
        await home.sync(with: HomePage(sections: [section]))
        #expect(home.rows.map(\.id) == [
            HomeModel.rowID(section: section.id, card: 0, source: module.instance),
            HomeModel.rowID(section: section.id, card: 1, source: module.instance),
            HomeModel.rowID(section: section.id, card: 2, source: module.instance),
            HomeModel.rowID(section: section.id, card: 2, source: library.instance),
            HomeModel.rowID(section: section.id, card: 3, source: module.instance),
            HomeModel.rowID(section: section.id, card: 4, source: module.instance),
        ])
        #expect(home.rows[5].loadingSection.binding == new)
        #expect(home.rows[5].loadingSection.parameters == ["sort": "new"])

        home.load(home.rows[0].id)
        await until(home) { isSettled($0[0]) }
        guard case .loading = home.groups(in: nil).first?.state else {
            Issue.record("the section waits for every card"); return
        }

        for row in home.rows { home.load(row.id) }
        await until(home) { $0.allSatisfy(isSettled) }
        let group = home.groups(in: nil).first
        let cards = collections(group?.state ?? .loading) ?? []
        #expect(cards.map(\.title) == ["熱門", "m", "新書"], "the empty list, the failed one and the failing library are left out")
        #expect(cards.first?.books.map(\.title) == ["甲", "乙"])
        #expect(cards.first?.sourceName == "m")
        #expect(module.loads.count == 5)
        #expect(Set(module.loads.map(\.binding)) == [hot, empty, .latest, broken, new])
        #expect(module.loads.allSatisfy { $0.id == section.id && $0.layout == .collageCards })
        #expect(group?.title == localized("清單"), "cards from several sources")
    }

    @Test("the section fails only when every card failed")
    func allFailed() async {
        let module = module()
        let home = HomeModel(providers: { [module] }, waitForSources: {})
        let section = HomeSection(layout: .collection, binding: .lists([HomeListCard(binding: broken),
                                                                       HomeListCard(binding: .module(moduleID: "m", entryID: "gone"))]))
        await home.sync(with: HomePage(sections: [section]))
        for row in home.rows { home.load(row.id) }
        await until(home) { $0.allSatisfy(isSettled) }
        guard case .failed = home.groups(in: nil).first?.state else {
            Issue.record("expected the section to fail"); return
        }
    }

    @Test("a section of one module's lists is titled by the module; a layout change reloads, a layout of lists to another does not")
    func titleAndReload() async {
        let module = module()
        let home = HomeModel(providers: { [module] }, waitForSources: {})
        var section = HomeSection(layout: .collageCards, binding: .lists([HomeListCard(binding: hot), HomeListCard(binding: new)]))
        await home.sync(with: HomePage(sections: [section]))
        for row in home.rows { home.load(row.id) }
        await until(home) { $0.allSatisfy(isSettled) }
        #expect(home.groups(in: nil).first?.title == "m")
        #expect(ExplorePlace.listsPage(home.rows) == .explore(.module(id: "m")))

        section.layout = .bannerCards
        await home.sync(with: HomePage(sections: [section]))
        #expect(home.rows.allSatisfy(isSettled), "another layout of lists draws the same cards")
        #expect(module.loads.count == 2)

        #expect(!HomeSection(id: section.id, layout: .collageCards, binding: hot)
            .loadsSameContent(as: HomeSection(id: section.id, layout: .row, binding: hot)))
    }

    // MARK: Opening

    @Test("a card opens its list's page; a list with none, the books it drew; AI 推薦, its page")
    func opening() {
        let source = SourceInstanceKey(type: .module, id: "m")
        func card(_ binding: HomeSectionBinding, entries: [CollectionEntry] = [], source: SourceInstanceKey) -> CollectionSummary {
            let opening = HomeListOpening(section: HomeSection(layout: .row, binding: binding), source: source,
                                          sourceName: "熱門", title: "熱門", entries: entries)
            return CollectionSummary(id: "card", title: "熱門", books: [], languages: [], opening: .list(opening))
        }
        guard case .explore(.moduleList(let route)) = ExplorePlace.page(of: card(hot, source: source), aozoraIndex: nil) else {
            Issue.record("expected the module list's page"); return
        }
        #expect(route.entryID == "hot")

        let reference = category("玄幻")
        #expect(ExplorePlace.page(of: card(.sourceCategories([reference]), source: SourceInstanceKey(type: .bookSource, id: reference.sourceURL)),
                                  aozoraIndex: nil) == .explore(.sourceCategory(reference)))
        #expect(ExplorePlace.page(of: card(.aiRecommendations, source: AIRecommendationProvider.instanceKey),
                                  aozoraIndex: nil) == .explore(.aiRecommendations))
        #expect(ExplorePlace.page(of: card(.continueReading, entries: [book("甲")], source: .localLibrary), aozoraIndex: nil)
                == .list(HomeListRoute(title: "熱門", binding: .continueReading, entries: [book("甲")])))
        #expect(card(.continueReading, source: .localLibrary).homeIdentifier == "home.collection.list.熱門")
    }

    @Test("the header of cards from several sources opens nothing")
    func mixedHeader() {
        let section = HomeSection(layout: .collection, binding: .lists([HomeListCard(binding: hot), HomeListCard(binding: .continueReading)]))
        let rows = [(0, SourceInstanceKey(type: .module, id: "m")), (1, SourceInstanceKey.localLibrary)].map { card, source in
            HomeModel.Row(id: HomeModel.rowID(section: section.id, card: card, source: source), section: section, source: source,
                          sourceName: "", policy: .local, state: .idle)
        }
        #expect(ExplorePlace.listsPage(rows) == nil)
        #expect(ExplorePlace.showAll(rows[0], aozoraIndex: nil) == nil)
    }

    // MARK: Names

    @Test("a module list's card names the options its own values pick")
    func moduleCardName() throws {
        let entry = try #require(RuleModulePreviewData.module().modules.first { $0.id == "new" })
        #expect(entry.cardName("新書", parameters: ["sort": "hot"]) == "新書 · 熱門")
        #expect(entry.cardName("新書", parameters: [:]) == "新書")
        #expect(entry.cardName("新書", parameters: ["q": "龍"]) == "新書", "only a choice is named")
    }
}
