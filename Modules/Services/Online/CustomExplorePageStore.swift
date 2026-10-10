import Combine
import Foundation

// MARK: - A category of a source

/// One explore category of one source, addressed the way Legado addresses it: by the
/// source's URL plus the category's title and URL. Stable across launches and across
/// a source being re-imported (which mints a new id but keeps its URL).
struct ExploreCategoryReference: Codable, Hashable, Identifiable, Sendable {
    let sourceURL: String
    let title: String
    let url: String

    var id: String { "\(sourceURL)\u{1F}\(title)\u{1F}\(url)" }

    init(sourceURL: String, title: String, url: String) {
        self.sourceURL = sourceURL
        self.title = title
        self.url = url
    }

    init?(source: BookSource, item: DiscoverCardItem) {
        guard item.isFetchable, let url = item.raw.url else { return nil }
        self.init(sourceURL: source.bookSourceUrl, title: item.title, url: url)
    }

    var source: BookSource? {
        BookSourceStore.shared.sources.first { $0.bookSourceUrl == sourceURL }
    }

    /// The category as the discover pipeline consumes it.
    var cardItem: DiscoverCardItem? {
        DiscoverViewModel.mapItem(ModernParserBridge.DiscoverItem(title: title, url: url))
    }
}

// MARK: - Custom explore pages

/// One block of a custom explore page: a layout, the category it shows — several, for
/// 多分類排行榜 — and the title over it.
struct CustomExploreComponent: Codable, Hashable, Identifiable, Sendable {
    /// The layouts a block can take.
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
        /// 錯位瀑布流: cards in staggered columns that keep loading as the page scrolls —
        /// one to a page, and always last, since nothing below it would ever show.
        case waterfall

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .featuredCards: "推薦卡片"
            case .ranking: "排行榜"
            case .grid: "宮格"
            case .carousel: "左右滑動"
            case .pagedRanking: "網絡排行榜"
            case .multiCategoryRanking: "多分類排行榜"
            case .waterfall: "錯位瀑布流"
            }
        }

        var descriptionKey: String {
            switch self {
            case .featuredCards: "一排封面，附書名和簡介"
            case .ranking: "前五名的列表，可展開到前十名"
            case .grid: "兩排、每排五本的封面"
            case .carousel: "只有封面，左右滑動"
            case .pagedRanking: "一個榜單分成每欄四本，左右翻頁"
            case .multiCategoryRanking: "同一來源配置的幾個分類，用標籤切換"
            case .waterfall: "三欄卡片，往下捲會一直載入"
            }
        }

        var systemImage: String {
            switch self {
            case .featuredCards: "rectangle.on.rectangle"
            case .ranking: "list.number"
            case .grid: "square.grid.3x2"
            case .carousel: "arrow.left.and.right"
            case .pagedRanking: "chart.bar.doc.horizontal"
            case .multiCategoryRanking: "square.stack.3d.up"
            case .waterfall: "rectangle.3.group"
            }
        }

        /// The fewest categories the block takes.
        var minimumCategoryCount: Int { self == .multiCategoryRanking ? 2 : 1 }

        var takesSeveralCategories: Bool { self == .multiCategoryRanking }
    }

    var id: UUID
    var kind: Kind
    /// The title over the block; empty reads the category's own. 多分類排行榜 has none:
    /// its tabs name its categories.
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

    /// What the block's header reads.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (categories.first?.title ?? "") : trimmed
    }

    var sourceURL: String? { categories.first?.sourceURL }
}

