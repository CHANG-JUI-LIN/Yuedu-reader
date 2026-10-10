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

    /// One tile per place (我的書庫).
    static let tiles = Self(rawValue: "tiles")
    /// One row of covers that swipes sideways.
    static let row = Self(rawValue: "row")

    /// The custom-page layout this is, if it is one.
    var componentKind: CustomExploreComponent.Kind? { .init(rawValue: rawValue) }

    var isKnown: Bool { componentKind != nil || self == .tiles || self == .row }
}

/// What a section shows (design §13.4).
enum HomeSectionBinding: Hashable, Sendable {
    /// 我的書庫: a tile for every place.
    case myLibrary
    /// 繼續閱讀, across every source.
    case continueReading
    /// 最新: one row per source that has a 最新, except the excluded ones (plan decision 10).
    case latest(excluded: [SourceInstanceKey])
    /// Categories of one book source: today's custom-page block.
    case sourceCategories([ExploreCategoryReference])
    case opdsFeed(connectionID: String, url: String)
    /// A list bundled with the app (`PublicLibraryCollection`); sends no request.
    case gutenbergCollection(id: String)
    /// A Gutenberg feed; loads only when the reader asks.
    case gutenbergFeed(url: String)
    case aozoraNew
    case aozoraIndex(kind: String)
    /// 相關: same author and series from the shelf.
    case related
    /// A binding a later build wrote, kept exactly as it was read.
    case unknown(PreservedJSON)

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

extension HomeSectionBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, excluded, categories, connectionID, url, id, kind
    }

    private enum Kind: String {
        case myLibrary, continueReading, latest, sourceCategories, opdsFeed
        case gutenbergCollection, gutenbergFeed, aozoraNew, aozoraIndex, related
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
        case .latest:
            self = .latest(excluded: try container.decodeIfPresent([SourceInstanceKey].self, forKey: .excluded) ?? [])
        case .sourceCategories:
            self = .sourceCategories(try container.decode([ExploreCategoryReference].self, forKey: .categories))
        case .opdsFeed:
            self = .opdsFeed(connectionID: try container.decode(String.self, forKey: .connectionID),
                             url: try container.decode(String.self, forKey: .url))
        case .gutenbergCollection: self = .gutenbergCollection(id: try container.decode(String.self, forKey: .id))
        case .gutenbergFeed: self = .gutenbergFeed(url: try container.decode(String.self, forKey: .url))
        case .aozoraNew: self = .aozoraNew
        case .aozoraIndex: self = .aozoraIndex(kind: try container.decode(String.self, forKey: .kind))
        case .related: self = .related
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
        case .latest(let excluded):
            try container.encode(Kind.latest.rawValue, forKey: .type)
            try container.encode(excluded, forKey: .excluded)
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
        case .aozoraNew:
            try container.encode(Kind.aozoraNew.rawValue, forKey: .type)
        case .aozoraIndex(let kind):
            try container.encode(Kind.aozoraIndex.rawValue, forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .related:
            try container.encode(Kind.related.rawValue, forKey: .type)
        case .unknown:
            break
        }
    }
}

/// One section of the home, or one block of a custom page read as a section.
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

    /// A custom-page block, which stays stored in its own format (plan decision 2).
    init(component: CustomExploreComponent) {
        self.init(id: component.id, layout: HomeSectionLayout(component.kind), title: component.title,
                  binding: .sourceCategories(component.categories))
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

/// The home: its sections, in the reader's order.
struct HomePage: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sections: [HomeSection]

    init(sections: [HomeSection]) {
        schemaVersion = Self.currentSchemaVersion
        self.sections = sections
    }
}

/// The sections a reader starts with (design §13.3, lines 700–704).
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
        let myLibrary = HomeSection(id: makeID(), layout: .tiles, binding: .myLibrary)
        let continueReading = HomeSection(id: makeID(), layout: .row, binding: .continueReading)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest(excluded: []))
        // 精選: one section per bundled list, titled by the list (plan decision 11).
        let featured = publicLibrariesAvailable
            ? PublicLibraryCollection.all.map {
                HomeSection(id: makeID(), layout: .row, binding: .gutenbergCollection(id: $0.id))
            }
            : []
        switch mode {
        case .bookSources:
            return HomePage(sections: [myLibrary, continueReading, latest] + featured)
        case .publicLibraries:
            return HomePage(sections: [continueReading, myLibrary] + featured + [latest])
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
