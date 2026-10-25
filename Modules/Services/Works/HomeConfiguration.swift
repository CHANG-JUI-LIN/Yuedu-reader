import Foundation

// Unified library 5d-4: 首頁配置 (Phase 5 plan, decisions 12 and 22). The home is one of
// several configurations, switched on 首頁配置's page:
// - 預設 is the home the reader had before 5d-4, edited since 5d-2 (decision 22), saved as the
//   file's top-level `sections`, where a build older than 5d-4 still finds it. It moves among
//   the reader's own (`defaultsIndex`), and is deleted like them (maintainer, 2026-10-25):
//   預設配置 makes the defaults again, as one of the reader's own (`defaultsDeleted`).
// - The last configuration left is never deleted: the home would have nothing to show.
// - The reader's own: made from a template (`HomeConfigurationTemplate`), or migrated from a
//   custom page (`custom_explore_pages.json`), which keeps its id.
// - 空白 was built in until 2026-10-23, when the maintainer took it away (`retireBlank`).
// Every configuration is edited the same way (編輯首頁, a section name's long press,
// 聚合設定's 首頁欄目); those edits act on the selected one.

/// Which configuration: 預設 or one of the reader's own. A string, so a built-in this build
/// does not know is still kept by id.
struct HomeConfigurationID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ id: UUID) { rawValue = id.uuidString }

    static let defaults = Self(rawValue: "default")
    /// The built-in 空白 until 2026-10-23: read from older files only (`retireBlank`).
    static let blank = Self(rawValue: "blank")

    var isBuiltIn: Bool { self == .defaults }
}

/// One configuration other than 預設: its name and sections.
struct HomeConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: HomeConfigurationID
    /// The reader's name for it; empty for a built-in, which is named in the reader's language.
    var name: String
    var sections: [HomeSection]

    init(id: HomeConfigurationID, name: String = "", sections: [HomeSection] = []) {
        self.id = id
        self.name = name
        self.sections = sections
    }
}

/// Where a new 首頁配置 starts, from 從設定範本新增: 空白模板 with no section, 預設配置 with the
/// defaults the app keeps (`HomePageDefaults`), not with the reader's 預設 (maintainer,
/// 2026-10-23).
enum HomeConfigurationTemplate: String, Sendable {
    case blank
    case defaults = "default"
}

/// What 首頁配置's page lists: a configuration's id and name.
struct HomeConfigurationListing: Identifiable, Hashable, Sendable {
    let id: HomeConfigurationID
    let name: String
}

/// `explore_home.json` since 5d-4 (schema 2).
struct HomeConfigurations: Codable, Hashable, Sendable {
    /// 預設's sections. Top level, under the key a build older than 5d-4 reads.
    var sections: [HomeSection]
    /// The reader's own, in the order 首頁配置's page lists them.
    var configurations: [HomeConfiguration]
    /// Nil is 預設.
    var selected: HomeConfigurationID?
    /// Where 預設 sits among the reader's own on 首頁配置's page; nil is first. A build older
    /// than 2026-10-23 lists it first all the same.
    var defaultsIndex: Int?
    /// Whether the reader deleted 預設 (2026-10-25); `sections` is then empty. A build older than
    /// that lists an empty 預設, but opens `selected`, which is always set once 預設 is gone.
    var defaultsDeleted: Bool
    /// Set while `custom_explore_pages.json` could not be read: the pages move in on a later
    /// launch that reads it.
    var customPagesPending: Bool

