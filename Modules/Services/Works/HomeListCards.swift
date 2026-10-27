import Foundation

// Every source in every layout of lists (maintainer, 2026-10-27: 「所有欄目，都是提供給所有的來源
// 選擇的不管是不是官方模組」). 專題集合, 分類卡片, 拼貼卡片 and 大圖卡片 draw a card per list, and a
// list is whatever a section of books shows: a module's list, a 來源配置's category, a library's
// feed, 古騰堡's shelves and lists, 青空文庫's, App 資料's.
// - A section's cards (`HomeSection.listCards`): a `.lists` section's own, as the reader put them
//   together in its form, from any sources, each with its own parameters (趨勢's 地區); a 來源配置's
//   categories a card each, as 分類卡片 drew them since 2026-10-26; any other binding one card of
//   itself, so 呈現方式 offers the layouts of lists to every section without changing what it stores.
// - Each card is a row of its own (`HomeModel.Row.card`), loaded as a section of its binding is,
//   by the provider that serves it and under its policy: a 來源配置's categories one at a time,
//   古騰堡's with the home. 最新 is a card per library, as it is a row per library. A row that gives
//   lists itself gives a card each: 精選書單's bundled lists, the 書架's groups.
// - A card's covers are its list's first books and its name the list's own. It opens what the
//   list's 查看全部 opens, or, for a list with no page of its own (繼續閱讀, 為你推薦, a 書架 group…),
//   the books it drew (`HomeListRoute`).
// - The section shows once every card has loaded, as 分類卡片 did: a card that failed or holds
//   nothing is left out (the model logs it), and the section fails only when every card did.
// - A build before `.lists` reads it as `.unknown`, keeps it and draws nothing for it. A section of
//   one list, or of one 來源配置's categories, is written as before (`HomeSection.settingCards`).

/// One card of a section of lists: the list it shows, with its own parameter values.
struct HomeListCard: Codable, Hashable, Sendable {
    var binding: HomeSectionBinding
    /// The list's parameters by name, as a section's (`HomeSection.parameters`): a module list's
    /// values, a 來源配置 category's filters.
    var parameters: [String: String]
    /// The list's name for a binding that cannot name itself (a feed), from 選擇內容來源; empty
    /// follows the list.
    var title: String

    init(binding: HomeSectionBinding, parameters: [String: String] = [:], title: String = "") {
        self.binding = binding
        self.parameters = parameters
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case binding, parameters, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binding = try container.decode(HomeSectionBinding.self, forKey: .binding)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binding, forKey: .binding)
        if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
        if !title.isEmpty { try container.encode(title, forKey: .title) }
    }

    /// A list as a card: one that cannot name itself (a feed) keeps the name it was picked by.
    static func picked(_ binding: HomeSectionBinding, parameters: [String: String] = [:], name: String) -> HomeListCard {
        HomeListCard(binding: binding, parameters: parameters, title: binding.namesItsList ? "" : name)
    }

    /// Whether this build can load it: a list it knows, not a section of lists inside another.
    var isDrawable: Bool {
        switch binding {
        case .lists, .myLibrary, .unknown: false
        default: true
        }
    }
}

extension HomeSectionBinding {
    /// Whether its list has a name of its own: a feed has none but the one it was picked by. A
    /// module's list is named by its module (`ModuleProvider.rowName`), in the app's language.
    var namesItsList: Bool {
        switch self {
        case .opdsFeed, .gutenbergFeed, .lists, .myLibrary, .unknown: false
        default: true
        }
    }

    /// What only a layout of lists can draw: 精選書單, the bundled lists, and a section of lists.
    var drawsOnlyLists: Bool {
        switch self {
        case .gutenbergLists, .lists: true
        default: false
        }
    }
}

extension HomeSection {
    /// The most cards a section keeps (maintainer, 2026-10-26): the section shows once they all
    /// have loaded.
    static let listCardLimit = 8

    /// Drawn as lists, a card each: 專題集合, 分類卡片, 拼貼卡片, 大圖卡片.
    var drawsLists: Bool { layout.style.drawsLists }

    /// The cards the section draws in a layout of lists, at most `listCardLimit`; none in a
    /// layout of books.
    var listCards: [HomeListCard] {
        guard drawsLists else { return [] }
        switch binding {
        case .lists(let cards):
            return Array(cards.filter(\.isDrawable).prefix(Self.listCardLimit))
        case .sourceCategories(let references):
            // The section's parameters hold each source's filters (`HomeSection.filtersKey`).
            return references.prefix(Self.listCardLimit).map { HomeListCard(binding: .sourceCategories([$0]), parameters: parameters) }
        case .myLibrary, .unknown:
            return []
        default:
            // A feed is named by the section, which 選擇內容來源 titled after it.
            return [.picked(binding, parameters: parameters, name: title)]
        }
    }

    /// A card's list as a section of its own, which its row loads: in the section's layout, so a
    /// provider that lists groups (the 書架's) gives them as lists.
    func cardSection(_ card: HomeListCard) -> HomeSection {
        HomeSection(id: id, layout: layout, binding: card.binding, parameters: card.parameters)
    }

