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

// MARK: - 發現頁設定

/// A source's categories as 發現頁設定 lists them, under the group label the source
/// emits before them (a non-fetchable title item, as Legado's explore page shows one).
struct DiscoverCategoryGroup: Identifiable {
    let id: String
    let title: String
    let items: [DiscoverCardItem]

    /// The groups holding categories that match `query`; a group whose own label matches
    /// keeps all of its categories. An empty query keeps every group.
    static func filtered(_ groups: [DiscoverCategoryGroup], matching query: String) -> [DiscoverCategoryGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedStandardContains(query) { return group }
            let items = group.items.filter { $0.title.localizedStandardContains(query) }
            guard !items.isEmpty else { return nil }
            return DiscoverCategoryGroup(id: group.id, title: group.title, items: items)
        }
    }
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
    /// Plain-text intro, cleaned the way search rows clean theirs.
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
    /// Read each time, so a change to 探索設定's chart keywords shows at once.
    var style: DiscoverSectionStyle { DiscoverViewModel.sectionStyle(for: item.title) }
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
        self.coverBaseURL = coverBaseURL
        self.coverHeaders = coverHeaders
    }
}

// MARK: - Discover View Model

/// One explore source's discover page: its categories, every one as a showcase section,
/// and the filters the source emits. Each source page owns one.
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var exploreSources: [BookSource] = []
    @Published var selectedSourceId: UUID?

    @Published var items: [DiscoverCardItem] = []
    /// Raw source-emitted discover items, including `select` controls and pure
    /// label separators. The showcase maps only fetchable/action entries.
    @Published var rawItems: [ModernParserBridge.DiscoverItem] = []

    /// Showcase sections for the redesigned 發現 page (one per source category).
    @Published var sections: [DiscoverShowcaseSection] = []

    @Published var isLoadingItems = false

    /// Serial loading queue for showcase sections (see `loadSection`).
    private var sectionQueue: [UUID] = []
    private var isPumpingSections = false

    /// Filter dropdowns the book source emits from its exploreUrl JS, repopulated
    /// on every reload. Empty for sources that don't emit `select` items.
    @Published var filters: [DiscoverFilter] = []

    /// The categories the reader picked to see (發現頁設定), or `nil` when none is picked
    /// and the page shows every one. Once some are picked the page shows those alone, so
    /// a category the source adds later stays off. Stored per source under the key
    /// 發現頁設定 used before the page showed every category, so a choice made then holds.
    @Published private(set) var shownCategoryKeys: Set<String>?
    private let categorySelectionPrefix = "discover.categorySelection."

    /// The source's explore `infoMap`, read after each load and after each control runs:
    /// what its inputs hold and where its toggles stand.
    @Published private(set) var quickActionValues: [String: String] = [:]
    /// Display names the source's `viewName` scripts gave its controls, by control.
    @Published private(set) var quickActionNames: [String: String] = [:]
    /// The control whose script is running; the others wait for it.
    @Published private(set) var runningQuickActionID: String?

    private let sourceStore = BookSourceStore.shared
    private let runtimeStore = BookSourceRuntimeStateStore.shared
    /// The page's source, looked up again after an edit gives it a new session.
    private let sourceURL: String
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

    /// Categories that open a web page (a source's `java.startBrowser` link) rather than
    /// list books.
    var pageItems: [DiscoverCardItem] {
        items.filter { $0.isAction && $0.actionURL != nil }
    }

    var selectedSource: BookSource? {
        exploreSources.first { $0.id == selectedSourceId }
    }

    var hasExploreSource: Bool { selectedSource != nil }

    init(source: BookSource) {
        sourceURL = source.bookSourceUrl
        exploreSources = [source]
        selectedSourceId = source.id
        loadCategorySelection()
    }

    /// The explore sources 探索 lists: enabled, with explore on and an explore URL.
    static func exploreSources(in store: BookSourceStore) -> [BookSource] {
        store.enabledSources.filter {
            $0.enabledExplore
                && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Source lifecycle

    /// Reads the page's source from the store again — an edit bumps its
    /// `lastUpdateTime`, which keys a fresh `BookSourceSession` — and loads the page the
    /// first time.
    func refreshSources() {
        let previousSourceId = selectedSourceId
        if let source = sourceStore.sources.first(where: { $0.bookSourceUrl == sourceURL }) {
            exploreSources = [source]
            selectedSourceId = source.id
        } else {
            exploreSources = []
            selectedSourceId = nil
        }
        if selectedSourceId != previousSourceId { loadCategorySelection() }
        if items.isEmpty, hasExploreSource { reload() }
    }

    // MARK: - 發現頁設定

    /// 發現頁設定's list: the categories the source returned, each once, under the group
    /// labels the source emits between them; `defaultTitle` heads those before any label.
    func categoryGroups(defaultTitle: String) -> [DiscoverCategoryGroup] {
        Self.categoryGroups(from: rawItems, defaultTitle: defaultTitle)
    }

    var hasCustomCategorySelection: Bool { shownCategoryKeys != nil }

    /// Whether the page shows `item`: every category while none is picked.
    func isCategoryShown(_ item: DiscoverCardItem) -> Bool {
        shownCategoryKeys?.contains(item.stableKey) ?? true
    }

    /// Whether the reader picked `item` in 發現頁設定.
    func isCategorySelected(_ item: DiscoverCardItem) -> Bool {
        shownCategoryKeys?.contains(item.stableKey) ?? false
    }

    /// Picks `item`, or unpicks it; unpicking the last one shows every category again.
    func toggleCategorySelection(_ item: DiscoverCardItem) {
        guard item.isFetchable else { return }
        var keys = shownCategoryKeys ?? []
        if keys.contains(item.stableKey) {
            keys.remove(item.stableKey)
        } else {
            keys.insert(item.stableKey)
        }
        shownCategoryKeys = keys.isEmpty ? nil : keys
        persistCategorySelection()
        buildSections(from: items)
    }

    func showAllCategories() {
        shownCategoryKeys = nil
        persistCategorySelection()
        buildSections(from: items)
    }

    private var categorySelectionKey: String? {
        selectedSourceId.map { categorySelectionPrefix + $0.uuidString }
    }

    private func loadCategorySelection() {
        guard let key = categorySelectionKey,
              let stored = UserDefaults.standard.stringArray(forKey: key) else {
            shownCategoryKeys = nil
            return
        }
        shownCategoryKeys = Set(stored)
    }

    private func persistCategorySelection() {
        guard let key = categorySelectionKey else { return }
        if let keys = shownCategoryKeys {
            UserDefaults.standard.set(keys.sorted(), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - 快捷操作: the source's own controls

    /// The source's buttons, inputs and toggles, each once (`DiscoverQuickAction`).
    var quickActions: [DiscoverQuickAction] {
        DiscoverQuickAction.actions(from: rawItems)
    }

    func displayName(for action: DiscoverQuickAction) -> String {
        action.literalDisplayName ?? quickActionNames[action.id] ?? action.title
    }

    /// Reads the controls' values and display names from the source's scripts. A toggle
    /// with nothing stored takes its default and keeps it, as legado-E and MD3 do.
    func refreshQuickActions() async {
        guard let source = selectedSource else { return }
        let actions = quickActions
        guard !actions.isEmpty else {
            quickActionValues = [:]
            quickActionNames = [:]
            return
        }
        var values = await DiscoverQuickActionRunner.infoMapValues(source: source)
        for action in actions where action.kind == .toggle && (values[action.title] ?? "").isEmpty {
            let value = action.toggleValue(in: values)
            await DiscoverQuickActionRunner.setInfoMapValue(value, forKey: action.title, source: source)
            values[action.title] = value
        }
        quickActionValues = values
        var names: [String: String] = [:]
        for action in actions {
            if let script = action.displayNameScript {
                names[action.id] = await DiscoverQuickActionRunner.displayName(script, source: source)
            }
        }
        quickActionNames = names
    }

    /// A button's tap: runs its script.
    func runButton(_ action: DiscoverQuickAction, presentToast: @escaping @MainActor (String) -> Void) async {
        await perform(action, presentToast: presentToast)
    }

    /// An input's new text: stored in `infoMap`, then its script runs if it has one.
    func submitText(
        _ text: String,
        for action: DiscoverQuickAction,
        presentToast: @escaping @MainActor (String) -> Void
    ) async {
        guard let source = selectedSource else { return }
        await DiscoverQuickActionRunner.setInfoMapValue(text, forKey: action.title, source: source)
        quickActionValues[action.title] = text
        await perform(action, presentToast: presentToast)
    }

    /// A toggle's tap: the next value, stored in `infoMap`, then its script.
    func cycleToggle(_ action: DiscoverQuickAction, presentToast: @escaping @MainActor (String) -> Void) async {
        guard let source = selectedSource else { return }
        let next = action.toggleValue(after: action.toggleValue(in: quickActionValues))
        await DiscoverQuickActionRunner.setInfoMapValue(next, forKey: action.title, source: source)
        quickActionValues[action.title] = next
        await perform(action, presentToast: presentToast)
    }

    /// Runs a control's script, then reloads the categories when it called
    /// `java.refreshExplore()` and reads the controls again — a script often changes
    /// what they show.
    private func perform(_ action: DiscoverQuickAction, presentToast: @escaping @MainActor (String) -> Void) async {
        guard runningQuickActionID == nil, let source = selectedSource else { return }
        guard let script = action.script else { return }
        runningQuickActionID = action.id
        let outcome = await DiscoverQuickActionRunner.run(
            script,
            title: action.title,
            source: source,
            presentToast: presentToast
        )
        runningQuickActionID = nil
        if let error = outcome.errorMessage {
            presentToast(String(format: localized("%@：%@"), localized("來源配置腳本錯誤"), error))
        }
        if outcome.refreshesExplore {
            reload(forceRefresh: true)
        } else {
            await refreshQuickActions()
        }
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
        reload()
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
        Task { await refreshQuickActions() }
    }

    /// A message the source put in place of its categories.
    ///
    /// A label-only explore payload (title, but no url and no action) is how a
    /// Legado source says "configure me first" — 同人小说网's `/explore/init`
    /// answers `[{"title":"请先于【源变量】处填写共享Token","url":""}]` until a token
    /// is stored. `mapItem` correctly drops such items as non-navigable, so
    /// without surfacing them here the 發現頁 just looks broken.
    ///
    /// When the source's rule JS produced nothing at all, fall through to what its
    /// API actually answered: the same source replies `{"error":"无效JWT…"}` once a
    /// *wrong* token is stored, and `requestApiUrl` returns null for it without a
    /// word — an empty page whose only explanation was in the device log.
    var sourceNotice: String? {
        guard items.isEmpty else { return nil }
        if !rawItems.isEmpty {
            let labels = rawItems.compactMap { item -> String? in
                guard (item.type ?? "") != "select" else { return nil }  // filters render on their own
                let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty || title == "--" ? nil : title
            }
            if !labels.isEmpty {
                return labels.prefix(4).joined(separator: "\n")
            }
        }
        guard let sourceUrl = selectedSource?.bookSourceUrl,
              let failure = SourceAPIErrorLog.shared.last(for: sourceUrl)
        else { return nil }
        return "\(localized("來源配置伺服器回應失敗"))\n\(failure.displayText)"
    }

    /// The selected source when the empty 發現頁 is explained by it asking for a
    /// device id it was never given — the one failure the reader can repair from
    /// here. See `AndroidIdentityRecovery`.
    var androidIdentityRepairSource: BookSource? {
        guard items.isEmpty, let source = selectedSource,
              AndroidIdentityRecovery.canRepair(source)
        else { return nil }
        return source
    }

    /// Turn 提供裝置識別碼 on for the selected source and load 發現 again.
    ///
    /// `refreshSources()` before the reload is required, not cosmetic:
    /// `exploreSources` is a snapshot taken before the edit, and reloading against
    /// that stale copy would land on the same `BookSourceSession` — its cache key
    /// carries `lastUpdateTime`, which the edit just advanced.
    func enableAndroidIdentityAndReload() {
        guard let source = androidIdentityRepairSource else { return }
        AndroidIdentityRecovery.enable(source)
        refreshSources()
        reload(forceRefresh: true)
    }

    /// Cache key for the current (source, discover runtime variables) pair.
    private func discoverKindsCacheKey(for source: BookSource) -> String {
        // Fingerprint whatever the source variable actually IS. Keying only off a
        // parsed *dictionary* made a bare-string variable invisible — 同人小说网 stores
        // its share Token as a plain JWT, `currentVariableDict` returns `[:]` for it,
        // and the key came out identical before and after the user pasted the token.
        // The 發現頁 then kept serving the 「请先于【源变量】处填写共享Token」 list it had
        // cached while there was no token. Canonical JSON stays the fingerprint for
        // object variables so key order can't cause spurious misses.
        let variableDict = currentVariableDict(for: source)
        let fingerprint = variableDict.isEmpty
            ? runtimeStore.sourceVariableJSON(for: source.bookSourceUrl)
            : Self.canonicalJSON(variableDict)
        return DiscoverKindsCache.key(
            sourceUrl: source.bookSourceUrl,
            exploreUrl: source.exploreUrl,
            variableJSON: fingerprint
        )
    }

    // MARK: - Showcase sections

    /// Turn the source's fetchable explore categories into showcase sections, leaving out
    /// those turned off in 發現頁設定. A category that already has a section keeps it,
    /// books and all, so turning another one on or off loads nothing again; a reload
    /// maps fresh items, so it starts every section anew.
    private func buildSections(from items: [DiscoverCardItem]) {
        // All sections share the selected source's cover context; parse the
        // header JSON once here instead of per row per render.
        let coverBaseURL = selectedSource?.bookSourceUrl
        let coverHeaders = selectedSource?.parsedHeaders ?? [:]
        let existing = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sections = Self.showcaseItems(from: items)
            .filter { shownCategoryKeys?.contains($0.stableKey) ?? true }
            .map {
                existing[$0.id]
                    ?? DiscoverShowcaseSection(item: $0, coverBaseURL: coverBaseURL, coverHeaders: coverHeaders)
            }
    }

    /// Enqueue one section's books to load — driven by the section view's `.task`.
    ///
    /// Loads run **serially** (one section at a time): a book source's explore
    /// fetch drives a JS runtime + shared login/cloud session, and firing several
    /// at once (LazyVStack renders multiple sections on first paint) can clobber
    /// that shared state. Sequential loading keeps each fetch deterministic.
    ///
    /// 探索設定's 預加載數量 queues that many of the categories after it too, so they are
    /// ready by the time they scroll into view. Still one at a time, so a larger number
    /// means a longer queue, never more requests at once. Preloading takes only
    /// categories never tried: a failed one waits for its own retry button.
    func loadSection(_ id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let phase = sections[index].phase
        if phase != .loading, phase != .loaded, !sectionQueue.contains(id) {
            sectionQueue.append(id)
        }
        let ahead = ExploreSettings.preloadCount
        if ahead > 0 {
            for next in sections.indices.dropFirst(index + 1).prefix(ahead)
            where sections[next].phase == .idle && !sectionQueue.contains(sections[next].id) {
                sectionQueue.append(sections[next].id)
            }
        }
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
                intro: SearchResultIPSDiagnostics.sanitizeIntroForSearchRow(
                    OnlineBookDetailPresentationPolicy.sanitizeIntro(book.intro)
                ),
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
    /// A category whose title holds any of 探索設定's chart keywords is a numbered chart;
    /// every other one is a shelf of covers.
    nonisolated static func sectionStyle(for title: String) -> DiscoverSectionStyle {
        sectionStyle(for: title, rankedKeywords: ExploreSettings.rankedKeywords)
    }

    nonisolated static func sectionStyle(for title: String, rankedKeywords: [String]) -> DiscoverSectionStyle {
        let ranked = rankedKeywords.contains { keyword in
            !keyword.isEmpty && title.range(of: keyword, options: .caseInsensitive) != nil
        }
        return ranked ? .ranked : .featured
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

    /// The source's fetchable categories, each once. A source can emit the same category
    /// in several of its groups (番茄's explore API repeats hot tags across lists with the
    /// same category_id, i.e. identical stableKey); only the first occurrence becomes a
    /// section, so the page never shows one twice.
    nonisolated static func showcaseItems(from items: [DiscoverCardItem]) -> [DiscoverCardItem] {
        var seen = Set<String>()
        return items.filter { $0.isFetchable && seen.insert($0.stableKey).inserted }
    }

    /// The fetchable categories in `raw`, each once as on the page, grouped under the
    /// non-fetchable title items between them, kept as the source draws them (☆ 排行榜 ☆).
    /// Filters (`select`) and page links are not categories the page lists, so they are
    /// left out.
    nonisolated static func categoryGroups(
        from raw: [ModernParserBridge.DiscoverItem],
        defaultTitle: String
    ) -> [DiscoverCategoryGroup] {
        var groups: [DiscoverCategoryGroup] = []
        var title = defaultTitle
        var items: [DiscoverCardItem] = []
        var seen = Set<String>()

        func flush() {
            guard !items.isEmpty else { return }
            groups.append(DiscoverCategoryGroup(id: "\(groups.count)-\(title)", title: title, items: items))
            items = []
        }

        for item in raw where (item.type ?? "") != "select" {
            let label = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "--" else { continue }
            if let card = mapItem(item) {
                if card.isFetchable, seen.insert(card.stableKey).inserted {
                    items.append(card)
                }
            } else {
                flush()
                // A label that is only a drawn line — a source's separator — names no group.
                title = label.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
                    ? label
                    : defaultTitle
            }
        }
        flush()
        return groups
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
}
