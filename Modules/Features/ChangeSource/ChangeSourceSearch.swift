import Combine
import Foundation

// MARK: - The book being looked for

/// What a 換源 search looks for, and where from: the reader's shelf book or 作品詳情's book.
struct ChangeSourceTarget: Equatable {
    var title: String
    var author: String
    /// The shelf book, when there is one: its found list is cached (`ChangeSourceCache`) and a
    /// failed switch stays flagged across sessions. 作品詳情 has none.
    var bookId: UUID?
    /// The origin in use, left out of the list (it has its own 目前來源 row).
    var currentSourceId: UUID?
    var currentBookURL: String?
    /// The chapter being read, re-located in each result's TOC for 加載字數 (Legado reads the
    /// chapter `getDurChapter` finds there; outside the reader it reads the last one).
    var readingChapter: ReadingChapter?
    /// The kind of book it is: an origin of another kind asks before switching.
    var kind: OnlineBookContentKind = .text

    struct ReadingChapter: Equatable {
        var index: Int
        var title: String?
        var count: Int
    }

    var currentOriginKey: String? {
        currentSourceId.map { ChangeSourceCache.originKey(sourceId: $0, bookUrl: currentBookURL) }
    }
}

// MARK: - What enrichment found for one origin

/// 加載詳情／換源時載入目錄／加載字數's findings for one origin, kept beside it rather than in a
/// new `BookOrigin` (each instance gets a fresh `id`, and rows would lose their identity).
struct ChangeSourceProbe: Equatable, Sendable {
    /// The detail page's latest chapter (加載詳情), when it named one.
    var detailLastChapter: String?
    /// The TOC address the detail page gave a result that had none.
    var tocURL: String?
    var runtimeVariables: [String: String]?
    /// 加載字數: the chapter read in this origin's TOC (0-based), its title and length.
    var chapterIndex: Int?
    var chapterTitle: String?
    /// Characters in the chapter, or -1 when it could not be read (`failure` says why).
    var wordCount: Int?
    /// How long the chapter took to fetch, in milliseconds.
    var respondMs: Int?
    var failure: String?
}

// MARK: - Ranking

/// The order of a 換源 list (Legado `ChangeBookSourceViewModel`'s comparators), as a pure
/// function so it can be tested.
enum ChangeSourceRanking {
    struct Candidate {
        let origin: BookOrigin
        let arrival: Int
        let isFailed: Bool
        let bookScore: Int
        let sourceScore: Int
        let pin: SourcePinPosition?
        let responseKey: Double
        let probe: ChangeSourceProbe?
    }

    /// A switch that failed sinks to the bottom; then 👍 before 👎 (the book's score, then the
    /// source's sum over its books); then 置頂 / 置底; then — with 加載字數 — a real chapter
    /// (over 1000 characters) first, the further its index the better, then the longer;
    /// otherwise the fastest source; and arrival order last.
    static func ordered(_ candidates: [Candidate], byWordCount: Bool) -> [BookOrigin] {
        candidates.sorted { a, b in
            if a.isFailed != b.isFailed { return !a.isFailed }
            if a.bookScore != b.bookScore { return a.bookScore > b.bookScore }
            if a.sourceScore != b.sourceScore { return a.sourceScore > b.sourceScore }
            let aPin = pinRank(a.pin), bPin = pinRank(b.pin)
            if aPin != bPin { return aPin < bPin }
            if byWordCount {
                let aCount = a.probe?.wordCount ?? -1, bCount = b.probe?.wordCount ?? -1
                let aReal = aCount > 1000, bReal = bCount > 1000
                if aReal != bReal { return aReal }
                let aIndex = a.probe?.chapterIndex ?? -1, bIndex = b.probe?.chapterIndex ?? -1
                if aIndex != bIndex { return aIndex > bIndex }
                if aCount != bCount { return aCount > bCount }
            }
            if a.responseKey != b.responseKey { return a.responseKey < b.responseKey }
            return a.arrival < b.arrival
        }.map(\.origin)
    }

    /// 篩選: the source's name or the latest chapter contains the text.
    static func matches(sourceName: String, lastChapter: String, filter: String) -> Bool {
        let key = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }
        return sourceName.localizedCaseInsensitiveContains(key)
            || lastChapter.localizedCaseInsensitiveContains(key)
    }

    private static func pinRank(_ pin: SourcePinPosition?) -> Int {
        switch pin {
        case .top: 0
        case nil: 1
        case .bottom: 2
        }
    }
}

// MARK: - 👍 / 👎

/// Legado `SourceConfig`'s book scores: each (來源配置, book) is liked (1), disliked (-1) or
/// neither, and a source's own score is the sum over its books. Device-local, as there.
@MainActor
final class ChangeSourceScores {
    static let shared = ChangeSourceScores(defaults: .standard)

