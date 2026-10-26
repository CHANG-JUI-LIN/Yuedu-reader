import Foundation

// Unified library 5a: the Explore home's sections. Design
// `Technotes/UnifiedLibrary-2026-10-08-design.md` §13.3–§13.4; Phase 5 plan, decisions 6–11.
//
// The file is read by builds older and newer than this one, so decoding is tolerant: a binding
// or layout this build does not know is kept as it was and written back unchanged. Anything
// else a later build changes — a new field on a section, a new field on a known binding —
// must raise `HomePage.currentSchemaVersion`, because this build drops what it cannot name.

/// How a section is drawn: today's seven custom-page layouts, plus 磚塊 (我的書庫) and a
/// single row. A string, so a layout a later build adds survives this one.
struct HomeSectionLayout: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ kind: CustomExploreComponent.Kind) { rawValue = kind.rawValue }

    /// One tile per place (我的書庫, no longer drawn: see `HomeSectionBinding.myLibrary`).
    static let tiles = Self(rawValue: "tiles")
    /// 橫向單排書架: one row of covers that swipes sideways.
    static let row = Self(rawValue: "row")
    /// 大型閱讀卡片 (5d-3).
    static let readingCard = Self(rawValue: "readingCard")
    /// 精簡閱讀卡片 (5d-3c): a small cover and the title, author, kind and progress on the
    /// cover's colour, as Apple Books' Continue.
    static let compactReadingCard = Self(rawValue: "compactReadingCard")
    /// 多行橫向輪播 (5d-3).
    static let multiRow = Self(rawValue: "multiRow")
    /// 固定封面網格 (5d-3).
    static let coverGrid = Self(rawValue: "coverGrid")
    /// 圖文資訊清單 (5d-3), and the same with ranks: two values, so a rank needs no field of
    /// its own, which would raise `HomePage.currentSchemaVersion`.
    static let list = Self(rawValue: "list")
    static let rankedList = Self(rawValue: "rankedList")
    /// 精選 (decisions 30 and 37): one book to a page, a large cover beside its title, author,
    /// category and blurb, paged sideways. A build before it draws a row and keeps the value.
    static let featured = Self(rawValue: "featured")
    /// 專題集合 (decisions 30 and 37): a card per list, its name over artwork made of its first
    /// covers. A section of lists only; a build before it keeps the value.
    static let collection = Self(rawValue: "collection")
    /// The layouts after Apple Books' store and home (maintainer, 2026-10-25;
    /// `Technotes/AppleBooksHomeLayouts-2026-10-25.md`). A build before them draws a row, or
    /// 專題集合 for a section of lists, and keeps the value.
    /// 色帶書架: large covers under the header, all on the first cover's colour, as Apple Books
    /// Japan's manga band.
    static let band = Self(rawValue: "band")
    /// 大型封面書架: about two large covers to a phone, as Apple Books' 新刊&話題作.
    static let largeRow = Self(rawValue: "largeRow")
    /// 一大四小: one large cover and four small ones beside it, a group at a time, as Apple
    /// Books' Special Offers.
    static let heroGrid = Self(rawValue: "heroGrid")
    /// 橫向單排書架 with its ranks under the covers, as Apple Books' charts.
    static let rankedRow = Self(rawValue: "rankedRow")
    /// 分類卡片: a wide card per list, its name beside its covers, as Apple Books' More to Explore.
    static let categoryCards = Self(rawValue: "categoryCards")
    /// 拼貼卡片: a card per list, its covers in a collage over its name, as Apple Books' Top Picks.
    static let collageCards = Self(rawValue: "collageCards")

    /// The custom-page layout this is, if it is one.
    var componentKind: CustomExploreComponent.Kind? { .init(rawValue: rawValue) }

    var isKnown: Bool {
        componentKind != nil || [.tiles, .row, .readingCard, .compactReadingCard, .multiRow, .coverGrid, .list, .rankedList,
                                 .featured, .collection, .band, .largeRow, .heroGrid, .rankedRow, .categoryCards,
                                 .collageCards].contains(self)
    }
}

