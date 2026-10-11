import Combine
import Foundation

/// Unified library 5d-5: a book source's discover categories as 選擇內容來源 lists them
/// (Phase 5 plan, decision 23), grouped as 發現頁設定 groups them
/// (`DiscoverViewModel.categoryGroups`), with the source's own filters.
///
/// It reads the source's explore rule through `BookSourceFetcher.discoverItems`, the one path
/// the source's own page reads it by. It keeps no cache: listing is the reader's tap, and a
/// list cached under the page's filters would be the wrong one here.
///
/// The filters are the section's (decision 23): a choice here is read by the explore rule in
/// place of the source's stored value (`LegadoSourceBridge.withVariableOverlay`) and is never
/// stored, so the source's own discover page and every other section keep theirs. Unlike
/// `DiscoverViewModel.selectFilter` it writes nothing: no shared variable, no per-類型 memory.
@MainActor
final class SourceCategoryListing: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        /// The source returned no category.
        case empty
    }

    let source: BookSource
    @Published private(set) var state: State = .loading
    @Published private(set) var groups: [DiscoverCategoryGroup] = []
    /// The source's filters as it drew them under `overlay`: each one's `selected` is the value
    /// the source read.
    @Published private(set) var filters: [DiscoverFilter] = []
    /// The values the explore rule reads in place of the stored ones.
    private(set) var overlay: [String: String]
    private let loadItems: (BookSource, [String: String]) async -> [ModernParserBridge.DiscoverItem]
    private let storedVariables: (BookSource) -> [String: Any]
    /// The latest load; an earlier one finishing after it is dropped.
    private var generation = 0

    /// - Parameter filterValues: the section's own values, from when it picked its category.
    init(source: BookSource,
         filterValues: [String: String] = [:],
         loadItems: @escaping (BookSource, [String: String]) async -> [ModernParserBridge.DiscoverItem] = {
             await BookSourceFetcher.shared.discoverItems(page: 1, in: $0, variableOverlay: $1)
         },
         storedVariables: @escaping (BookSource) -> [String: Any] = {
             BookSourceRuntimeStateStore.shared.sourceVariables(for: $0.bookSourceUrl)
         }) {
        self.source = source
        self.overlay = filterValues
        self.loadItems = loadItems
        self.storedVariables = storedVariables
    }

    func load() async {
        generation += 1
        let current = generation
        state = .loading
        let started = SourcePerfTrace.now
        let items = await loadItems(source, overlay)
        guard !Task.isCancelled, current == generation else { return }
        groups = DiscoverViewModel.categoryGroups(from: items, defaultTitle: localized("分類"))
        filters = DiscoverViewModel.extractFilters(from: items)
        SourcePerfTrace.record("home.picker.categories",
                               "items=\(items.count) groups=\(groups.count) filters=\(filters.count) overlay=\(overlay.count)",
                               since: started, thresholdMs: 0)
        if groups.isEmpty {
            AppLogger.network("⟐ source listed no discover category",
                              context: ["source": source.bookSourceUrl, "overlay": overlay.description])
        }
        state = groups.isEmpty ? .empty : .loaded
    }

    /// The filter values the categories on screen were listed under: what a section picking
    /// one of them keeps.
    var filterValues: [String: String] {
        Dictionary(filters.map { ($0.paramKey, $0.selected) }, uniquingKeysWith: { first, _ in first })
    }

    /// Lists the categories again under `value`. The other filters keep the values the source
    /// read; a new 发现页类型 starts its 发现页来源 where the source's own page would
    /// (`DiscoverViewModel.discoverPlatform`), since each 类型 has its own platform list.
    func select(_ filter: DiscoverFilter, value: String) async {
        guard value != filter.selected else { return }
        var values = filterValues
        values[filter.paramKey] = value
        if filter.paramKey == "发现页类型" {
            values["发现页来源"] = DiscoverViewModel.discoverPlatform(for: value, dict: storedVariables(source))
        }
        overlay = values
        await load()
    }

    /// The category as a section shows it.
    func reference(for item: DiscoverCardItem) -> ExploreCategoryReference? {
        ExploreCategoryReference(source: source, item: item)
    }
}
