import Combine
import Foundation
import SwiftUI

// MARK: - Discover Card Item

/// A single tappable entry on the 書源發現 (book-source discover) screen, derived
/// from a `ModernParserBridge.DiscoverItem`. Items are either *actions* (login /
/// open-in-browser) or *categories* (load a book list via `discoverBooks`).
struct DiscoverCardItem: Identifiable {
    let id = UUID()
    let title: String
    let stableKey: String
    let raw: ModernParserBridge.DiscoverItem
    let isAction: Bool
    let actionURL: String?
    let isFetchable: Bool
}

// MARK: - Discover Filter

/// One dropdown filter the *book source itself* emits from its exploreUrl JS
/// (e.g. 线路 / 类型 / 频道 / 平台). Each maps to a Legado runtime variable
/// (`paramKey`) the JS reads on its next run. Options (`chars`) and the current
/// value (`default`) come straight from the source's `type:"select"` item — for
/// the 光遇 aggregator the 平台 options are the per-mode cloud config (`js[tab]`),
/// so they change when 类型 switches.
struct DiscoverFilter: Identifiable {
    let id = UUID()
    let title: String
    let paramKey: String
    let options: [String]
    var selected: String
}

// MARK: - Discover Settings

/// One visible group in 發現頁設定. Group titles come from source-emitted
/// non-fetchable labels; entries are the actual fetchable/action discover items.
struct DiscoverSettingsGroup: Identifiable {
    let id: String
    let title: String
    let items: [DiscoverCardItem]
}

// MARK: - Discover Showcase Section

/// How a showcase section renders its books. `featured` = horizontal cover
/// carousel (推薦/精選); `ranked` = numbered vertical list (榜單/排行).
enum DiscoverSectionStyle {
    case featured
    case ranked
}

/// Per-section loading lifecycle for the three-state UI (loading / empty / error).
enum DiscoverSectionPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// One ranked/featured block on the redesigned 發現 showcase. Each section maps
/// directly to one of the *book source's own* explore categories — the source
/// owns the feed; we only present it faithfully.
struct DiscoverShowcaseSection: Identifiable {
    let id: UUID
    let item: DiscoverCardItem
    let style: DiscoverSectionStyle
    var books: [OnlineBook] = []
    var phase: DiscoverSectionPhase = .idle
    /// Short reason shown under the failed state, for on-device diagnosis.
    var errorReason: String?

    var title: String { item.title }

    init(item: DiscoverCardItem) {
        self.id = item.id
        self.item = item
        self.style = DiscoverViewModel.sectionStyle(for: item.title)
    }
}