    init(sections: [HomeSection], configurations: [HomeConfiguration] = [], selected: HomeConfigurationID? = nil,
         defaultsIndex: Int? = nil, defaultsDeleted: Bool = false, customPagesPending: Bool = false) {
        self.sections = sections
        self.configurations = configurations
        self.selected = selected
        self.defaultsIndex = defaultsIndex
        self.defaultsDeleted = defaultsDeleted
        self.customPagesPending = customPagesPending
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, configurations, selected, defaultsIndex, defaultsDeleted, customPagesPending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decode([HomeSection].self, forKey: .sections)
        configurations = try container.decodeIfPresent([HomeConfiguration].self, forKey: .configurations) ?? []
        selected = try container.decodeIfPresent(HomeConfigurationID.self, forKey: .selected)
        defaultsIndex = try container.decodeIfPresent(Int.self, forKey: .defaultsIndex)
        defaultsDeleted = try container.decodeIfPresent(Bool.self, forKey: .defaultsDeleted) ?? false
        customPagesPending = try container.decodeIfPresent(Bool.self, forKey: .customPagesPending) ?? false
        retireBlank()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HomePage.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sections, forKey: .sections)
        try container.encode(configurations, forKey: .configurations)
        try container.encodeIfPresent(selected, forKey: .selected)
        try container.encodeIfPresent(defaultsIndex, forKey: .defaultsIndex)
        if defaultsDeleted { try container.encode(true, forKey: .defaultsDeleted) }
        if customPagesPending { try container.encode(true, forKey: .customPagesPending) }
    }

    /// 空白 is no longer built in (maintainer, 2026-10-23). One the reader filled stays, as
    /// their own 空白; an empty one goes, and 預設 (or, once it is deleted, the first) is shown in
    /// its place.
    mutating func retireBlank() {
        if let index = configurations.firstIndex(where: { $0.id == .blank }) {
            if configurations[index].sections.isEmpty {
                configurations.remove(at: index)
            } else if configurations[index].name.isEmpty {
                configurations[index].name = localized("空白")
            }
        }
        if selected == .blank, !configurations.contains(where: { $0.id == .blank }) { selected = replacement }
    }

    /// What is shown when the selected one goes: 預設, else the first left.
    private var replacement: HomeConfigurationID? {
        defaultsDeleted ? listings.first?.id : nil
    }

    // MARK: Reading

    /// The selected configuration's id; one that is gone reads as 預設, or once 預設 is deleted,
    /// as the first.
    var selectedID: HomeConfigurationID {
        guard let selected, configurations.contains(where: { $0.id == selected }) else {
            return replacement ?? .defaults
        }
        return selected
    }

    func sections(of id: HomeConfigurationID) -> [HomeSection] {
        if id == .defaults { return sections }
        return configurations.first { $0.id == id }?.sections ?? []
    }

    /// The reader's own in their order, with 預設 where it was moved to unless it was deleted.
    var listings: [HomeConfigurationListing] {
        var listed = configurations.filter { !$0.id.isBuiltIn }.map { HomeConfigurationListing(id: $0.id, name: $0.name) }
        guard !defaultsDeleted else { return listed }
        listed.insert(HomeConfigurationListing(id: .defaults, name: localized("預設")),
                      at: min(max(defaultsIndex ?? 0, 0), listed.count))
        return listed
    }

    // MARK: Changing

    mutating func setSections(_ newSections: [HomeSection], of id: HomeConfigurationID) {
        if id == .defaults {
            sections = newSections
        } else if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].sections = newSections
        }
    }

    /// 新增首頁配置: `newSections` (its template's), named as the reader typed it, a blank name
    /// becoming 首頁配置 and a taken one numbered. It goes last and becomes the selected one.
    mutating func create(named name: String, sections newSections: [HomeSection],
                         makeID: () -> UUID = UUID.init) -> HomeConfigurationID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = HomeConfigurationID(makeID())
        configurations.append(HomeConfiguration(id: id, name: uniqueName(trimmed.isEmpty ? localized("首頁配置") : trimmed),
                                                sections: newSections))
        selected = id
        return id
    }

    /// A blank name, or a built-in, is left as it was.
    mutating func rename(_ id: HomeConfigurationID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isBuiltIn, let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].name = trimmed
    }

    /// 首頁配置's 編輯: the list in a new order, 預設 among the reader's own (maintainer,
    /// 2026-10-23); `offsets` and `destination` count `listings`.
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let listed = listings.map(\.id)
        let valid = offsets.filteredIndexSet { listed.indices.contains($0) }
        guard !valid.isEmpty, (0...listed.count).contains(destination) else { return }
        // `List`'s onMove: the destination is counted before the moved ones are taken out.
        var order = listed.indices.filter { !valid.contains($0) }.map { listed[$0] }
        order.insert(contentsOf: valid.map { listed[$0] }, at: destination - valid.count(in: 0..<destination))
        let own = Dictionary(configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        configurations = order.compactMap { own[$0] }
        defaultsIndex = order.firstIndex(of: .defaults).flatMap { $0 == 0 ? nil : $0 }
    }

    /// Any but the last one left. One of the reader's own: 預設 keeps its place in the list. 預設:
    /// its sections go, and it is listed no more. The one deleted, if selected, gives way to 預設,
    /// else to the first left.
    mutating func delete(_ id: HomeConfigurationID) {
        let listed = listings
        guard listed.count > 1, let position = listed.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        if id == .defaults {
            defaultsDeleted = true
            sections = []
            defaultsIndex = nil
        } else {
            if let index = defaultsIndex, position < index { defaultsIndex = index - 1 == 0 ? nil : index - 1 }
            configurations.removeAll { $0.id == id }
        }
        if wasSelected { selected = replacement }
    }

    /// 加入首頁配置 on a source's category: a 橫向單排書架 of it at the end.
    mutating func addCategory(_ reference: ExploreCategoryReference, to id: HomeConfigurationID) {
        setSections(sections(of: id) + [HomeSection(layout: .row, binding: .sourceCategories([reference]))], of: id)
    }

    func contains(_ reference: ExploreCategoryReference, in id: HomeConfigurationID) -> Bool {
        sections(of: id).contains { section in
            if case .sourceCategories(let references) = section.binding { return references.contains(reference) }
            return false
        }
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(configurations.map(\.name) + [localized("預設")])
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

// MARK: - Custom pages

extension HomeConfigurations {
    /// The custom pages as configurations, each under its page's id, appended after the ones
    /// there are. A page already there (moved in by an earlier launch) is not added again.
    mutating func adopt(_ pages: [CustomExplorePage]) {
        for page in pages where !configurations.contains(where: { $0.id == HomeConfigurationID(page.id) }) {
            configurations.append(HomeConfiguration(id: HomeConfigurationID(page.id), name: page.name,
                                                    sections: page.components.flatMap { HomeSection.migrating($0, page: page.name) }))
        }
    }
}

extension HomeSection {
    /// A custom-page block in the layouts of decision 14: 左右滑動 and 推薦卡片 → 橫向單排書架;
    /// 宮格 → 多行橫向輪播; 排行榜 and 網絡排行榜 → 圖文資訊清單 with ranks; 多分類排行榜 → one
    /// ranked 圖文資訊清單 per category, each titled by its category; 錯位瀑布流 → 固定封面網格,
    /// which does not keep loading as the page scrolls. A block without enough categories, or
    /// of several sources, has nothing the home can draw and is left out, in the log.
    static func migrating(_ component: CustomExploreComponent, page: String) -> [HomeSection] {
        guard component.isComplete else {
            AppLogger.cache("⟐ custom page block left out: too few categories, or several sources", context: [
                "page": page, "kind": component.kind.rawValue, "categories": "\(component.categories.count)",
            ])
            return []
        }
        let layout: HomeSectionLayout = switch component.kind {
        case .featuredCards, .carousel: .row
        case .grid: .multiRow
        case .ranking, .pagedRanking, .multiCategoryRanking: .rankedList
        case .waterfall: .coverGrid
        }
        if component.kind.takesSeveralCategories {
            return component.categories.map { HomeSection(layout: layout, binding: .sourceCategories([$0])) }
        }
        return [HomeSection(id: component.id, layout: layout, title: component.title,
                            binding: .sourceCategories(component.categories))]
    }
}