/// A page of blocks put together from any sources' categories, named by the reader and
/// opened from its tile on 探索.
struct CustomExplorePage: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var components: [CustomExploreComponent]

    init(id: UUID = UUID(), name: String, components: [CustomExploreComponent] = []) {
        self.id = id
        self.name = name
        self.components = components
    }

    var hasWaterfall: Bool { components.contains { $0.kind == .waterfall } }

    /// `components` with `component` saved into it: in its own place when it is there
    /// already, else at the end — before the waterfall, which stays last. A second
    /// waterfall is not added.
    static func saving(
        _ component: CustomExploreComponent,
        into components: [CustomExploreComponent]
    ) -> [CustomExploreComponent] {
        var result = components
        if let index = result.firstIndex(where: { $0.id == component.id }) {
            result[index] = component
        } else if component.kind == .waterfall {
            guard !result.contains(where: { $0.kind == .waterfall }) else { return result }
            result.append(component)
        } else if let waterfall = result.firstIndex(where: { $0.kind == .waterfall }) {
            result.insert(component, at: waterfall)
        } else {
            result.append(component)
        }
        return waterfallLast(result)
    }

    /// `components` after a `List` move — `destination` is an offset in the list before
    /// the move — with the waterfall put back at the end.
    static func moving(
        _ components: [CustomExploreComponent],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [CustomExploreComponent] {
        let moving = source.compactMap { components.indices.contains($0) ? components[$0] : nil }
        var remaining = components.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        return waterfallLast(remaining)
    }

    private static func waterfallLast(_ components: [CustomExploreComponent]) -> [CustomExploreComponent] {
        components.filter { $0.kind != .waterfall } + components.filter { $0.kind == .waterfall }
    }
}

/// The reader's custom explore pages. Kept on this device, as the explore settings are.
@MainActor
final class CustomExplorePageStore: ObservableObject {
    static let shared = CustomExplorePageStore()

    @Published private(set) var pages: [CustomExplorePage] = []

    private let fileURL: URL

    init(fileURL: URL = StorageLocations.applicationSupportRoot.appendingPathComponent("custom_explore_pages.json")) {
        self.fileURL = fileURL
        load()
    }

    func page(id: UUID) -> CustomExplorePage? {
        pages.first { $0.id == id }
    }

    /// A new, empty page. A name left blank becomes 自訂頁, and a name already taken
    /// gets a number after it, as a new theme's does.
    @discardableResult
    func createPage(named name: String) -> CustomExplorePage {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = CustomExplorePage(name: uniqueName(base: trimmed.isEmpty ? localized("自訂頁") : trimmed))
        pages.append(page)
        save()
        return page
    }

    /// A blank name leaves the page as it was.
    func renamePage(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func deletePage(id: UUID) {
        pages.removeAll { $0.id == id }
        save()
    }

    /// Adds the block, or replaces the one with its id.
    func saveComponent(_ component: CustomExploreComponent, inPage pageID: UUID) {
        update(pageID) { $0.components = CustomExplorePage.saving(component, into: $0.components) }
    }

    func removeComponents(atOffsets offsets: IndexSet, inPage pageID: UUID) {
        update(pageID) { page in
            page.components = page.components.enumerated()
                .filter { !offsets.contains($0.offset) }
                .map(\.element)
        }
    }

    /// `List`'s `onMove` contract: `destination` is an offset in the list before the move.
    func moveComponents(fromOffsets source: IndexSet, toOffset destination: Int, inPage pageID: UUID) {
        update(pageID) { $0.components = CustomExplorePage.moving($0.components, fromOffsets: source, toOffset: destination) }
    }

    /// 加入自訂頁 on a category: a 推薦卡片 block of it at the end of the page.
    func addCategory(_ reference: ExploreCategoryReference, toPage pageID: UUID) {
        saveComponent(CustomExploreComponent(kind: .featuredCards, categories: [reference]), inPage: pageID)
    }

    /// Whether any block of the page shows the category.
    func page(_ pageID: UUID, contains reference: ExploreCategoryReference) -> Bool {
        page(id: pageID)?.components.contains { $0.categories.contains(reference) } ?? false
    }

    private func update(_ pageID: UUID, _ change: (inout CustomExplorePage) -> Void) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        change(&pages[index])
        save()
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(pages.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            pages = try JSONDecoder().decode([CustomExplorePage].self, from: data)
        } catch {
            AppLogger.cache("⟐ custom explore pages could not be read", error: error)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pages)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.cache("⟐ custom explore pages could not be saved", error: error)
        }
    }
}
