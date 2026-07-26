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

/// One book prepared for showcase rendering. Everything a row's `body` needs is
/// precomputed here, off the main thread, when its section finishes loading.
/// SwiftUI re-evaluates every visible row while the remaining sections stream
/// in, so per-render work the rows used to do inline — the SwiftSoup + regex
/// intro strip, and the audiobook inference's base64/JSON decoding plus a
/// UserDefaults read behind SHA256 + `queue.sync` — multiplied into dropped
/// frames once an aggregate source filled the page with sections.
struct DiscoverBookDisplay: Identifiable {
    let book: OnlineBook
    /// Plain-text intro (`ReaderHTMLUtilities.displayText` of `book.intro`).
    let intro: String
    /// Whether the audiobook cover badge shows (`inferredContentKind == .audio`).
    let isAudiobook: Bool

    var id: UUID { book.id }
}

/// One ranked/featured block on the redesigned 發現 showcase. Each section maps
/// directly to one of the *book source's own* explore categories — the source
/// owns the feed; we only present it faithfully.
struct DiscoverShowcaseSection: Identifiable {
    let id: UUID
    let item: DiscoverCardItem
    let style: DiscoverSectionStyle
    /// Cover request context, resolved once per reload. Rows used to re-derive
    /// it per render (a linear source scan + header-JSON parse each time).
    let coverBaseURL: String?
    let coverHeaders: [String: String]
    var books: [DiscoverBookDisplay] = []
    var phase: DiscoverSectionPhase = .idle
    /// Short reason shown under the failed state, for on-device diagnosis.
    var errorReason: String?

    var title: String { item.title }

    init(item: DiscoverCardItem, coverBaseURL: String?, coverHeaders: [String: String]) {
        self.id = item.id
        self.item = item
        self.style = DiscoverViewModel.sectionStyle(for: item.title)
        self.coverBaseURL = coverBaseURL
        self.coverHeaders = coverHeaders
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

    /// Showcase sections for the redesigned 發現 page (one per source category).
    @Published var sections: [DiscoverShowcaseSection] = []

    @Published var isLoadingItems = false

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
    /// Runtime-variable keys this source's own filters target (learned from every
    /// healthy explore load, plus whatever the user picks). App-private bookkeeping,
    /// deliberately outside the source variable JSON so nothing the source's JS reads
    /// changes. Keyed by bookSourceUrl to match the runtime variable store.
    private let filterKeysPrefix = "discover.filterKeys."
    private let defaultDiscoverPlatform = "全部"
    private var loadItemsTask: Task<Void, Never>?
    /// Guards the one-shot "reset poisoned discover variable + reload" recovery so a source
    /// that genuinely returns no filters can't loop. Cleared whenever the selected source changes.
    private var didAutoResetDiscoverVariable = false

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
            didAutoResetDiscoverVariable = false
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
        didAutoResetDiscoverVariable = false
        reload()
    }

    // MARK: - Filters