    private let defaults: UserDefaults
    private let key: String
    private var scores: [String: Int]

    init(defaults: UserDefaults, key: String = "yd_change_source_scores") {
        self.defaults = defaults
        self.key = key
        scores = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    func bookScore(sourceId: UUID, name: String, author: String) -> Int {
        scores[Self.bookKey(sourceId, name, author)] ?? 0
    }

    func sourceScore(sourceId: UUID) -> Int {
        scores[sourceId.uuidString] ?? 0
    }

    /// Sets the book's score (clamped to -1…1) and moves the source's sum by the difference.
    func setBookScore(_ score: Int, sourceId: UUID, name: String, author: String) {
        let clamped = max(-1, min(1, score))
        let bookKey = Self.bookKey(sourceId, name, author)
        let previous = scores[bookKey] ?? 0
        guard clamped != previous else { return }
        scores[sourceId.uuidString, default: 0] += clamped - previous
        scores[bookKey] = clamped == 0 ? nil : clamped
        defaults.set(scores, forKey: key)
    }

    /// Forgets a deleted source's scores (Legado `SourceConfig.removeSource`).
    func removeSource(_ sourceId: UUID) {
        let prefix = sourceId.uuidString
        scores = scores.filter { !$0.key.hasPrefix(prefix) }
        defaults.set(scores, forKey: key)
    }

    private static func bookKey(_ sourceId: UUID, _ name: String, _ author: String) -> String {
        "\(sourceId.uuidString)_\(name.trimmingCharacters(in: .whitespacesAndNewlines))_\(author.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - 分組

enum ChangeSourceScope {
    /// The groups among enabled sources, in the order they first appear (a source may be in
    /// several, comma-separated, as Legado writes them).
    static func groups(of sources: [BookSource]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for source in sources where source.enabled {
            for name in DiscoverViewModel.groupNames(of: source) where seen.insert(name).inserted {
                order.append(name)
            }
        }
        return order
    }

    /// The enabled sources in `group`; every enabled one for the empty group.
    static func sources(_ enabled: [BookSource], in group: String) -> [BookSource] {
        guard !group.isEmpty else { return enabled }
        return enabled.filter { DiscoverViewModel.groupNames(of: $0).contains(group) }
    }
}

// MARK: - Another source's chapter, read without keeping it

enum OtherSourceChapter {
    /// One chapter of an origin's copy, read the way the reader reads chapters, under a
    /// throwaway book id that is cleared afterwards — the same as 校驗來源配置's content probe
    /// (`BookSourceHealthChecker.probeContent`), so nothing is left in any book's cache.
    static func package(
        of ref: OnlineChapterRef, toc: TOCPackage, source: BookSource
    ) async throws -> ChapterPackage {
        let scratch = UUID()
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: scratch) }
        return try await BookSourceFetcher.shared.fetchChapterPackage(
            ref: ref, bookId: scratch, source: source, chapterReferer: toc.tocURL
        )
    }

    /// 單章換源 (Legado `ChangeChapterSourceDialog`): `ref`, another origin's chapter, becomes
    /// chapter `chapterIndex` of the book `bookId`. It is saved under the book's own stamp for
    /// that chapter (`own`'s URL and 目錄 title), which is what the reader's cache check
    /// compares, so the reader takes it as that chapter's text; refetching the chapter
    /// (刷新) brings the book's own text back.
    static func replace(
        chapterIndex: Int,
        ofBook bookId: UUID,
        own: OnlineChapterRef,
        with ref: OnlineChapterRef,
        toc: TOCPackage,
        source: BookSource,
        storeNormalizedHTML: Bool
    ) async throws {
        let fetched = try await package(of: ref, toc: toc, source: source)
        guard !fetched.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLogger.parse("⟐ changeChapterSource empty content", context: [
                "source": toc.sourceName,
                "chapter": ref.title,
            ])
            throw NSError(
                domain: "ChangeSourceSearch", code: -3,
                userInfo: [NSLocalizedDescriptionKey: localized("這一章取不到內容")])
        }
        // Walked away while it fetched: leave the book's own text in place. Past this point
        // the text is replaced, and the caller always shows it.
        try Task.checkCancellation()
        let fetcher = BookSourceFetcher.shared
        fetcher.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
        _ = try fetcher.saveToCache(
            content: fetched.content,
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: own.url,
            tocTitle: own.title,
            storeNormalizedHTML: storeNormalizedHTML
        )
    }

    /// Characters a chapter's text holds, white space aside.
    static func wordCount(of content: String) -> Int {
        content.unicodeScalars.reduce(0) { count, scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? count : count + 1
        }
    }
}

// MARK: - The search