    /// The section with `cards`, written in the oldest form that says them, so a build before
    /// `.lists` still draws what it can: one card as its own binding and parameters, one
    /// 來源配置's categories under one set of filters as `.sourceCategories`. Every card is kept,
    /// those this build cannot draw too; `listCards` draws the first ones it can.
    func settingCards(_ cards: [HomeListCard]) -> HomeSection {
        var section = self
        if cards.count == 1, let card = cards.first, card.isDrawable {
            section.binding = card.binding
            section.parameters = card.parameters
            return section
        }
        let references = cards.compactMap { card -> ExploreCategoryReference? in
            guard case .sourceCategories(let references) = card.binding, references.count == 1 else { return nil }
            return references.first
        }
        if !references.isEmpty, references.count == cards.count, Set(references.map(\.sourceURL)).count == 1,
           Set(cards.map(\.parameters)).count == 1 {
            section.binding = .sourceCategories(references)
            section.parameters = cards[0].parameters
            return section
        }
        section.binding = .lists(cards)
        section.parameters = [:]
        return section
    }
}

// MARK: - A card

/// What a card opens: its list's 查看全部, made from the row it loaded in, and the books it drew
/// for a list with no page of its own. Frozen when the card is made (CLAUDE.md, "Freeze data at
/// search navigation boundaries").
struct HomeListOpening: Hashable, Sendable {
    /// The card's list as a section of books, which `ExplorePlace.showAll` reads.
    let section: HomeSection
    let source: SourceInstanceKey
    /// The row's name (`HomeSectionProviding.rowName`), which a list titled by its source reads.
    let sourceName: String
    let title: String
    /// What the card's row loaded, at most `HomeRow.limit`.
    let entries: [CollectionEntry]
}

extension HomeModel.Row {
    /// A card's name: its own (a feed's, from 選擇內容來源), else its list's; a library's 最新 by
    /// the library, since every card of 最新 is one.
    var cardTitle: String {
        if let title = card?.title, !title.isEmpty { return title }
        let list = loadingSection
        if list.binding == .latest { return sourceName }
        return HomeSection(layout: .row, binding: list.binding, parameters: list.parameters).displayTitle(sourceName: sourceName)
    }
}

extension CollectionSummary {
    /// A card row's cards: those it gave as lists, in 偏好閱讀語言's order as 精選書單's were; else
    /// one card of its books, an article's image as its cover, or of its places (青空文庫's
    /// indexes), which have none. A row with neither has no card.
    static func cards(of row: HomeModel.Row, entries: [CollectionEntry],
                      languages: ReadingLanguagePreferences?) -> [CollectionSummary] {
        let lists = (languages?.arrange(entries) ?? entries).compactMap { entry -> CollectionSummary? in
            if case .collection(let list) = entry { return list }
            return nil
        }
        if !lists.isEmpty { return lists }
        var books: [WorkSummary] = []
        var bookLanguages: [String] = []
        var hasPlaces = false
        for entry in entries {
            switch entry {
            case .item(let record, let summary, _):
                books.append(summary)
                bookLanguages.append(summary.language ?? record.language ?? "")
            case .article(let article):
                books.append(WorkSummary(title: article.title, authors: article.feedName.isEmpty ? [] : [article.feedName],
                                         cover: article.imageURL.map { .remote($0, headers: [:]) } ?? .generated(seed: article.title),
                                         blurb: nil, language: nil, contentKind: .text))
            case .location:
                hasPlaces = true
            case .collection:
                break
            }
        }
        guard !books.isEmpty || hasPlaces else { return [] }
        let title = row.cardTitle
        let list = row.loadingSection
        let opening = HomeListOpening(section: HomeSection(id: list.id, layout: .row, binding: list.binding, parameters: list.parameters),
                                      source: row.source, sourceName: row.sourceName, title: title,
                                      entries: Array(entries.prefix(HomeRow.limit)))
        return [CollectionSummary(id: row.id, title: title, books: books, languages: bookLanguages, opening: .list(opening),
                                  sourceName: row.providerName)]
    }

    /// A card while its row loads: its name over blank covers.
    static func loading(_ row: HomeModel.Row) -> CollectionSummary {
        CollectionSummary(id: row.id, title: row.cardTitle,
                          books: (0..<artworkLimit).map { _ in
                              WorkSummary(title: "", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text)
                          },
                          languages: [],
                          opening: .list(HomeListOpening(section: row.loadingSection, source: row.source, sourceName: row.sourceName,
                                                         title: row.cardTitle, entries: [])))
    }
}

/// A card's books, for a list with no page of its own: 繼續閱讀, 為你推薦, 相關, 系列下一本, a 書架
/// group. What the card drew, frozen in the route.
struct HomeListRoute: Hashable {
    let title: String
    /// The card's list, so a shelf copy on 繼續閱讀 or 書架 opens its reader as their cards do.
    let binding: HomeSectionBinding
    let entries: [CollectionEntry]
}
