import Foundation

// Unified library 5d-4: the custom pages, read once to become 首頁配置 (Phase 5 plan,
// decisions 12 and 22). Nothing writes `custom_explore_pages.json` any more; the file stays
// where it is, for a build older than 5d-4. A page such a build adds afterwards does not
// move in.

/// One block of a custom explore page: a layout, the category it shows — several, for
/// 多分類排行榜 — and the title over it.
struct CustomExploreComponent: Codable, Hashable, Identifiable, Sendable {
    /// The layouts a block could take. `HomeSection.migrating` maps each onto the home's.
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 推薦卡片: a row of covers, each with its title and intro.
        case featuredCards
        /// 排行榜: the top five as a list, 顯示全部 for the top ten.
        case ranking
        /// 宮格: two rows of five covers.
        case grid
        /// 左右滑動: covers alone, in a row that swipes sideways.
        case carousel
        /// 網絡排行榜: one ranking in columns of four, paged sideways.
        case pagedRanking
        /// 多分類排行榜: rankings of one source behind tabs, each paged sideways.
        case multiCategoryRanking
        /// 錯位瀑布流: cards in staggered columns that kept loading as the page scrolled.
        case waterfall

        var id: String { rawValue }

        /// The fewest categories the block takes.
        var minimumCategoryCount: Int { self == .multiCategoryRanking ? 2 : 1 }

        var takesSeveralCategories: Bool { self == .multiCategoryRanking }
    }

    var id: UUID
    var kind: Kind
    /// The title over the block; empty read the category's own.
    var title: String
    /// The categories the block shows, all from one source.
    var categories: [ExploreCategoryReference]

    init(id: UUID = UUID(), kind: Kind, title: String = "", categories: [ExploreCategoryReference]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.categories = categories
    }

    /// Enough categories for its kind, all of one source.
    var isComplete: Bool {
        categories.count >= kind.minimumCategoryCount
            && Set(categories.map(\.sourceURL)).count == 1
    }
}

/// A page of blocks put together from any sources' categories, named by the reader.
struct CustomExplorePage: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var components: [CustomExploreComponent]

    init(id: UUID = UUID(), name: String, components: [CustomExploreComponent] = []) {
        self.id = id
        self.name = name
        self.components = components
    }
}

/// `custom_explore_pages.json`, as the move into 首頁配置 finds it.
enum LegacyCustomExplorePages: Equatable, Sendable {
    /// No file: nothing to move.
    case absent
    case pages([CustomExplorePage])
    /// There is a file and it could not be read or decoded: the pages move on a later launch.
    case unreadable

    static func read(_ url: URL) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            return .pages(try JSONDecoder().decode([CustomExplorePage].self, from: Data(contentsOf: url)))
        } catch {
            AppLogger.cache("⟐ custom explore pages could not be read; they move into 首頁配置 later", error: error)
            return .unreadable
        }
    }
}

#if DEBUG
extension LegacyCustomExplorePages {
    /// `-seed-custom-explore-page`'s page, a ranking from a source this device does not have.
    static let seededPageID = UUID(uuidString: "5D4C0000-0000-4000-8000-000000000001")!
    static let seededComponentID = UUID(uuidString: "5D4C0000-0000-4000-8000-000000000002")!

    /// Writes one custom page, chosen as the old 首屏頁面, as a build before 5d-4 left them.
    /// UI tests only, after `-reset-explore-home`.
    static func seedForTesting() {
        let page = CustomExplorePage(id: seededPageID, name: "週末書單", components: [
            CustomExploreComponent(id: seededComponentID, kind: .ranking, title: "熱門榜", categories: [
                ExploreCategoryReference(sourceURL: "https://seed.test", title: "熱門", url: "/hot"),
            ]),
        ])
        let url = StorageLocations.applicationSupportRoot.appendingPathComponent("custom_explore_pages.json")
        do {
            try JSONEncoder().encode([page]).write(to: url, options: .atomic)
            UserDefaults.standard.set("page:" + seededPageID.uuidString, forKey: ExploreSettings.legacyLandingKey)
        } catch {
            AppLogger.error("Custom page seed failed: \(error)")
        }
    }
}
#endif
