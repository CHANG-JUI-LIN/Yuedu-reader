import Foundation

// Unified library 5d-4: 首頁配置 (Phase 5 plan, decisions 12 and 22). The home is one of
// several configurations, switched from 範圍:
// - 預設 is the home the reader had before 5d-4, edited since 5d-2 (decision 22), saved as the
//   file's top-level `sections`, where a build older than 5d-4 still finds it.
// - 空白 starts with no section.
// - The reader's own: made from 新增首頁配置, starting from 預設 or 空白, or migrated from a
//   custom page (`custom_explore_pages.json`), which keeps its id.
// Every configuration is edited the same way (編輯首頁, a section name's long press,
// 聚合設定's 首頁欄目); those edits act on the selected one.

/// Which configuration: 預設, 空白 or one of the reader's own. A string, so a built-in this
/// build does not know is still kept by id.
struct HomeConfigurationID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ id: UUID) { rawValue = id.uuidString }

    static let defaults = Self(rawValue: "default")
    static let blank = Self(rawValue: "blank")

    var isBuiltIn: Bool { self == .defaults || self == .blank }
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

/// What 範圍 lists: a configuration's id and name.
struct HomeConfigurationListing: Identifiable, Hashable, Sendable {
    let id: HomeConfigurationID
    let name: String
}

/// `explore_home.json` since 5d-4 (schema 2).
struct HomeConfigurations: Codable, Hashable, Sendable {
    /// 預設's sections. Top level, under the key a build older than 5d-4 reads.
    var sections: [HomeSection]
    /// 空白 once it has been saved, and the reader's own, in the order they were made.
    var configurations: [HomeConfiguration]
    /// Nil is 預設.
    var selected: HomeConfigurationID?
    /// Set while `custom_explore_pages.json` could not be read: the pages move in on a later
    /// launch that reads it.
    var customPagesPending: Bool

    init(sections: [HomeSection], configurations: [HomeConfiguration] = [], selected: HomeConfigurationID? = nil,
         customPagesPending: Bool = false) {
        self.sections = sections
        self.configurations = configurations
        self.selected = selected
        self.customPagesPending = customPagesPending
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, configurations, selected, customPagesPending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decode([HomeSection].self, forKey: .sections)
        configurations = try container.decodeIfPresent([HomeConfiguration].self, forKey: .configurations) ?? []
        selected = try container.decodeIfPresent(HomeConfigurationID.self, forKey: .selected)
        customPagesPending = try container.decodeIfPresent(Bool.self, forKey: .customPagesPending) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HomePage.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sections, forKey: .sections)
        try container.encode(configurations, forKey: .configurations)
        try container.encodeIfPresent(selected, forKey: .selected)
        if customPagesPending { try container.encode(true, forKey: .customPagesPending) }
    }

    // MARK: Reading

    /// The selected configuration's id; one that is gone reads as 預設.
    var selectedID: HomeConfigurationID {
        guard let selected, selected == .blank || configurations.contains(where: { $0.id == selected }) else {
            return .defaults
        }
        return selected
    }

    func sections(of id: HomeConfigurationID) -> [HomeSection] {
        if id == .defaults { return sections }
        return configurations.first { $0.id == id }?.sections ?? []
    }

    /// 預設, 空白, then the reader's own in the order they were made.
    var listings: [HomeConfigurationListing] {
        [HomeConfigurationListing(id: .defaults, name: localized("預設")),
         HomeConfigurationListing(id: .blank, name: localized("空白"))]
            + configurations.filter { !$0.id.isBuiltIn }.map { HomeConfigurationListing(id: $0.id, name: $0.name) }
    }

    // MARK: Changing

    mutating func setSections(_ newSections: [HomeSection], of id: HomeConfigurationID) {
        if id == .defaults {
            sections = newSections
        } else if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].sections = newSections
        } else if id == .blank {
            configurations.insert(HomeConfiguration(id: .blank, sections: newSections), at: 0)
        }
    }

    /// 新增首頁配置: a configuration starting from 預設's sections (each under a new id, so
    /// the two never share a row) or from none, named as the reader typed it, a blank name
    /// becoming 首頁配置 and a taken one numbered. It becomes the selected one.
    mutating func create(named name: String, from start: HomeConfigurationID, makeID: () -> UUID = UUID.init) -> HomeConfigurationID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let copied = start == .defaults
            ? sections.map { section -> HomeSection in
                var copy = section
                copy.id = makeID()
                return copy
            }
            : []
        let id = HomeConfigurationID(makeID())
        configurations.append(HomeConfiguration(id: id, name: uniqueName(trimmed.isEmpty ? localized("首頁配置") : trimmed),
                                                sections: copied))
        selected = id
        return id
    }

    /// A blank name, or a built-in, is left as it was.
    mutating func rename(_ id: HomeConfigurationID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isBuiltIn, let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].name = trimmed
    }

    /// The reader's own only; 預設 is selected in its place.
    mutating func delete(_ id: HomeConfigurationID) {
        guard !id.isBuiltIn else { return }
        configurations.removeAll { $0.id == id }
        if selected == id { selected = nil }
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
        let taken = Set(configurations.map(\.name) + [localized("預設"), localized("空白")])
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