/// One 換源 list, for the reader and 作品詳情 alike: the cross-source fan-out
/// (`BookOriginSearchService`), its 分組 scope, 校驗作者, progress and 停止, the per-origin
/// 加載詳情／載入目錄／加載字數, 👍/👎, and what a long press does to a source.
///
/// Legado keeps all of this in `ChangeBookSourceViewModel`; the two screens only decide what
/// a tapped origin does.
@MainActor
final class ChangeSourceSearch: ObservableObject {
    struct Progress: Equatable {
        var finished = 0
        var total = 0
    }

    /// Every origin found, in arrival order.
    @Published private(set) var origins: [BookOrigin] = []
    /// `origins` in list order (`ChangeSourceRanking`), before 篩選.
    @Published private(set) var ranked: [BookOrigin] = []
    @Published private(set) var isSearching = false
    @Published private(set) var progress = Progress()
    @Published private(set) var error: String?
    /// Source-qualified keys (and legacy URL keys) of origins that failed to switch.
    @Published private(set) var failedKeys: Set<String> = []
    @Published private(set) var probes: [String: ChangeSourceProbe] = [:]
    /// Origin keys 加載字數 / 載入目錄 is working on, for the row's spinner.
    @Published private(set) var probing: Set<String> = []
    /// 篩選.
    @Published var filterText = ""
    /// Set when a search scoped to a group found nothing: Legado offers to search every group.
    @Published var emptyGroupPrompt: String?
    /// 編輯來源配置 from a long press: the source the editor is open on.
    @Published var editingSource: BookSource?
    /// A tapped origin of another kind than the book, waiting for 「是否確認換源」.
    @Published var kindMismatchOrigin: BookOrigin?

    private(set) var target: ChangeSourceTarget?
    /// The sources `start` was handed, when not the store's enabled ones.
    private var sourcesOverride: [BookSource]?
    private var matchesAuthorOverride: Bool?
    let fetcher: BookSourceFetching
    private let scores: ChangeSourceScores
    private let sourceStore: BookSourceStore

    private var searchTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    private var enrichQueue: [String] = []
    /// The deepest enrichment each origin key has had.
    private var enrichedLevel: [String: EnrichLevel] = [:]
    /// Waiting `nextOrigins` streams (auto change source), fed as origins arrive.
    private var arrivalContinuations: [UUID: AsyncStream<BookOrigin>.Continuation] = [:]

    /// TOCs fetched while searching (Legado's `tocMap`), so tapping one switches without
    /// fetching it again. Capped like Legado's, at 30 000 chapters in all.
    private var tocCache: [String: TOCPackage] = [:]
    private var tocCacheChapterCount = 0
    private static let tocCacheChapterLimit = 30_000
    private static let enrichmentWidth = 4

    init(
        fetcher: BookSourceFetching,
        scores: ChangeSourceScores? = nil,
        sourceStore: BookSourceStore = .shared
    ) {
        self.fetcher = fetcher
        self.scores = scores ?? .shared
        self.sourceStore = sourceStore
    }

    // MARK: Options (網路設定 and the sheet's menu share them)

    var group: String { GlobalSettings.shared.changeSourceGroup }
    var checkAuthor: Bool { GlobalSettings.shared.changeSourceCheckAuthor }
    var loadInfo: Bool { GlobalSettings.shared.changeSourceLoadInfo }
    var loadToc: Bool { GlobalSettings.shared.changeSourceLoadToc }
    var loadWordCount: Bool { GlobalSettings.shared.changeSourceLoadWordCount }

    /// The groups the 分組 menu offers.
    var availableGroups: [String] { ChangeSourceScope.groups(of: sourceStore.sources) }

    func setGroup(_ group: String) {
        guard group != self.group else { return }
        GlobalSettings.shared.changeSourceGroup = group
        objectWillChange.send()
        restart()
    }

    /// 校驗作者 decides which results count, so the list is searched again (Legado restarts too).
    func setCheckAuthor(_ on: Bool) {
        guard on != checkAuthor else { return }
        GlobalSettings.shared.changeSourceCheckAuthor = on
        matchesAuthorOverride = nil
        objectWillChange.send()
        restart()
    }

    func setLoadInfo(_ on: Bool) {
        GlobalSettings.shared.changeSourceLoadInfo = on
        optionsDeepened()
    }

    func setLoadToc(_ on: Bool) {
        GlobalSettings.shared.changeSourceLoadToc = on
        optionsDeepened()
    }

    /// Turning 加載字數 on counts the origins already found (Legado `onLoadWordCountChecked`).
    func setLoadWordCount(_ on: Bool) {
        GlobalSettings.shared.changeSourceLoadWordCount = on
        optionsDeepened()
        rerank()
    }

    private func optionsDeepened() {
        objectWillChange.send()
        for origin in origins { enqueueEnrichment(origin) }
    }

    // MARK: Searching