    /// Apply a filter choice: persist it as the source's Legado runtime variable
    /// (read by the JS on its next run), then reload. Mirrors the source's own
    /// `show(m, t)`, which writes `t = m` and — for 发现页类型 only — resets the
    /// platform, because each 类型 has its own platform list.
    ///
    /// The discover page writes exactly the variables the source's filter actions
    /// name (`发现页类型`/`发现页来源`) plus its own per-类型 memory. It must NOT touch
    /// `更多设置`: that dictionary is the source's, holding the 默认搜索网站 the user
    /// picks per 类型 in 书源设置 (read back by searchUrl as `sourcesKey`) and the
    /// 搜索模式 that selects which of those rows search uses. Writing either from
    /// here silently redirects search away from what the user configured — and the
    /// source's own JS keeps 发现页类型 separate from 搜索模式 for exactly that reason.
    func selectFilter(_ filter: DiscoverFilter, value: String) {
        guard value != filter.selected, let source = selectedSource else { return }
        var dict = currentVariableDict(for: source)
        let moreSettings = (dict["更多设置"] as? [String: Any]) ?? [:]
        let currentMode = discoverMode(from: dict, moreSettings: moreSettings)

        dict[filter.paramKey] = value
        rememberFilterKeys([filter.paramKey], for: source)

        switch filter.paramKey {
        case "发现页类型":
            let platform = discoverPlatform(for: value, dict: dict)
            dict["发现页来源"] = platform
            rememberFilterKeys(["发现页来源"], for: source)
            Self.setDiscoverPlatform(platform, forMode: value, in: &dict)
        case "发现页来源":
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

    func reload(forceRefresh: Bool = false) {
        guard let source = selectedSource else {
            items = []
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
        let cacheKey = discoverKindsCacheKey(for: source)
        loadItemsTask = Task { [weak self] in
            // Some sources' 榜單/分類 read a site cookie inline (起点 _csrfToken) that's only set by
            // browsing the site — without it every section loads 0 books and 发现页 looks empty.
            // Prime it before the sections start fetching books. No-op when not needed / already set.
            await BookSourceFetcher.shared.primeDiscoverCookies(in: source)
            guard let self, !Task.isCancelled else { return }

            // Category list cache (Legado exploreKinds-style): `@js:` exploreUrls
            // re-run their JS (often with network calls) on every open just to
            // rebuild the same category list. The key covers rule + discover
            // variables, so filter changes and source updates fetch fresh.
            if !forceRefresh, let cached = DiscoverKindsCache.shared.items(forKey: cacheKey) {
                self.applyDiscoverItems(cached)
                return
            }

            var raw = await BookSourceFetcher.shared.discoverItems(page: 1, in: source)
            guard !Task.isCancelled else { return }

            // Recover from a poisoned discover variable. A JS exploreUrl that builds
            // `type:"select"` filters (createFilter) but returns NONE means the source's
            // own JS fell into its catch fallback — typically because a persisted runtime
            // `sort`/筛选 value no longer matches the source's category table, so its
            // `csh()` keeps the stale value and throws. The runtime variable is keyed by
            // bookSourceUrl, so this survives re-import and silently degrades 发现页 to the
            // bare 榜单 fallback. Drop only the filter values *we* wrote and re-fetch INLINE
            // (re-entrant reload() could cancel its own task and leave sections empty) so
            // `csh()` re-initialises. Never clear the whole variable: it also holds the
            // source's own state (云端配置/线路/更多设置 — the user's 默认搜索网站 lives there).
            if !self.didAutoResetDiscoverVariable,
               Self.exploreLikelyDegraded(source: source, items: raw) {
                self.didAutoResetDiscoverVariable = true
                if self.resetDiscoverFilterValues(for: source) {
                    raw = await BookSourceFetcher.shared.discoverItems(page: 1, in: source)
                    guard !Task.isCancelled else { return }
                }
            }

            // Only persist a healthy category list; caching the degraded 榜单
            // fallback would pin the broken state until the next force refresh.
            // Recompute the key: the auto-reset above may have cleared variables.
            if !Self.exploreLikelyDegraded(source: source, items: raw) {
                DiscoverKindsCache.shared.store(
                    raw, forKey: self.discoverKindsCacheKey(for: source))
            }

            self.applyDiscoverItems(raw)
        }
    }

    /// Shared tail of `reload()` for both the cache-hit and network paths.
    private func applyDiscoverItems(_ raw: [ModernParserBridge.DiscoverItem]) {
        rawItems = raw
        filters = Self.extractFilters(from: raw)
        // Learn which runtime variables this source's filters target, so a later
        // degraded load can reset exactly those and nothing else.
        if let source = selectedSource, !filters.isEmpty {
            rememberFilterKeys(filters.map(\.paramKey), for: source)
        }
        let mapped = raw.compactMap(Self.mapItem)
        items = mapped
        isLoadingItems = false
        buildSections(from: mapped)
    }

    /// A message the source put in place of its categories.
    ///
    /// A label-only explore payload (title, but no url and no action) is how a
    /// Legado source says "configure me first" — 同人小说网's `/explore/init`
    /// answers `[{"title":"请先于【源变量】处填写共享Token","url":""}]` until a token
    /// is stored. `mapItem` correctly drops such items as non-navigable, so
    /// without surfacing them here the 發現頁 just looks broken.
    var sourceNotice: String? {
        guard items.isEmpty, !rawItems.isEmpty else { return nil }
        let labels = rawItems.compactMap { item -> String? in
            guard (item.type ?? "") != "select" else { return nil }  // filters render on their own
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty || title == "--" ? nil : title
        }
        guard !labels.isEmpty else { return nil }
        return labels.prefix(4).joined(separator: "\n")
    }

    /// Cache key for the current (source, discover runtime variables) pair.
    private func discoverKindsCacheKey(for source: BookSource) -> String {
        let variableDict = currentVariableDict(for: source)
        return DiscoverKindsCache.key(
            sourceUrl: source.bookSourceUrl,
            exploreUrl: source.exploreUrl,
            variableJSON: variableDict.isEmpty ? nil : Self.canonicalJSON(variableDict)
        )
    }

    // MARK: - Showcase sections

    /// Turn the source's fetchable explore categories into showcase sections.
    private func buildSections(from items: [DiscoverCardItem]) {
        // All sections share the selected source's cover context; parse the
        // header JSON once here instead of per row per render.
        let coverBaseURL = selectedSource?.bookSourceUrl
        let coverHeaders = selectedSource?.parsedHeaders ?? [:]
        sections = Self.showcaseItems(
            from: items,
            customKeys: usesCustomCategorySelection ? selectedCategoryKeys : nil,
            defaultLimit: maxShowcaseSections
        ).map {
            DiscoverShowcaseSection(item: $0, coverBaseURL: coverBaseURL, coverHeaders: coverHeaders)
        }
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
            var displays: [DiscoverBookDisplay] = []
            var reason: String?
            var ok = false
            do {
                loaded = try await BookSourceFetcher.shared.discoverBooks(from: raw, page: 1, in: source)
                displays = await Self.makeDisplays(loaded, source: source)
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
                // Mutate a copy and write back once: each subscript write
                // publishes the whole array and re-renders every visible section.
                var updated = self.sections[idx]
                if ok {
                    updated.books = displays
                    updated.phase = .loaded
                } else {
                    updated.phase = .failed
                    updated.errorReason = reason
                }
                self.sections[idx] = updated
                if ok {
                    self.prefetchCovers(loaded, source: source)
                }
            }
            self.isPumpingSections = false
            self.pumpSectionQueue()
        }
    }

    /// Precompute the row-rendering derivations for a batch of books, off the
    /// main actor (`nonisolated` + `async` runs on the global executor).
    nonisolated static func makeDisplays(
        _ books: [OnlineBook],
        source: BookSource?
    ) async -> [DiscoverBookDisplay] {
        guard !books.isEmpty else { return [] }
        // One runtime-variable read per batch — it costs SHA256 + queue.sync +
        // a UserDefaults read + JSON parse — instead of one per book.
        let modeMarkers = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        let sourceType = source?.bookSourceType
        return books.map { book in
            DiscoverBookDisplay(
                book: book,
                intro: ReaderHTMLUtilities.displayText(fromHTMLFragment: book.intro),
                isAudiobook: OnlineBookContentInference.infer(
                    sourceType: sourceType,
                    runtimeVariables: book.runtimeVariables,
                    urls: [book.bookUrl, book.tocUrl],
                    metadataText: [book.kind, book.intro, book.lastChapter, book.sourceName]
                        + modeMarkers
                ) == .audio
            )
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
        for url in urls {
            CoverDecodeService.shared.registerIfNeeded(coverUrl: url, source: source)
        }
        Task.detached(priority: .utility) {
            // A section can carry dozens of covers; bound the fan-out so warming
            // one section doesn't burst that many simultaneous fetches + decodes
            // while the page is scrolling.
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(4, urls.count) {
                    let url = urls[next]
                    next += 1
                    group.addTask {
                        _ = await BookCoverLoader.loadImage(urlString: url, headers: headers)
                    }
                }
                while await group.next() != nil {
                    guard next < urls.count else { continue }
                    let url = urls[next]
                    next += 1
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
        // A source can emit the same category in several of its groups (番茄's
        // explore API repeats hot tags across lists with the same category_id,
        // i.e. identical stableKey). Selection is keyed by stableKey, so without
        // dedup a custom selection matches every occurrence and the showcase
        // shows duplicate sections; keep only the first occurrence.
        var seen = Set<String>()
        let fetchable = items.filter { $0.isFetchable && seen.insert($0.stableKey).inserted }
        guard let customKeys else {
            return Array(fetchable.prefix(defaultLimit))
        }
        let selected = fetchable.filter { customKeys.contains($0.stableKey) }
        // A per-source customization saved earlier can go stale: if the source's categories
        // changed (e.g. 起点's 分类 chips depend on the selected genre, so their stableKeys
        // shift), none of the saved keys match the current items and this filter returns empty
        // — blanking the entire 發現頁. Fall back to the default set rather than show nothing.
        return selected.isEmpty ? Array(fetchable.prefix(defaultLimit)) : selected
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

    /// True when the source *should* emit `type:"select"` filters (its exploreUrl JS calls
    /// `createFilter` / builds `select` controls) but the returned items contain none — the
    /// hallmark of the source's JS having fallen into its own catch/fallback branch (usually a
    /// poisoned runtime `sort`/筛选 value). Used to trigger a one-shot variable reset + reload.
    nonisolated static func exploreLikelyDegraded(
        source: BookSource,
        items: [ModernParserBridge.DiscoverItem]
    ) -> Bool {
        let explore = source.exploreUrl
        let buildsFilters = explore.contains("createFilter")
            || explore.contains("\"select\"")
            || explore.contains("'select'")
        guard buildsFilters else { return false }
        return !items.contains { ($0.type ?? "") == "select" }
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
        // Mirror the source's own fallback (`sources = 发现页来源 || 更多设置[tab] || '全部'`):
        // with no discover pick yet, start from the 默认搜索网站 the user configured for
        // this 类型. A multi-site list (「番茄,七猫」) is meaningless as a single discover
        // platform, so those fall through to 全部.
        if let moreSettings = dict["更多设置"] as? [String: Any],
           let configured = Self.nonEmptyString(moreSettings[mode]),
           !configured.contains(",") {
            return configured
        }
        return defaultDiscoverPlatform
    }

    // MARK: - Discover platform memory (app-private, kept out of 更多设置)

    /// App-private key holding the user's per-类型 discover platform choice.
    /// Aggregate-source JS never reads this, so it cannot leak into search.
    nonisolated static let discoverPlatformMemoryKey = "__discoverSourceByMode"

    private static func setDiscoverPlatform(
        _ platform: String, forMode mode: String, in dict: inout [String: Any]
    ) {
        guard !mode.isEmpty else { return }
        var memory = (dict[discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        memory[mode] = platform
        dict[discoverPlatformMemoryKey] = memory
    }

    // MARK: - Filter variable bookkeeping

    private func filterKeysStorageKey(for source: BookSource) -> String {
        filterKeysPrefix + source.bookSourceUrl
    }

    private func knownFilterKeys(for source: BookSource) -> [String] {
        UserDefaults.standard.stringArray(forKey: filterKeysStorageKey(for: source)) ?? []
    }

    private func rememberFilterKeys(_ keys: [String], for source: BookSource) {
        let incoming = keys.filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
        var known = knownFilterKeys(for: source)
        let added = incoming.filter { !known.contains($0) }
        guard !added.isEmpty else { return }
        known.append(contentsOf: added)
        UserDefaults.standard.set(known, forKey: filterKeysStorageKey(for: source))
    }

    /// Drop the filter values the discover page owns for this source (the poisoned-`csh()`
    /// recovery in `reload()`). Returns whether anything changed, so the caller only
    /// re-fetches when a retry can actually produce a different result.
    private func resetDiscoverFilterValues(for source: BookSource) -> Bool {
        let keys = knownFilterKeys(for: source)
        guard !keys.isEmpty else { return false }
        var dict = currentVariableDict(for: source)
        var changed = false
        for key in keys where dict[key] != nil {
            dict.removeValue(forKey: key)
            changed = true
        }
        guard changed else { return false }
        writeVariableDict(dict, for: source)
        return true
    }

    private func repairHardcodedDiscoverSourceIfNeeded(for source: BookSource) {
        let dict = currentVariableDict(for: source)
        let repaired = Self.repairHardcodedDiscoverSource(in: dict)
        guard Self.canonicalJSON(dict) != Self.canonicalJSON(repaired) else { return }
        writeVariableDict(repaired, for: source)
    }

    /// Older builds mirrored the source JS too literally and persisted
    /// `发现页来源 = 番茄` whenever the mode changed. Prefer the platform the user
    /// actually chose for this 类型 — their discover pick (app-private memory), else
    /// the 默认搜索网站 they set in the source's own settings page (`更多设置[类型]`).
    /// A discover pick of 番茄 lands in memory, so a deliberate 番茄 is never rewritten.
    nonisolated static func repairHardcodedDiscoverSource(in dict: [String: Any]) -> [String: Any] {
        guard (dict["发现页来源"] as? String) == "番茄" else { return dict }

        let moreSettings = (dict["更多设置"] as? [String: Any]) ?? [:]
        let memory = (dict[discoverPlatformMemoryKey] as? [String: Any]) ?? [:]
        let mode = nonEmptyString(dict["发现页类型"])
            ?? nonEmptyString(moreSettings["搜索模式"])
            ?? "小说"
        let configured = nonEmptyString(moreSettings[mode]).flatMap {
            $0.contains(",") ? nil : $0
        }
        guard let saved = nonEmptyString(memory[mode]) ?? configured,
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
