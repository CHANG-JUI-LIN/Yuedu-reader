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

    /// The custom-page layout this is, if it is one.
    var componentKind: CustomExploreComponent.Kind? { .init(rawValue: rawValue) }

    var isKnown: Bool {
        componentKind != nil || [.tiles, .row, .readingCard, .compactReadingCard, .multiRow, .coverGrid, .list, .rankedList].contains(self)
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
    /// 最新: one row per source that has a 最新 (plan decision 10), except those 聚合設定's
    /// 顯示在最新 turns off (5d-3f, decision 21). Until 5d-3f the section kept its own
    /// `excluded` list; `HomePageStore.legacyLatestExcluded` reads it for the move.
    case latest
    /// Categories of one book source: 加入首頁配置's, and a custom page's block moved in (5d-4).
    case sourceCategories([ExploreCategoryReference])
    case opdsFeed(connectionID: String, url: String)
    /// A list bundled with the app (`PublicLibraryCollection`); sends no request.
    case gutenbergCollection(id: String)
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
    /// A binding a later build wrote, kept exactly as it was read.
    case unknown(PreservedJSON)

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

extension HomeSectionBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, categories, connectionID, url, id, kind
    }

    private enum Kind: String {
        case myLibrary, continueReading, latest, sourceCategories, opdsFeed
        case gutenbergCollection, gutenbergFeed, gutenbergShelf, aozoraNew, aozoraIndex, related, nextInSeries
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
        case .latest: self = .latest
        case .sourceCategories:
            self = .sourceCategories(try container.decode([ExploreCategoryReference].self, forKey: .categories))
        case .opdsFeed:
            self = .opdsFeed(connectionID: try container.decode(String.self, forKey: .connectionID),
                             url: try container.decode(String.self, forKey: .url))
        case .gutenbergCollection: self = .gutenbergCollection(id: try container.decode(String.self, forKey: .id))
        case .gutenbergFeed: self = .gutenbergFeed(url: try container.decode(String.self, forKey: .url))
        case .gutenbergShelf: self = .gutenbergShelf(id: try container.decode(String.self, forKey: .id))
        case .aozoraNew: self = .aozoraNew
        case .aozoraIndex: self = .aozoraIndex(kind: try container.decode(String.self, forKey: .kind))
        case .related: self = .related
        case .nextInSeries: self = .nextInSeries
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
    var binding: HomeSectionBinding
    /// A hidden section keeps its place and settings (編輯首頁).
    var isEnabled: Bool
    /// The section's own parameter values, keyed by `SectionParameter.key` (design §13.4).
    /// Never written into a source's shared variables.
    var parameters: [String: String]

    init(id: UUID = UUID(), layout: HomeSectionLayout, title: String = "", binding: HomeSectionBinding,
         isEnabled: Bool = true, parameters: [String: String] = [:]) {
        self.id = id
        self.layout = layout
        self.title = title
        self.binding = binding
        self.isEnabled = isEnabled
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, layout, title, binding, isEnabled, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        layout = try container.decode(HomeSectionLayout.self, forKey: .layout)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        binding = try container.decode(HomeSectionBinding.self, forKey: .binding)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
    }
}

/// One 首頁配置's sections, in the reader's order. Before 5d-4 this was the whole file; the
/// file is `HomeConfigurations` now, which keeps 預設's sections under the same key.
struct HomePage: Codable, Hashable, Sendable {
    /// `explore_home.json`'s version: 2 since 5d-4's 首頁配置. A build before them reads a file
    /// of 2 as a newer build's: 預設's sections, without writing.
    static let currentSchemaVersion = 2

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
/// Pure: nothing calls it at launch and nothing writes it until the home first reads it
/// (Phase 5 plan, 5a step 3), so the defaults can still change without a second migration.
enum HomePageDefaults {
    /// - Parameters:
    ///   - mode: the effective `explore.mode` (`ExploreMode.effective`); a new install is
    ///     `.publicLibraries`.
    ///   - publicLibrariesAvailable: false in China, where no public-library section is made.
    static func page(mode: ExploreMode, publicLibrariesAvailable: Bool,
                     makeID: () -> UUID = UUID.init) -> HomePage {
        // 精簡閱讀卡片 since 5d-3c (Phase 5 plan, decision 20); 大型閱讀卡片 in 5d-3.
        let continueReading = HomeSection(id: makeID(), layout: .compactReadingCard, binding: .continueReading)
        // Under 繼續閱讀 (decision 25); empty, it takes no room.
        let nextInSeries = HomeSection(id: makeID(), layout: .row, binding: .nextInSeries)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest)
        // 古騰堡熱門, Gutenberg's download ranking, before 精選 (decisions 16 and 24). A new
        // install's 預設 only: a saved 預設 is the reader's and is not changed.
        let popular = publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .row, binding: .gutenbergShelf(id: "popular"))]
            : []
        // 精選: one section per bundled list, titled by the list (plan decision 11).
        let featured = publicLibrariesAvailable
            ? PublicLibraryCollection.all.map {
                HomeSection(id: makeID(), layout: .row, binding: .gutenbergCollection(id: $0.id))
            }
            : []
        switch mode {
        case .bookSources:
            return HomePage(sections: [continueReading, nextInSeries, latest] + popular + featured)
        case .publicLibraries:
            return HomePage(sections: [continueReading, nextInSeries] + popular + featured + [latest])
        }
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