// MARK: - Discover View Model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var exploreSources: [BookSource] = []
    @Published var selectedSourceId: UUID?

    @Published var items: [DiscoverCardItem] = []
    /// Raw source-emitted discover items, including `select` controls and pure
    /// label separators. The main showcase maps only fetchable/action entries;
    /// the settings sheet needs the raw list to preserve the source's own groups.
    @Published var rawItems: [ModernParserBridge.DiscoverItem] = []
    @Published var books: [OnlineBook] = []
    @Published var booksSectionTitle: String = ""

    /// Showcase sections for the redesigned 發現 page (one per source category).
    @Published var sections: [DiscoverShowcaseSection] = []

    @Published var isLoadingItems = false
    @Published var isLoadingBooks = false

    /// Max number of source categories rendered as showcase sections.
    let maxShowcaseSections = 12
    /// Serial loading queue for showcase sections (see `loadSection`).
    private var sectionQueue: [UUID] = []
    private var isPumpingSections = false

    /// Filter dropdowns the book source emits from its exploreUrl JS, repopulated
    /// on every reload. Empty for sources that don't emit `select` items.
    @Published var filters: [DiscoverFilter] = []
    @Published private(set) var usesCustomCategorySelection = false
    @Published private(set) var selectedCategoryKeys: Set<String> = []

    private let sourceStore = BookSourceStore.shared
    private let runtimeStore = BookSourceRuntimeStateStore.shared
    private let selectedSourceKey = "discover.selectedSourceId"
    private let categorySelectionPrefix = "discover.categorySelection."
    private let defaultDiscoverPlatform = "全部"
    private var loadItemsTask: Task<Void, Never>?
    private var loadBooksTask: Task<Void, Never>?

    var selectedSource: BookSource? {
        exploreSources.first { $0.id == selectedSourceId }
    }

    var hasExploreSource: Bool { selectedSource != nil }

    init() {
        if let stored = UserDefaults.standard.string(forKey: selectedSourceKey) {
            selectedSourceId = UUID(uuidString: stored)
        }
    }

    // MARK: - Source lifecycle

    func refreshSources() {
        exploreSources = sourceStore.enabledSources.filter {
            $0.enabledExplore
                && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if selectedSourceId == nil || !exploreSources.contains(where: { $0.id == selectedSourceId }) {
            selectedSourceId = exploreSources.first?.id
            persistSelectedSource()
        }
        loadCategorySelectionForSelectedSource()
        if items.isEmpty, hasExploreSource { reload() }
    }

    func selectSource(_ id: UUID) {
        guard id != selectedSourceId else { return }
        selectedSourceId = id
        persistSelectedSource()
        loadCategorySelectionForSelectedSource()
        filters = []
        reload()
    }

    // MARK: - Filters

    /// Apply a filter choice: persist it as the source's Legado runtime variable
    /// (read by the JS on its next run), then reload. Mirrors the source's own
    /// `show()` — switching 类型 resets the platform and syncs the search mode,
    /// because each 类型 has its own platform list.
    ///
    /// Important: the per-类型 platform the user picks on the *discover* page is
    /// kept in the app-private `__discoverSourceByMode` key, NOT in `更多设置[类型]`.
    /// Aggregate sources (光遇/大灰狼…) read `更多设置[类型]` as their *search*
    /// sub-site filter (`sourcesKey`), so writing a single platform there would
    /// pin search to one site instead of `全部`. Discover itself reads
    /// `发现页来源`/`发现页类型`, so it is unaffected.
    func selectFilter(_ filter: DiscoverFilter, value: String) {
        guard value != filter.selected, let source = selectedSource else { return }
        var dict = Self.sanitizeDiscoverVariable(currentVariableDict(for: source))
        var moreSettings = (dict["更多设置"] as? [String: Any]) ?? [:]
        let currentMode = discoverMode(from: dict, moreSettings: moreSettings)

        dict[filter.paramKey] = value

        switch filter.paramKey {
        case "发现页类型":
            let platform = discoverPlatform(for: value, dict: dict)
            dict["发现页来源"] = platform
            moreSettings["搜索模式"] = value
            dict["更多设置"] = moreSettings
            Self.setDiscoverPlatform(platform, forMode: value, in: &dict)
        case "发现页来源":
            moreSettings["搜索模式"] = currentMode
            dict["更多设置"] = moreSettings
            Self.setDiscoverPlatform(value, forMode: currentMode, in: &dict)
        default:
            break
        }

        writeVariableDict(dict, for: source)
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index].selected = value
        }
        clearCategorySelection(for: source)
        reload()
    }

    // MARK: - Discover page category customization

    var discoverSettingsGroups: [DiscoverSettingsGroup] {
        Self.discoverSettingsGroups(from: rawItems)
    }

    var selectedCategoryCount: Int {
        if usesCustomCategorySelection {
            return selectedCategoryKeys.count
        }
        return Self.showcaseItems(
            from: items,
            customKeys: nil,
            defaultLimit: maxShowcaseSections
        ).count
    }

    func isCategorySelected(_ item: DiscoverCardItem) -> Bool {
        if usesCustomCategorySelection {
            return selectedCategoryKeys.contains(item.stableKey)
        }
        return Self.showcaseItems(
            from: items,
            customKeys: nil,
            defaultLimit: maxShowcaseSections
        ).contains { $0.stableKey == item.stableKey }
    }

    func toggleCategoryVisibility(_ item: DiscoverCardItem) {
        guard item.isFetchable else { return }
        if !usesCustomCategorySelection {
            selectedCategoryKeys = Set(Self.showcaseItems(
                from: items,
                customKeys: nil,
                defaultLimit: maxShowcaseSections
            ).map(\.stableKey))
            usesCustomCategorySelection = true
        }
        if selectedCategoryKeys.contains(item.stableKey) {
            selectedCategoryKeys.remove(item.stableKey)
        } else {
            selectedCategoryKeys.insert(item.stableKey)
        }
        persistCategorySelection()
        buildSections(from: items)
    }

    func selectAllCategories() {
        let all = items.filter { $0.isFetchable }.map(\.stableKey)
        usesCustomCategorySelection = true
        selectedCategoryKeys = Set(all)
        persistCategorySelection()
        buildSections(from: items)
    }

    func resetCategorySelection() {
        guard let source = selectedSource else { return }
        clearCategorySelection(for: source)
        buildSections(from: items)
    }

    // MARK: - Loading

    func reload() {
        guard let source = selectedSource else {
            items = []
            books = []
            booksSectionTitle = ""
            cancelSectionTasks()
            sections = []
            rawItems = []
            filters = []
            return
        }
        repairHardcodedDiscoverSourceIfNeeded(for: source)
        loadItemsTask?.cancel()
        cancelSectionTasks()
        rawItems = []
        items = []
        sections = []
        isLoadingItems = true
        loadItemsTask = Task { [weak self] in
            let raw = await BookSourceFetcher.shared.discoverItems(page: 1, in: source)
            guard let self, !Task.isCancelled else { return }
            self.rawItems = raw
            self.filters = Self.extractFilters(from: raw)
            let mapped = raw.compactMap(Self.mapItem)
            self.items = mapped
            self.isLoadingItems = false
            self.buildSections(from: mapped)
            if let first = mapped.first(where: { $0.isFetchable }) {
                self.loadBooks(for: first)
            } else {
                self.loadBooksTask?.cancel()
                self.books = []
                self.booksSectionTitle = ""
            }
        }
    }

    // MARK: - Showcase sections

    /// Turn the source's fetchable explore categories into showcase sections.
    private func buildSections(from items: [DiscoverCardItem]) {
        sections = Self.showcaseItems(
            from: items,
            customKeys: usesCustomCategorySelection ? selectedCategoryKeys : nil,
            defaultLimit: maxShowcaseSections
        ).map { DiscoverShowcaseSection(item: $0) }
    }

    /// Enqueue one section's books to load — driven by the section view's `.task`.
    ///
    /// Loads run **serially** (one section at a time): a book source's explore
    /// fetch drives a JS runtime + shared login/cloud session, and firing several
    /// at once (LazyVStack renders multiple sections on first paint) can clobber
    /// that shared state. Sequential loading keeps each fetch deterministic.
    func loadSection(_ id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        if sections[index].phase == .loading || sections[index].phase == .loaded { return }
        if sectionQueue.contains(id) { return }
        sectionQueue.append(id)
        pumpSectionQueue()
    }

    /// Retry a single failed section.
    func retrySection(_ id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].phase = .idle
        sections[index].errorReason = nil
        loadSection(id)
    }

    private func pumpSectionQueue() {
        guard !isPumpingSections, let id = sectionQueue.first else { return }
        guard let source = selectedSource,
              let index = sections.firstIndex(where: { $0.id == id }) else {
            if !sectionQueue.isEmpty { sectionQueue.removeFirst() }
            pumpSectionQueue()
            return
        }
        isPumpingSections = true
        sections[index].phase = .loading
        let raw = sections[index].item.raw
        Task { [weak self] in
            var loaded: [OnlineBook] = []
            var reason: String?
            var ok = false
            do {
                loaded = try await BookSourceFetcher.shared.discoverBooks(from: raw, page: 1, in: source)
                ok = true
            } catch {
                reason = (error as NSError).localizedDescription
            }
            guard let self else { return }
            // A reload may have cleared/rebuilt the queue mid-flight; only the
            // active pump (its id still at the front) advances shared state.
            guard self.sectionQueue.first == id else { return }
            self.sectionQueue.removeFirst()
            if let idx = self.sections.firstIndex(where: { $0.id == id }) {
                if ok {
                    self.sections[idx].books = loaded
                    self.sections[idx].phase = .loaded
                    self.prefetchCovers(loaded, source: source)
                } else {
                    self.sections[idx].phase = .failed
                    self.sections[idx].errorReason = reason
                }
            }
            self.isPumpingSections = false
            self.pumpSectionQueue()
        }
    }

    private func cancelSectionTasks() {
        sectionQueue = []
        isPumpingSections = false
    }

    /// Warm the cover cache for a freshly loaded section so its cards paint right away
    /// instead of each fetching lazily on appear (covers used to trickle in until you
    /// opened 查看全部 — which warmed the cache as a side effect — and came back).
    private func prefetchCovers(_ books: [OnlineBook], source: BookSource) {
        let headers = BookCoverLoader.headers(
            sourceBaseURL: source.bookSourceUrl,
            sourceHeaders: source.parsedHeaders
        )
        let urls = books
            .map { $0.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && BookCoverLoader.cachedImage(for: $0) == nil }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        _ = await BookCoverLoader.loadImage(urlString: url, headers: headers)
                    }
                }
            }
        }
    }

    /// Section render style derived from the source's category title. The book
    /// source owns the categories; this only chooses a faithful presentation.
    nonisolated static func sectionStyle(for title: String) -> DiscoverSectionStyle {
        let featured = ["推荐", "推薦", "精选", "精選", "今日", "必读", "必讀",
                        "新书", "新書", "新作", "编辑", "編輯", "为你", "為你", "猜你"]
        if featured.contains(where: title.contains) { return .featured }
        let ranked = ["榜", "排行", "畅销", "暢銷", "热销", "熱銷", "热门", "熱門",
                      "完本", "完结", "完結", "top", "TOP", "Top"]
        if ranked.contains(where: title.contains) { return .ranked }
        return .featured
    }

    func handleTap(_ item: DiscoverCardItem, onNavigate: (String) -> Void) {
        if item.isAction, let url = item.actionURL {
            onNavigate(url)
        } else if item.isFetchable {
            loadBooks(for: item)
        }
    }

    func loadBooks(for item: DiscoverCardItem) {
        guard let source = selectedSource, item.isFetchable else { return }
        loadBooksTask?.cancel()
        isLoadingBooks = true
        booksSectionTitle = item.title
        loadBooksTask = Task { [weak self] in
            let result =
                (try? await BookSourceFetcher.shared.discoverBooks(from: item.raw, page: 1, in: source)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.books = result
            self.isLoadingBooks = false
        }
    }

    // MARK: - Item mapping

    nonisolated static func mapItem(_ raw: ModernParserBridge.DiscoverItem) -> DiscoverCardItem? {
        let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "--" else { return nil }

        let url = (raw.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isAction = url.contains("java.startBrowser")
        let actionURL = isAction ? extractHTTPURL(from: url) : nil
        let isFetchable = !isAction && !url.isEmpty

        // Skip pure labels (no url, no action) — e.g. a "username's 番茄" header.
        guard isAction || isFetchable else { return nil }

        return DiscoverCardItem(
            title: title,
            stableKey: stableKey(for: raw, title: title, url: url),
            raw: raw,
            isAction: isAction,
            actionURL: actionURL,
            isFetchable: isFetchable
        )
    }

    nonisolated static func extractHTTPURL(from string: String) -> String? {
        guard let range = string.range(of: "https?://[^\"')\\s]+", options: .regularExpression) else {
            return nil
        }
        return String(string[range])
    }

    nonisolated static func stableKey(
        for raw: ModernParserBridge.DiscoverItem,
        title: String,
        url: String
    ) -> String {
        [
            title,
            url,
            raw.type ?? "",
            raw.viewName ?? ""
        ].joined(separator: "\u{1F}")
    }

    nonisolated static func showcaseItems(
        from items: [DiscoverCardItem],
        customKeys: Set<String>?,
        defaultLimit: Int
    ) -> [DiscoverCardItem] {
        let fetchable = items.filter { $0.isFetchable }
        guard let customKeys else {
            return Array(fetchable.prefix(defaultLimit))
        }
        return fetchable.filter { customKeys.contains($0.stableKey) }
    }

    nonisolated static func uniqueAdditionalBooks(
        _ incoming: [OnlineBook],
        existing: [OnlineBook]
    ) -> [OnlineBook] {
        var seen = Set(existing.map(bookIdentity))
        var unique: [OnlineBook] = []
        for book in incoming {
            let identity = bookIdentity(book)
            if seen.insert(identity).inserted {
                unique.append(book)
            }
        }
        return unique
    }

    nonisolated private static func bookIdentity(_ book: OnlineBook) -> String {
        let primary = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return [
            book.name.trimmingCharacters(in: .whitespacesAndNewlines),
            book.author.trimmingCharacters(in: .whitespacesAndNewlines),
            book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1F}")
    }

    nonisolated static func discoverSettingsGroups(
        from raw: [ModernParserBridge.DiscoverItem],
        defaultTitle: String = "發現"
    ) -> [DiscoverSettingsGroup] {
        var groups: [DiscoverSettingsGroup] = []
        var currentTitle = defaultTitle
        var currentItems: [DiscoverCardItem] = []

        func flush() {
            guard !currentItems.isEmpty else { return }
            groups.append(
                DiscoverSettingsGroup(
                    id: "\(groups.count)-\(currentTitle)",
                    title: currentTitle,
                    items: currentItems
                )
            )
            currentItems = []
        }

        for item in raw {
            if (item.type ?? "") == "select" { continue }
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "--" else { continue }
            if let card = mapItem(item) {
                currentItems.append(card)
            } else {
                flush()
                currentTitle = normalizedDiscoverGroupTitle(title)
            }
        }
        flush()
        return groups
    }

    nonisolated private static func normalizedDiscoverGroupTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let decorative = CharacterSet(charactersIn: "-—_─═▱༺༻ˇ»«`´ʚɞ🟥🟧🟨🟪🟠🟡🟣 ")
        let stripped = trimmed.trimmingCharacters(in: decorative)
        return stripped.isEmpty ? trimmed : stripped
    }

    // MARK: - Source-emitted filters

    /// Pull the source's `type:"select"` dropdowns out of the exploreUrl result.
    /// The exploreUrl JS encodes the target variable in the action, e.g.
    /// `show(infoMap['平台'],'发现页来源')` → paramKey `发现页来源`.
    static func extractFilters(from raw: [ModernParserBridge.DiscoverItem]) -> [DiscoverFilter] {
        raw.compactMap { item in
            guard (item.type ?? "") == "select" else { return nil }
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let options = (item.chars ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !title.isEmpty, !options.isEmpty else { return nil }
            let paramKey = parseParamKey(from: item.action) ?? title
            let preferred = (item.default ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = preferred.isEmpty ? (options.first ?? "") : preferred
            return DiscoverFilter(title: title, paramKey: paramKey, options: options, selected: selected)
        }
    }

    /// Extract the variable key from an action like `show(infoMap['平台'],'发现页来源')`
    /// — the last single-quoted token.
    private static func parseParamKey(from action: String?) -> String? {
        guard let action else { return nil }
        let parts = action.components(separatedBy: "'")
        // Single-quoted tokens sit at odd indices ("a'X'b'Y'c" → [a,X,b,Y,c]).
        let quoted = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
        return quoted.last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Source runtime variables

    private func currentVariableDict(for source: BookSource) -> [String: Any] {
        guard let json = runtimeStore.sourceVariableJSON(for: source.bookSourceUrl),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func discoverMode(from dict: [String: Any], moreSettings: [String: Any]) -> String {
        if let mode = dict["发现页类型"] as? String, !mode.isEmpty {
            return mode
        }
        if let mode = moreSettings["搜索模式"] as? String, !mode.isEmpty {
            return mode
        }
        if let modeFilter = filters.first(where: { $0.paramKey == "发现页类型" }),
           !modeFilter.selected.isEmpty {
            return modeFilter.selected
        }
        return "小说"
    }

    private func discoverPlatform(for mode: String, dict: [String: Any]) -> String {
        let memory = (dict[Self.discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        if let saved = Self.nonEmptyString(memory[mode]) {
            return saved
        }
        // Back-compat: honor a legacy per-类型 platform still sitting in 更多设置
        // (sanitize will have moved it out, but be defensive).
        if let moreSettings = dict["更多设置"] as? [String: Any],
           let legacy = Self.nonEmptyString(moreSettings[mode]) {
            return legacy
        }
        return defaultDiscoverPlatform
    }

    // MARK: - Discover platform memory (app-private, kept out of 更多设置)

    /// App-private key holding the user's per-类型 discover platform choice.
    /// Aggregate-source JS never reads this, so it cannot leak into search.
    nonisolated static let discoverPlatformMemoryKey = "__discoverSourceByMode"

    /// Keys inside `更多设置` that are the source's own meta-settings (read by its
    /// search/discover JS) rather than an app-written per-类型 platform selection.
    /// Everything else the app previously persisted under 更多设置 was a single
    /// discover platform that the search JS misreads as its sub-site filter.
    nonisolated private static let moreSettingsMetaKeys: Set<String> = ["搜索模式", "强制搜索"]

    private static func setDiscoverPlatform(
        _ platform: String, forMode mode: String, in dict: inout [String: Any]
    ) {
        guard !mode.isEmpty else { return }
        var memory = (dict[discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        memory[mode] = platform
        dict[discoverPlatformMemoryKey] = memory
    }

    /// One-time normalization: move any legacy per-类型 platform entries out of
    /// `更多设置` (where an aggregate source's search JS reads them as `sourcesKey`)
    /// into the app-private memory key. This restores search to `全部` for users
    /// whose runtime state was polluted by earlier builds. No-op once clean.
    nonisolated static func sanitizeDiscoverVariable(_ dict: [String: Any]) -> [String: Any] {
        guard var moreSettings = dict["更多设置"] as? [String: Any] else { return dict }
        var memory = (dict[discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        var moved = false
        for (key, value) in moreSettings {
            guard !moreSettingsMetaKeys.contains(key), value is String else { continue }
            if memory[key] == nil { memory[key] = value }
            moreSettings.removeValue(forKey: key)
            moved = true
        }
        guard moved else { return dict }
        var result = dict
        result["更多设置"] = moreSettings
        result[discoverPlatformMemoryKey] = memory
        return result
    }

    private func repairHardcodedDiscoverSourceIfNeeded(for source: BookSource) {
        let dict = currentVariableDict(for: source)
        // Strip legacy per-类型 platform keys out of 更多设置 first (fixes aggregate
        // search pinned to one sub-site on already-polluted state), then apply the
        // hardcoded-source repair. Persist if either step changed anything.
        let sanitized = Self.sanitizeDiscoverVariable(dict)
        let repaired = Self.repairHardcodedDiscoverSource(in: sanitized)
        guard Self.canonicalJSON(dict) != Self.canonicalJSON(repaired) else { return }
        writeVariableDict(repaired, for: source)
    }

    /// Older builds mirrored the source JS too literally and persisted
    /// `发现页来源 = 番茄` whenever the mode changed. If a per-mode source is
    /// remembered (now in the app-private memory key, legacy: in `更多设置`),
    /// treat that as the user's intended source.
    nonisolated static func repairHardcodedDiscoverSource(in dict: [String: Any]) -> [String: Any] {
        guard (dict["发现页来源"] as? String) == "番茄" else { return dict }

        let moreSettings = (dict["更多设置"] as? [String: Any]) ?? [:]
        let memory = (dict[discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        let mode = nonEmptyString(dict["发现页类型"])
            ?? nonEmptyString(moreSettings["搜索模式"])
            ?? "小说"
        guard let saved = nonEmptyString(memory[mode]) ?? nonEmptyString(moreSettings[mode]),
              saved != "番茄"
        else { return dict }

        var repaired = dict
        repaired["发现页来源"] = saved
        return repaired
    }

    /// Stable JSON serialization (sorted keys) used to detect whether a runtime
    /// variable actually changed before persisting it.
    nonisolated static func canonicalJSON(_ dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeVariableDict(_ dict: [String: Any], for source: BookSource) {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        runtimeStore.setSourceVariableJSON(json, for: source.bookSourceUrl)
    }

    private func persistSelectedSource() {
        guard let id = selectedSourceId else { return }
        UserDefaults.standard.set(id.uuidString, forKey: selectedSourceKey)
    }

    private func loadCategorySelectionForSelectedSource() {
        guard let source = selectedSource else {
            usesCustomCategorySelection = false
            selectedCategoryKeys = []
            return
        }
        let key = categorySelectionKey(for: source)
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            usesCustomCategorySelection = true
            selectedCategoryKeys = Set(saved)
        } else {
            usesCustomCategorySelection = false
            selectedCategoryKeys = []
        }
    }

    private func persistCategorySelection() {
        guard let source = selectedSource else { return }
        UserDefaults.standard.set(
            Array(selectedCategoryKeys).sorted(),
            forKey: categorySelectionKey(for: source)
        )
    }

    private func clearCategorySelection(for source: BookSource) {
        UserDefaults.standard.removeObject(forKey: categorySelectionKey(for: source))
        usesCustomCategorySelection = false
        selectedCategoryKeys = []
    }

    private func categorySelectionKey(for source: BookSource) -> String {
        categorySelectionPrefix + source.id.uuidString
    }
}