/// What a section shows (design §13.4).
enum HomeSectionBinding: Hashable, Sendable {
    /// 我的書庫: a tile for every place. Not drawn since unified library 5d-1 (settled
    /// decision 12: the libraries are reached from 範圍); kept so a saved page round-trips
    /// and an older build still shows it.
    case myLibrary
    /// 繼續閱讀, across every source.
    case continueReading
    /// 書架 (feedback #24; maintainer, 2026-10-20): the shelf's books in the 書架 tab's order,
    /// each opening its reader as the tab's cards do. Not 我的書庫, which drew the places. A
    /// build before it reads it as `.unknown` and writes it back as it came.
    case bookshelf
    /// 最新: one row per source that has a 最新 (plan decision 10), except those 聚合設定's
    /// 顯示在最新 turns off (5d-3f, decision 21). Until 5d-3f the section kept its own
    /// `excluded` list; `HomePageStore.legacyLatestExcluded` reads it for the move.
    case latest
    /// Categories of one book source: 加入首頁配置's, and a custom page's block moved in (5d-4).
    case sourceCategories([ExploreCategoryReference])
    case opdsFeed(connectionID: String, url: String)
    /// A list bundled with the app (`PublicLibraryCollection`); sends no request.
    case gutenbergCollection(id: String)
    /// 精選書單: every bundled list, a card each (專題集合, decision 37); sends no request. A
    /// build before it reads it as `.unknown`, keeps it, and draws nothing for it.
    case gutenbergLists
    /// A Gutenberg feed; loads when the home shows (Phase 5 plan, decision 15).
    case gutenbergFeed(url: String)
    /// One of Gutenberg's shelves (`GutenbergShelf`: 熱門, 最新, a language), by id, resolved on
    /// the endpoint this build reads (5d-6a, decision 24); loads when the home shows.
    case gutenbergShelf(id: String)
    case aozoraNew
    case aozoraIndex(kind: String)
    /// 相關: same author and series from the shelf.
    case related
    /// 系列下一本 (5d-6b, decisions 24 and 25): the next numbered book of each series being
    /// read or read to the end, from the shelf and the WebDAV index (`NextInSeries`).
    case nextInSeries
    /// 訂閱的最新文章 (5g, decision 26): the newest articles of the RSS subscriptions, as the RSS
    /// tab stores them. Articles, never books: they open the article, not 作品詳情. A build
    /// before 5g reads it as `.unknown` and writes it back as it came.
    case subscriptionArticles
    /// 為你推薦 (Discovery Phase 7a): books from the home's own categories and library rows,
    /// ranked on the device (`ForYouProvider`). A build before it reads it as `.unknown` and
    /// writes it back as it came.
    case forYou
    /// One list of an installed module (Phase 6d). Its parameters are the section's own
    /// `parameters`, by the module's parameter names. A build before it reads it as `.unknown`
    /// and writes it back as it came.
    case module(moduleID: String, entryID: String)
    /// AI 推薦, the official module (AI 推薦 plan 8c): the works the reader's AI service last
    /// suggested (`AIRecommendationProvider`), generated only when the reader asks. A build
    /// before it reads it as `.unknown` and writes it back as it came.
    case aiRecommendations
    /// A binding a later build wrote, kept exactly as it was read.
    case unknown(PreservedJSON)

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

extension HomeSectionBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, categories, connectionID, url, id, kind, moduleID, entryID
    }

    private enum Kind: String {
        case myLibrary, continueReading, bookshelf, latest, sourceCategories, opdsFeed
        case gutenbergCollection, gutenbergLists, gutenbergFeed, gutenbergShelf, aozoraNew, aozoraIndex, related, nextInSeries
        case subscriptionArticles, forYou, module, aiRecommendations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            self = .unknown(try PreservedJSON(from: decoder))
            return
        }
        switch kind {
        case .myLibrary: self = .myLibrary
        case .continueReading: self = .continueReading
        case .bookshelf: self = .bookshelf
        case .latest: self = .latest
        case .sourceCategories:
            self = .sourceCategories(try container.decode([ExploreCategoryReference].self, forKey: .categories))
        case .opdsFeed:
            self = .opdsFeed(connectionID: try container.decode(String.self, forKey: .connectionID),
                             url: try container.decode(String.self, forKey: .url))
        case .gutenbergCollection: self = .gutenbergCollection(id: try container.decode(String.self, forKey: .id))
        case .gutenbergLists: self = .gutenbergLists
        case .gutenbergFeed: self = .gutenbergFeed(url: try container.decode(String.self, forKey: .url))
        case .gutenbergShelf: self = .gutenbergShelf(id: try container.decode(String.self, forKey: .id))
        case .aozoraNew: self = .aozoraNew
        case .aozoraIndex: self = .aozoraIndex(kind: try container.decode(String.self, forKey: .kind))
        case .related: self = .related
        case .nextInSeries: self = .nextInSeries
        case .subscriptionArticles: self = .subscriptionArticles
        case .forYou: self = .forYou
        case .aiRecommendations: self = .aiRecommendations
        case .module:
            self = .module(moduleID: try container.decode(String.self, forKey: .moduleID),
                           entryID: try container.decode(String.self, forKey: .entryID))
        }
    }

    func encode(to encoder: Encoder) throws {
        if case .unknown(let raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .myLibrary:
            try container.encode(Kind.myLibrary.rawValue, forKey: .type)
        case .continueReading:
            try container.encode(Kind.continueReading.rawValue, forKey: .type)
        case .bookshelf:
            try container.encode(Kind.bookshelf.rawValue, forKey: .type)
        case .latest:
            try container.encode(Kind.latest.rawValue, forKey: .type)
        case .sourceCategories(let categories):
            try container.encode(Kind.sourceCategories.rawValue, forKey: .type)
            try container.encode(categories, forKey: .categories)
        case .opdsFeed(let connectionID, let url):
            try container.encode(Kind.opdsFeed.rawValue, forKey: .type)
            try container.encode(connectionID, forKey: .connectionID)
            try container.encode(url, forKey: .url)
        case .gutenbergCollection(let id):
            try container.encode(Kind.gutenbergCollection.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
        case .gutenbergLists:
            try container.encode(Kind.gutenbergLists.rawValue, forKey: .type)
        case .gutenbergFeed(let url):
            try container.encode(Kind.gutenbergFeed.rawValue, forKey: .type)
            try container.encode(url, forKey: .url)
        case .gutenbergShelf(let id):
            try container.encode(Kind.gutenbergShelf.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
        case .aozoraNew:
            try container.encode(Kind.aozoraNew.rawValue, forKey: .type)
        case .aozoraIndex(let kind):
            try container.encode(Kind.aozoraIndex.rawValue, forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .related:
            try container.encode(Kind.related.rawValue, forKey: .type)
        case .nextInSeries:
            try container.encode(Kind.nextInSeries.rawValue, forKey: .type)
        case .subscriptionArticles:
            try container.encode(Kind.subscriptionArticles.rawValue, forKey: .type)
        case .forYou:
            try container.encode(Kind.forYou.rawValue, forKey: .type)
        case .aiRecommendations:
            try container.encode(Kind.aiRecommendations.rawValue, forKey: .type)
        case .module(let moduleID, let entryID):
            try container.encode(Kind.module.rawValue, forKey: .type)
            try container.encode(moduleID, forKey: .moduleID)
            try container.encode(entryID, forKey: .entryID)
        case .unknown:
            break
        }
    }
}

/// One section of the home.
struct HomeSection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var layout: HomeSectionLayout
    /// The title over the section; empty reads the binding's own.
    var title: String
    /// The line under the title (maintainer, 2026-10-25, after Apple Books' shelves); empty
    /// reads the binding's own, which most bindings do not have. Since schema 3.
    var subtitle: String
    var binding: HomeSectionBinding
    /// A hidden section keeps its place and settings (編輯首頁).
    var isEnabled: Bool
    /// The section's own parameter values, keyed by `SectionParameter.key` (design §13.4).
    /// Never written into a source's shared variables.
    var parameters: [String: String]

    init(id: UUID = UUID(), layout: HomeSectionLayout, title: String = "", subtitle: String = "",
         binding: HomeSectionBinding, isEnabled: Bool = true, parameters: [String: String] = [:]) {
        self.id = id
        self.layout = layout
        self.title = title
        self.subtitle = subtitle
        self.binding = binding
        self.isEnabled = isEnabled
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, layout, title, subtitle, binding, isEnabled, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        layout = try container.decode(HomeSectionLayout.self, forKey: .layout)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        binding = try container.decode(HomeSectionBinding.self, forKey: .binding)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(layout, forKey: .layout)
        try container.encode(title, forKey: .title)
        // Only one the reader wrote: a section without one is written as before schema 3.
        if !subtitle.isEmpty { try container.encode(subtitle, forKey: .subtitle) }
        try container.encode(binding, forKey: .binding)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(parameters, forKey: .parameters)
    }
}

/// One 首頁配置's sections, in the reader's order. Before 5d-4 this was the whole file; the
/// file is `HomeConfigurations` now, which keeps 預設's sections under the same key.
struct HomePage: Codable, Hashable, Sendable {
    /// `explore_home.json`'s version: 2 since 5d-4's 首頁配置, 3 since a section's `subtitle`
    /// (maintainer, 2026-10-25, knowing a build before it then shows the home without writing).
    /// A build before them reads a newer file as a newer build's: 預設's sections, without writing.
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var sections: [HomeSection]

    init(sections: [HomeSection]) {
        schemaVersion = Self.currentSchemaVersion
        self.sections = sections
    }
}

/// The sections a reader starts with (design §13.3, lines 700–704), without 我的書庫 since
/// unified library 5d-1 (settled decision 12).
///
/// Pure: nothing writes it until the home first reads it (Phase 5 plan, 5a step 3). A saved 預設
/// is the reader's and keeps the defaults it was made with, except once, for the 2026-10-25
/// layouts: a 預設 still as the defaults made it takes them (`HomeDefaultsRhythmMigration`).
enum HomePageDefaults {
    /// Whom the defaults are made for, as the home knows it: `page`'s inputs. 預設配置 makes a
    /// 首頁配置 from them (maintainer, 2026-10-23: the defaults the app keeps, not the reader's
    /// 預設, which they may have emptied).
    struct Context: Equatable, Sendable {
        let mode: ExploreMode
        let publicLibrariesAvailable: Bool
        let languages: [String]
    }

    static func page(for context: Context, makeID: () -> UUID = UUID.init) -> HomePage {
        page(mode: context.mode, publicLibrariesAvailable: context.publicLibrariesAvailable, languages: context.languages,
             makeID: makeID)
    }

    /// - Parameters:
    ///   - mode: the effective `explore.mode` (`ExploreMode.effective`); a new install is
    ///     `.publicLibraries`.
    ///   - publicLibrariesAvailable: false in China, where no public-library section is made.
    ///   - languages: the reader's languages (偏好閱讀語言, base codes, most wanted first), which
    ///     choose the official modules' lists (`officialModuleLists`).
    static func page(mode: ExploreMode, publicLibrariesAvailable: Bool, languages: [String],
                     makeID: () -> UUID = UUID.init) -> HomePage {
        // 精簡閱讀卡片 since 5d-3c (Phase 5 plan, decision 20); 大型閱讀卡片 in 5d-3.
        let continueReading = HomeSection(id: makeID(), layout: .compactReadingCard, binding: .continueReading)
        // Under 繼續閱讀 (decision 25); empty, it takes no room.
        let nextInSeries = HomeSection(id: makeID(), layout: .row, binding: .nextInSeries)
        // After 系列下一本 for everyone (Discovery Phase 7a, maintainer's decision 4); a saved
        // home gets it once (`HomePageStore`).
        let forYou = HomeSection(id: makeID(), layout: .row, binding: .forYou)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest)
        // 古騰堡熱門, Gutenberg's download ranking, before 精選 (decisions 16 and 24), ranked
        // since 2026-10-25 (`officialModuleLists` says why); a saved 預設 that still has it as a
        // plain row takes the ranks once (`HomeDefaultsRhythmMigration`).
        let popular = publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .rankedRow, binding: .gutenbergShelf(id: "popular"))]
            : []
        // 精選書單: the bundled lists, a card each, in place of a row per list (plan decision 11)
        // since 2026-10-13; 分類卡片 since 2026-10-25, as Apple Books' More to Explore lays out
        // its classics, in place of 專題集合 (decision 37); a saved 預設 that still has it as
        // 專題集合 takes 分類卡片 once (`HomeDefaultsRhythmMigration`).
        let featured = publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .categoryCards, binding: .gutenbergLists)]
            : []
        // The official modules' lists in the reader's languages (maintainer, 2026-10-21: the
        // defaults made no use of them). A new install's 預設 only: a saved 預設 is the reader's
        // and gets none added. Untitled: each is named by its list in the app's language
        // (`ModuleProvider.rowName`).
        let modules = officialModuleLists(languages: languages, publicLibrariesAvailable: publicLibrariesAvailable)
            .map { HomeSection(id: makeID(), layout: $0.layout, binding: .module(moduleID: $0.moduleID, entryID: $0.entryID)) }
        switch mode {
        case .bookSources:
            return HomePage(sections: [continueReading, nextInSeries, forYou, latest] + modules + popular + featured)
        case .publicLibraries:
            return HomePage(sections: [continueReading, nextInSeries, forYou] + modules + popular + featured + [latest])
        }
    }

    /// An official module's list on the defaults, with the layout its content suits.
    struct ModuleList: Equatable {
        let moduleID: String
        let entryID: String
        let layout: HomeSectionLayout
    }

    /// The official modules' lists for each language, in the languages' order, each list once.
    /// Chinese reads Bangumi, whose titles are Chinese; Japanese なろう, hidden where the public
    /// libraries are (`OfficialRuleModules.isAvailable`); English AniList. No other language has
    /// a list in its own language yet.
    ///
    /// The maintainer, 2026-10-25, after Apple Books' home (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`):
    /// each list in a rhythm of its own, and one band on the page. The first list with real
    /// covers is 色帶書架; a ranking with covers is a ranked row, AniList's trending manga 一大四小
    /// and its trending novels, not a ranking, a row. なろう's ranking has no covers, so it stays
    /// 圖文資訊清單 with its ranks, and never takes the band.
    ///
    /// - Parameter takesBand: which lists may take the band, as their own layout gives them; the
    ///   first with covers among them does. `HomeDefaultsRhythmMigration` keeps it off a list the
    ///   reader changed.
    static func officialModuleLists(languages: [String], publicLibrariesAvailable: Bool,
                                    takesBand: (ModuleList) -> Bool = { _ in true }) -> [ModuleList] {
        var lists: [(list: ModuleList, hasCovers: Bool)] = []
        for language in languages {
            let wanted: [(list: ModuleList, hasCovers: Bool)]
            switch ReadingLanguage.base(of: language) {
            case "zh":
                wanted = [(ModuleList(moduleID: "bangumi", entryID: "novel-rank", layout: .rankedRow), true),
                          (ModuleList(moduleID: "bangumi", entryID: "manga-rank", layout: .rankedRow), true)]
            case "ja":
                wanted = OfficialRuleModules.isAvailable("narou", librariesAvailable: publicLibrariesAvailable)
                    ? [(ModuleList(moduleID: "narou", entryID: "weekly", layout: .rankedList), false)]
                    : []
            case "en":
                wanted = [(ModuleList(moduleID: "anilist", entryID: "trending-novels", layout: .row), true),
                          (ModuleList(moduleID: "anilist", entryID: "trending-manga", layout: .heroGrid), true)]
            default:
                wanted = []
            }
            for item in wanted where !lists.contains(where: { $0.list == item.list }) { lists.append(item) }
        }
        var chosen = lists.map(\.list)
        if let first = lists.firstIndex(where: { $0.hasCovers && takesBand($0.list) }) {
            chosen[first] = ModuleList(moduleID: chosen[first].moduleID, entryID: chosen[first].entryID, layout: .band)
        }
        return chosen
    }
}

/// Any JSON value, kept so a binding this build does not know is written back as it came.
/// Numbers are kept as the decoder gives them: whole numbers as `Int64`, others as `Double`.
indirect enum PreservedJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([PreservedJSON])
    case object([String: PreservedJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PreservedJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PreservedJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