    /// The list as shown: ranked, then 篩選.
    var displayedOrigins: [BookOrigin] {
        let filter = filterText
        guard !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ranked }
        return ranked.filter {
            ChangeSourceRanking.matches(sourceName: $0.sourceName, lastChapter: lastChapter(of: $0), filter: filter)
        }
    }

    /// Searches for `target`. Unless `forceRefresh`, a fresh cached list for the shelf book is
    /// reused (網路設定 →「搜索結果快取天數」) instead of searching every source again.
    ///
    /// - Parameter sources: the sources to search, before 分組; the store's enabled ones by default.
    /// - Parameter matchesAuthor: overrides 校驗作者 for this search; 自動換源 always compares
    ///   the author, as Legado's `preciseSearchAwait`.
    func start(
        _ target: ChangeSourceTarget,
        sources: [BookSource]? = nil,
        matchesAuthor: Bool? = nil,
        forceRefresh: Bool = false
    ) {
        if target != self.target {
            resetForNewTarget()
        }
        self.target = target
        self.sourcesOverride = sources
        self.matchesAuthorOverride = matchesAuthor
        start(forceRefresh: forceRefresh)
    }

    /// 停止 / 刷新: Legado's start-stop button.
    func toggleSearch() {
        if isSearching { stop() } else { restart() }
    }

    /// Searches again from scratch (刷新, or an option that changes what counts).
    func restart() {
        start(forceRefresh: true)
    }

    private func start(forceRefresh: Bool) {
        guard let target else { return }
        searchTask?.cancel()
        enrichTask?.cancel()
        enrichTask = nil
        enrichQueue.removeAll()
        probing.removeAll()
        emptyGroupPrompt = nil
        error = nil

        if !forceRefresh, let bookId = target.bookId,
           let cached = ChangeSourceCache.shared.freshEntry(for: bookId, days: GlobalSettings.shared.searchCacheDays) {
            // A source deleted or disabled since the list was saved (here, or in 來源配置管理)
            // has nothing to switch to any more.
            let searchable = Set((sourcesOverride ?? sourceStore.enabledSources).map(\.id))
            origins = cached.origins.filter { searchable.contains($0.sourceId) }
            failedKeys = Set(cached.failedKeys)
            isSearching = false
            progress = Progress()
            rerank()
            for origin in origins { enqueueEnrichment(origin) }
            finishArrivals()
            return
        }

        origins = []
        ranked = []
        probes = [:]
        enrichedLevel = [:]
        // Keep prior failure flags across a re-search so a known-bad source stays marked.
        failedKeys = target.bookId.flatMap { Set(ChangeSourceCache.shared.entry(for: $0)?.failedKeys ?? []) } ?? []

        let enabled = sourcesOverride ?? sourceStore.enabledSources
        var group = self.group
        var sources = ChangeSourceScope.sources(enabled, in: group)
        if sources.isEmpty, !group.isEmpty {
            // Legado's startSearch: a group with no enabled source left falls back to all.
            GlobalSettings.shared.changeSourceGroup = ""
            group = ""
            sources = enabled
        }
        let concurrency = NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency)
        let autoPausePolicy = SearchAutoPausePolicy.configured
        let matchesAuthor = matchesAuthorOverride ?? checkAuthor
        let excluding = target.currentOriginKey
        let bookId = target.bookId
        progress = Progress(finished: 0, total: sources.count)
        isSearching = true

        searchTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let outcome = await BookOriginSearchService.stream(
                title: target.title,
                author: target.author,
                sources: sources,
                concurrency: concurrency,
                fetcher: self.fetcher,
                excludingOriginKey: excluding,
                matchesAuthor: matchesAuthor,
                shouldStop: { autoPausePolicy.shouldPause(exactCount: $0, fuzzyCount: 0) },
                onSourceFinished: { [weak self] in self?.progress.finished += 1 },
                onBatch: { [weak self] batch in self?.receive(batch) }
            )
            guard !Task.isCancelled else { return }
            self.isSearching = false
            self.rerank()
            SourcePerfTrace.record("changeSource.search", "\(self.origins.count)/\(sources.count)", since: startedAt)
            if let bookId {
                // A list cut short by 自動暫停 is stored as partial: reopening searches again
                // instead of serving it as everything the sources have (feedback #16).
                ChangeSourceCache.shared.store(origins: self.ranked, for: bookId, isComplete: outcome == .completed)
            }
            if self.origins.isEmpty, !group.isEmpty, outcome == .completed {
                self.emptyGroupPrompt = group
            }
            self.finishArrivals()
        }
    }

    /// Stops the fan-out and the per-origin work. Called the moment an origin is tapped: from
    /// then on the search competes with the one fetch the user waits on (Legado's `getToc`
    /// opens with `stopSearch()`).
    func stop() {
        searchTask?.cancel()
        searchTask = nil
        enrichTask?.cancel()
        enrichTask = nil
        enrichQueue.removeAll()
        probing.removeAll()
        isSearching = false
        finishArrivals()
    }

    /// Legado's 搜索結果為空 prompt: search every group instead.
    func searchAllGroups() {
        emptyGroupPrompt = nil
        setGroup("")
    }

    private func receive(_ batch: [BookOrigin]) {
        origins.append(contentsOf: batch)
        rerank()
        for origin in batch {
            enqueueEnrichment(origin)
            for continuation in arrivalContinuations.values { continuation.yield(origin) }
        }
    }

    private func resetForNewTarget() {
        stop()
        origins = []
        ranked = []
        probes = [:]
        enrichedLevel = [:]
        failedKeys = []
        tocCache = [:]
        tocCacheChapterCount = 0
        filterText = ""
        progress = Progress()
    }

    // MARK: Ranking

    func rerank() {
        let failed = failedKeys
        let health = SourceHealthStore.shared
        let title = target?.title ?? ""
        let author = target?.author ?? ""
        let candidates = origins.enumerated().map { offset, origin in
            ChangeSourceRanking.Candidate(
                origin: origin,
                arrival: offset,
                isFailed: Self.isFailed(origin, in: failed),
                bookScore: scores.bookScore(sourceId: origin.sourceId, name: title, author: author),
                sourceScore: scores.sourceScore(sourceId: origin.sourceId),
                pin: sourceStore.pinRecord(for: origin.sourceId)?.position,
                responseKey: health.responseSortKey(origin.sourceId),
                probe: probes[Self.key(origin)]
            )
        }
        ranked = ChangeSourceRanking.ordered(candidates, byWordCount: loadWordCount)
    }

    static func key(_ origin: BookOrigin) -> String {
        ChangeSourceCache.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl)
    }

    private static func isFailed(_ origin: BookOrigin, in failed: Set<String>) -> Bool {
        failed.contains(key(origin)) || failed.contains(ChangeSourceCache.urlKey(origin.bookUrl))
    }

    func isFailed(_ origin: BookOrigin) -> Bool { Self.isFailed(origin, in: failedKeys) }

    /// The row's latest chapter: the detail page's when 加載詳情 read one.
    func lastChapter(of origin: BookOrigin) -> String {
        let detail = probes[Self.key(origin)]?.detailLastChapter?.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail?.isEmpty == false ? detail! : origin.lastChapter
    }

    // MARK: Failures

    /// Flags an origin whose switch failed, persisting the flag for the shelf book.
    func markFailed(_ origin: BookOrigin) {
        markFailed(sourceId: origin.sourceId, bookUrl: origin.bookUrl, bookId: target?.bookId)
    }

    func markFailed(sourceId: UUID, bookUrl: String, bookId: UUID?) {
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: bookUrl)
        guard !key.isEmpty else { return }
        failedKeys.insert(key)
        if let bookId {
            ChangeSourceCache.shared.markFailed(originKey: key, for: bookId)
        }
        rerank()
    }

    /// Drops an origin's flag once it switched: `markFailed` persists, so without this a source
    /// that failed once stayed badged 載入失敗 for good.
    func clearFailure(_ origin: BookOrigin) {
        clearFailure(sourceId: origin.sourceId, bookUrl: origin.bookUrl, bookId: target?.bookId)
    }

    func clearFailure(sourceId: UUID, bookUrl: String, bookId: UUID?) {
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: bookUrl)
        let legacyKey = ChangeSourceCache.urlKey(bookUrl)
        guard !key.isEmpty else { return }
        failedKeys.remove(key)
        failedKeys.remove(legacyKey)
        if let bookId {
            ChangeSourceCache.shared.clearFailure(originKeys: [key, legacyKey], for: bookId)
        }
        rerank()
    }

    func reportError(_ message: String?) {
        error = message
    }

    // MARK: 👍 / 👎

    func bookScore(of origin: BookOrigin) -> Int {
        scores.bookScore(sourceId: origin.sourceId, name: target?.title ?? "", author: target?.author ?? "")
    }

    func setBookScore(_ score: Int, for origin: BookOrigin) {
        scores.setBookScore(score, sourceId: origin.sourceId, name: target?.title ?? "", author: target?.author ?? "")
        rerank()
    }

    // MARK: Long press (Legado change_source_item.xml)

    func pinToTop(sourceId: UUID) {
        sourceStore.pinToTop(id: sourceId)
        rerank()
    }

    func pinToBottom(sourceId: UUID) {
        sourceStore.pinToBottom(id: sourceId)
        rerank()
    }

    /// 停用: the source leaves the search, and its results leave the list. A book reading from
    /// it keeps reading: a disabled source still loads chapters.
    func disableSource(id sourceId: UUID) {
        sourceStore.setEnabledByUser(ids: [sourceId], enabled: false)
        sourcesOverride?.removeAll { $0.id == sourceId }
        removeOrigins(of: sourceId)
    }

    /// 編輯來源配置 was saved: the edit is stored, and the source searched again on its own.
    func saveEditedSource(_ source: BookSource) {
        sourceStore.update(source)
        researchSource(source.id)
    }

    /// 刪除: the source is deleted, with its scores.
    func deleteSource(id sourceId: UUID) {
        _ = sourceStore.delete(id: sourceId)
        scores.removeSource(sourceId)
        sourcesOverride?.removeAll { $0.id == sourceId }
        removeOrigins(of: sourceId)
    }

    /// After 編輯來源配置 is saved, that source is searched again on its own (Legado's
    /// `startSearch(origin)`); its old results go.
    func researchSource(_ sourceId: UUID) {
        guard let target, let source = sourceStore.source(id: sourceId), source.enabled else {
            removeOrigins(of: sourceId)
            return
        }
        removeOrigins(of: sourceId)
        let matchesAuthor = matchesAuthorOverride ?? checkAuthor
        let excluding = target.currentOriginKey
        Task { [weak self] in
            guard let self else { return }
            await BookOriginSearchService.stream(
                title: target.title,
                author: target.author,
                sources: [source],
                concurrency: 1,
                fetcher: self.fetcher,
                excludingOriginKey: excluding,
                matchesAuthor: matchesAuthor,
                onBatch: { [weak self] batch in self?.receive(batch) }
            )
        }
    }

    private func removeOrigins(of sourceId: UUID) {
        let removed = origins.filter { $0.sourceId == sourceId }.map(Self.key)
        origins.removeAll { $0.sourceId == sourceId }
        for key in removed {
            probes[key] = nil
            enrichedLevel[key] = nil
            tocCache[key] = nil
        }
        enrichQueue.removeAll { removed.contains($0) }
        rerank()
    }

    // MARK: TOC

    /// Legado `ChangeBookSourceViewModel.getToc`: the search-phase TOC first, the network only
    /// on a miss. The package is handed to the commit, so a switch fetches its TOC once.
    func prepareTOCPackage(for origin: BookOrigin) async throws -> TOCPackage {
        let key = Self.key(origin)
        if let cached = tocCache[key] {
            return cached
        }
        guard let source = sourceStore.source(id: origin.sourceId) else {
            throw NSError(
                domain: "ChangeSourceSearch", code: -1,
                userInfo: [NSLocalizedDescriptionKey: localized("找不到來源配置")])
        }
        let (tocURL, runtimeVariables, detailPage) = try await resolvedTOCAddress(of: origin, source: source)
        let package = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: nil,
            forceRefresh: false,
            detailPage: detailPage
        )
        // An empty TOC means this source's rules matched nothing. Fail here, before the
        // commit: the sheet stays open, the origin gets flagged, and the book keeps the
        // source it already had. Committing an empty list left the book with no chapters
        // at all — see the same guard in `BookStore.updateOnlineBookSource`.
        guard !package.chapters.isEmpty else {
            AppLogger.parse("⟐ changeSource empty TOC", context: [
                "source": origin.sourceName,
                // The RESOLVED url, not `origin.tocUrl` — that one is empty for most
                // sources and would make every one of these log lines look identical.
                "tocUrl": String(tocURL.prefix(120)),
                "fromDetailPage": origin.tocUrl.isEmpty,
            ])
            throw NSError(
                domain: "ChangeSourceSearch", code: -2,
                userInfo: [NSLocalizedDescriptionKey: localized("此來源配置取不到目錄")])
        }
        cacheTOC(package, forKey: key)
        return package
    }

    /// A search result almost never carries a tocUrl: it belongs to the book's DETAIL page,
    /// so `parseSearchResults` leaves it empty on purpose (an empty rule would otherwise
    /// resolve to the site root and the homepage would be scraped as a TOC — see the guard in
    /// `ModernParserBridge.parseBookInfo`). Legado closes the same gap in `getToc`:
    ///
    ///     if (book.tocUrl.isEmpty()) { WebBook.getBookInfoAwait(source, book) }
    ///
    /// Same here — the detail page only when the TOC address is missing, its runtime variables
    /// carried forward, because that request is what a source's bookInfo JS uses to stash
    /// chapter-list state. What it found is kept (`probes`), so 加載詳情 and a later tap
    /// don't read the detail page again.
    ///
    /// The detail page itself comes back only when this call read it: a TOC at the book's own
    /// URL is then read from it (Legado's `tocHtml`). `probes` keeps the address, not the page,
    /// so a TOC resolved from an earlier probe is fetched.
    private func resolvedTOCAddress(
        of origin: BookOrigin, source: BookSource
    ) async throws -> (String, [String: String]?, BookDetailPage?) {
        let key = Self.key(origin)
        let tocURL = origin.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tocURL.isEmpty { return (tocURL, origin.runtimeVariables, nil) }
        if let probe = probes[key], let known = probe.tocURL, !known.isEmpty {
            return (known, probe.runtimeVariables ?? origin.runtimeVariables, nil)
        }
        // name/author are deliberately empty: `BookOrigin` carries none of the book's identity
        // (it lives on the shelf book), and this path only resolves a missing tocUrl — a
        // switch must never rename the book being read.
        let knownBook = OnlineBook(
            name: "",
            author: "",
            intro: origin.intro,
            coverUrl: origin.coverUrl,
            bookUrl: origin.bookUrl,
            tocUrl: origin.tocUrl,
            wordCount: origin.wordCount,
            lastChapter: origin.lastChapter,
            kind: origin.kind,
            sourceId: origin.sourceId,
            sourceName: origin.sourceName,
            runtimeVariables: origin.runtimeVariables
        )
        let info = try await fetcher.fetchBookInfoPackage(
            url: origin.bookUrl,
            source: source,
            runtimeVariables: origin.runtimeVariables,
            knownBook: knownBook
        )
        var probe = probes[key] ?? ChangeSourceProbe()
        probe.tocURL = info.tocUrl
        probe.runtimeVariables = info.runtimeVariables ?? origin.runtimeVariables
        let detailLast = info.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detailLast.isEmpty { probe.detailLastChapter = detailLast }
        probes[key] = probe
        return (info.tocUrl, probe.runtimeVariables, info.onlineBook.detailPage)
    }

    private func cacheTOC(_ package: TOCPackage, forKey key: String) {
        // Never cache an empty TOC: `prepareTOCPackage` returns cache hits verbatim, so one
        // stored here would slip past its empty-TOC guard on every later tap.
        guard !package.chapters.isEmpty else { return }
        guard !key.isEmpty, tocCache[key] == nil else { return }
        guard tocCacheChapterCount < Self.tocCacheChapterLimit else { return }
        tocCacheChapterCount += package.chapters.count
        tocCache[key] = package
    }

    // MARK: 加載詳情／換源時載入目錄／加載字數

    private enum EnrichLevel: Int, Comparable {
        case none, info, toc, wordCount
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var wantedLevel: EnrichLevel {
        if loadWordCount { return .wordCount }
        if loadToc { return .toc }
        if loadInfo { return .info }
        return .none
    }

    /// Queues the per-origin work the options ask for. Legado does it inline in each source's
    /// search; here one bounded queue (4 at a time) runs beside the fan-out, so results appear
    /// as fast as before and the details fill in. Failed origins are left alone.
    private func enqueueEnrichment(_ origin: BookOrigin) {
        let key = Self.key(origin)
        guard !key.isEmpty, wantedLevel > (enrichedLevel[key] ?? .none),
              !isFailed(origin), !enrichQueue.contains(key), !probing.contains(key) else { return }
        enrichQueue.append(key)
        guard enrichTask == nil else { return }
        enrichTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.drainEnrichment()
                // Checked and cleared with no suspension in between, so an origin queued after
                // the drain finished starts a new one instead of waiting forever.
                if self.enrichQueue.isEmpty || Task.isCancelled { break }
            }
            self?.enrichTask = nil
        }
    }

    private func drainEnrichment() async {
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            while true {
                while active < Self.enrichmentWidth, !enrichQueue.isEmpty {
                    let key = enrichQueue.removeFirst()
                    guard let origin = origins.first(where: { Self.key($0) == key }) else { continue }
                    active += 1
                    probing.insert(key)
                    group.addTask { [weak self] in await self?.enrich(origin) }
                }
                guard active > 0 else { break }
                await group.next()
                active -= 1
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
            }
        }
    }

    private func enrich(_ origin: BookOrigin) async {
        let key = Self.key(origin)
        let level = wantedLevel
        defer { probing.remove(key) }
        guard let source = sourceStore.source(id: origin.sourceId) else { return }
        do {
            if level >= .info, origin.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await resolvedTOCAddress(of: origin, source: source)
                try Task.checkCancellation()
                enrichedLevel[key] = .info
            }
            guard level >= .toc else { return }
            let toc = try await prepareTOCPackage(for: origin)
            try Task.checkCancellation()
            enrichedLevel[key] = .toc
            guard level >= .wordCount else { return }
            try await countWords(of: origin, toc: toc, source: source)
            enrichedLevel[key] = .wordCount
            if loadWordCount { rerank() }
        } catch is CancellationError {
            // Stopped: not a finding about the source.
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.network("⟐ changeSource probe failed", error: error,
                              context: ["source": origin.sourceName, "level": "\(level.rawValue)"])
            var probe = probes[key] ?? ChangeSourceProbe()
            probe.failure = error.localizedDescription
            if level >= .wordCount, probe.wordCount == nil { probe.wordCount = -1 }
            probes[key] = probe
            enrichedLevel[key] = level
            if loadWordCount { rerank() }
        }
    }

    /// Legado `loadBookWordCount`: the chapter being read, found in this origin's TOC, or its
    /// last chapter outside the reader; its length and how long it took.
    private func countWords(of origin: BookOrigin, toc: TOCPackage, source: BookSource) async throws {
        let key = Self.key(origin)
        let chapters = toc.chapters
        let index: Int
        if let reading = target?.readingChapter {
            index = min(chapters.count - 1, ChapterAlignment.alignedIndex(
                oldIndex: reading.index, oldTitle: reading.title, oldCount: reading.count,
                newTitles: chapters.map(\.title)))
        } else {
            index = chapters.count - 1
        }
        let ref = chapters[index]
        let startedAt = ProcessInfo.processInfo.systemUptime
        var probe = probes[key] ?? ChangeSourceProbe()
        probe.chapterIndex = index
        probe.chapterTitle = ref.title
        do {
            let package = try await OtherSourceChapter.package(of: ref, toc: toc, source: source)
            try Task.checkCancellation()
            probe.wordCount = OtherSourceChapter.wordCount(of: package.content)
            probe.failure = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.network("⟐ changeSource word count failed", error: error,
                              context: ["source": origin.sourceName, "chapter": ref.title])
            probe.wordCount = -1
            probe.failure = error.localizedDescription
        }
        probe.respondMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        probes[key] = probe
    }

    // MARK: The first origin that loads

    /// Legado `autoChangeSource`: the origins of `kind`, in list order and then as they
    /// arrive, until one's TOC loads — that one, with its TOC. Nil once the search has ended
    /// with none. Used when the book's 來源配置 is gone: on opening, and after 刪除 of the one
    /// in use.
    func firstLoadable(kind: OnlineBookContentKind, excluding excludedSourceId: UUID? = nil) async -> (BookOrigin, TOCPackage)? {
        var tried = Set<String>()
        func attempt(_ origin: BookOrigin) async -> TOCPackage? {
            let key = Self.key(origin)
            guard origin.sourceId != excludedSourceId, !isFailed(origin), tried.insert(key).inserted,
                  origin.inferredContentKind() == kind else { return nil }
            do {
                return try await prepareTOCPackage(for: origin)
            } catch {
                guard !(error is CancellationError) else { return nil }
                AppLogger.network("⟐ auto change source candidate failed", error: error,
                                  context: ["source": origin.sourceName])
                markFailed(origin)
                return nil
            }
        }
        // Subscribed before the existing list is tried, so nothing that arrives meanwhile is missed.
        let arrivals = isSearching ? nextOrigins() : nil
        for origin in ranked {
            if Task.isCancelled { return nil }
            if let toc = await attempt(origin) { return (origin, toc) }
        }
        guard let arrivals else { return nil }
        for await origin in arrivals {
            if Task.isCancelled { return nil }
            if let toc = await attempt(origin) { return (origin, toc) }
        }
        return nil
    }

    /// The origins found from now on, ending with the search.
    private func nextOrigins() -> AsyncStream<BookOrigin> {
        let id = UUID()
        return AsyncStream { continuation in
            arrivalContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.arrivalContinuations[id] = nil }
            }
        }
    }

    private func finishArrivals() {
        let continuations = arrivalContinuations.values
        arrivalContinuations.removeAll()
        for continuation in continuations { continuation.finish() }
    }
}

// MARK: - Previews

#if DEBUG
extension ChangeSourceSearch {
    /// A list seeded with found origins and probes, for `#Preview`s — no network.
    static func preview(
        origins: [BookOrigin],
        probes: [String: ChangeSourceProbe] = [:],
        searching: Bool = false,
        progress: Progress = Progress()
    ) -> ChangeSourceSearch {
        let search = ChangeSourceSearch(fetcher: AppDependencies.live.bookSourceFetcher,
                                        scores: ChangeSourceScores(defaults: UserDefaults(suiteName: "preview.changeSource")!))
        search.target = ChangeSourceTarget(title: "斗羅大陸", author: "唐家三少")
        search.origins = origins
        search.probes = probes
        search.isSearching = searching
        search.progress = progress
        search.rerank()
        return search
    }

    static func previewOrigin(_ name: String, last: String = "第 1450 章 終章", kind: String = "") -> BookOrigin {
        BookOrigin(
            sourceId: UUID(), sourceName: name, bookUrl: "https://example.com/\(name)", tocUrl: "",
            coverUrl: "", intro: "", lastChapter: last, wordCount: "", kind: kind, runtimeVariables: nil,
            author: "唐家三少"
        )
    }
}
#endif
