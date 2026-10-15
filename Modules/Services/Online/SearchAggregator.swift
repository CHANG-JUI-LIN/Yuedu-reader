import Combine
import Foundation

// MARK: - Book Origin (link info provided by a single book source)

struct BookOrigin: Identifiable, Codable, Sendable {
    let id = UUID()
    let sourceId: UUID
    let sourceName: String
    let bookUrl: String
    let tocUrl: String
    let coverUrl: String
    let intro: String
    let lastChapter: String
    let wordCount: String
    let kind: String
    let runtimeVariables: [String: String]?

    // `id` is a fresh UUID per instance and is intentionally excluded so cached
    // origins (換源 results) round-trip without persisting a meaningless identity.
    private enum CodingKeys: String, CodingKey {
        case sourceId, sourceName, bookUrl, tocUrl, coverUrl, intro
        case lastChapter, wordCount, kind, runtimeVariables
    }
}

extension BookOrigin {
    func inferredContentKind(sourceStore: BookSourceStore = .shared) -> OnlineBookContentKind {
        let source = sourceStore.source(id: sourceId)
        return OnlineBookContentInference.infer(
            sourceType: source?.bookSourceType,
            runtimeVariables: runtimeVariables,
            urls: [bookUrl, tocUrl],
            metadataText: [kind, intro, lastChapter, sourceName]
                + OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        )
    }
}

// MARK: - Aggregated Search Results (merge info from multiple sources for the same book)

final class SearchBook: Identifiable {
    let id: UUID
    let name: String
    let author: String
    private(set) var origins: [BookOrigin]

    /// `normalize(name)`, derived once at construction.
    ///
    /// `normalize` runs an ICU `fullwidthToHalfwidth` transform plus three more
    /// string allocations. The sort comparator and the dedup bucketing both used to
    /// re-derive it per call — O(n log n) ICU transforms for every merged batch —
    /// which at a few thousand book sources was the most expensive thing happening
    /// on the main actor during a search.
    let normalizedName: String

    /// The row's `WorkMatchKey` keys, from the book that made it: both merge rules bucket and
    /// compare by them (`SearchMergeRule`). Nil only for a row made outside the aggregator.
    let workKeys: SearchWorkKeys?

    /// Snapshots are index-aligned with `origins`. Production search batches build
    /// them off the main actor before constructing or mutating a `SearchBook`.
    private var originPresentations: [SearchOriginPresentation]
    private var rowPresentation: RowPresentation

    private struct RowPresentation {
        let displayName: String
        let displayIntro: String
        let contentKind: OnlineBookContentKind
        let primaryIntroIndex: Int?
    }

    /// Normalized key for deduplication
    var deduplicationKey: String {
        Self.makeKey(name: name, author: author)
    }

    /// Generate dedup key: normalize fullwidth/halfwidth, strip whitespace
    static func makeKey(name: String, author: String) -> String {
        let n = normalize(name)
        let a = normalize(author)
        return "\(n)||||\(a)"
    }

    /// Normalize string: strip whitespace/punctuation, convert fullwidth to halfwidth
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic "same book" test used for 換源, 換封面 and 尋找可用來源.
    ///
    /// Titles compare by `WorkMatchKey` (unified search 4d, maintainer 2026-10-14), so
    /// 三體／三体／三體！ are one book. The folded title must be an **exact** match:
    /// containment is deliberately *not* allowed, since a substring rule matches sequels and
    /// spin-offs (e.g. "斗罗大陆" vs "斗罗大陆3" / "斗罗大陆之笔"), which would offer the wrong
    /// book as an alternative source.
    ///
    /// The author is a *soft* filter: it only excludes a candidate when BOTH sides report a
    /// non-empty author AND those authors are incompatible (`WorkMatchKey.compatible`: equal,
    /// or one contains the other — e.g. "唐家三少" vs "唐家三少著"). This keeps alternative
    /// sources discoverable even when a source omits the author (very common), which is why
    /// the previous exact `(name, author)` key match returned empty. 搜索 differs here: a
    /// result without an author is its own row there (`SearchMergeRule.work`).
    static func isLikelySameBook(
        name lhsName: String, author lhsAuthor: String,
        name rhsName: String, author rhsAuthor: String
    ) -> Bool {
        isLikelySameBook(SearchWorkKeys(name: lhsName, author: lhsAuthor),
                         SearchWorkKeys(name: rhsName, author: rhsAuthor))
    }

    /// `isLikelySameBook` over keys already folded: each fold runs ICU transforms (≈85 µs a
    /// book), so a caller comparing many books against one folds that one once.
    static func isLikelySameBook(_ lhs: SearchWorkKeys, _ rhs: SearchWorkKeys) -> Bool {
        guard !lhs.title.isEmpty, lhs.title == rhs.title else { return false }
        if lhs.author.isEmpty || rhs.author.isEmpty { return true }
        return WorkMatchKey.compatible(lhs.author, rhs.author)
    }

    /// Primary cover URL (first non-empty one)
    var coverUrl: String {
        origins.first(where: { !$0.coverUrl.isEmpty })?.coverUrl ?? ""
    }

    /// Primary intro (longest one)
    var intro: String {
        guard let index = rowPresentation.primaryIntroIndex, index < origins.count else {
            return ""
        }
        return origins[index].intro
    }

    /// Primary latest chapter
    var lastChapter: String {
        origins.first(where: { !$0.lastChapter.isEmpty })?.lastChapter ?? ""
    }

    /// Primary category
    var kind: String {
        origins.first(where: { !$0.kind.isEmpty })?.kind ?? ""
    }

    /// The source-store argument remains for source compatibility. Content kind
    /// is deliberately snapshotted when the origin arrives so detail-page JS
    /// writes cannot mutate routing for a result already shown to the user.
    func inferredContentKind(
        sourceStore _: BookSourceStore = .shared
    ) -> OnlineBookContentKind {
        rowPresentation.contentKind
    }

    func preferredOrigin(
        for kind: OnlineBookContentKind,
        sourceStore _: BookSourceStore = .shared
    ) -> BookOrigin? {
        guard let index = originPresentations.firstIndex(where: {
            $0.contentKind == kind
        }), index < origins.count else {
            return nil
        }
        return origins[index]
    }

    var displayIntro: String {
        rowPresentation.displayIntro
    }

    var detailIntro: String {
        guard
            let index = rowPresentation.primaryIntroIndex,
            index < originPresentations.count
        else {
            return ""
        }
        return originPresentations[index].detailIntro
    }

    func detailIntro(for origin: BookOrigin) -> String {
        guard
            let index = origins.firstIndex(where: { $0.id == origin.id }),
            index < originPresentations.count
        else {
            return detailIntro
        }
        return originPresentations[index].detailIntro
    }

    /// The content kind snapshotted for one origin when it arrived; `nil` for an
    /// origin that is not part of this result.
    func contentKind(for origin: BookOrigin) -> OnlineBookContentKind? {
        guard
            let index = origins.firstIndex(where: { $0.id == origin.id }),
            index < originPresentations.count
        else {
            return nil
        }
        return originPresentations[index].contentKind
    }

    var displayName: String {
        rowPresentation.displayName
    }

    init(
        id: UUID = UUID(),
        name: String,
        author: String,
        origins: [BookOrigin] = []
    ) {
        let preparedOrigins = SearchResultPresentationBuilder.prepareOrigins(
            origins,
            sourceStore: .shared
        )
        assert(preparedOrigins.count == origins.count)
        self.id = id
        self.name = name
        self.normalizedName = Self.normalize(name)
        self.workKeys = nil
        self.author = author
        self.origins = origins
        self.originPresentations = preparedOrigins.map(\.presentation)
        self.rowPresentation = Self.resolveRowPresentation(
            name: name,
            preparedOrigins: preparedOrigins
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        author: String,
        workKeys: SearchWorkKeys? = nil,
        preparedOrigins: [PreparedSearchOrigin]
    ) {
        let origins = preparedOrigins.map(\.origin)
        let presentations = preparedOrigins.map(\.presentation)
        assert(origins.count == presentations.count)
        self.id = id
        self.name = name
        self.normalizedName = Self.normalize(name)
        self.workKeys = workKeys
        self.author = author
        self.origins = origins
        self.originPresentations = presentations
        self.rowPresentation = Self.resolveRowPresentation(
            name: name,
            preparedOrigins: preparedOrigins
        )
    }

    func append(_ preparedOrigin: PreparedSearchOrigin) {
        assert(origins.count == originPresentations.count)
        let preparedOrigins = zip(origins, originPresentations).map {
            PreparedSearchOrigin(origin: $0.0, presentation: $0.1)
        } + [preparedOrigin]

        // Refresh the lightweight snapshot before the authoritative origin array.
        // The aggregator publishes the resulting row state on its bounded cadence.
        rowPresentation = Self.resolveRowPresentation(
            name: name,
            preparedOrigins: preparedOrigins
        )
        originPresentations.append(preparedOrigin.presentation)
        origins.append(preparedOrigin.origin)
        assert(origins.count == originPresentations.count)
    }

    /// Freeze the current row values for the next UI publication. The stable id
    /// lets SwiftUI diff the row in place, while later background merges mutate
    /// only the authoritative instance held by `SearchAggregator`.
    func publicationSnapshot() -> SearchBook {
        return SearchBook(
            id: id,
            name: name,
            author: author,
            workKeys: workKeys,
            origins: origins,
            originPresentations: originPresentations,
            rowPresentation: rowPresentation
        )
    }

    private init(
        id: UUID,
        name: String,
        author: String,
        workKeys: SearchWorkKeys?,
        origins: [BookOrigin],
        originPresentations: [SearchOriginPresentation],
        rowPresentation: RowPresentation
    ) {
        self.id = id
        self.name = name
        self.normalizedName = Self.normalize(name)
        self.workKeys = workKeys
        self.author = author
        self.origins = origins
        self.originPresentations = originPresentations
        self.rowPresentation = rowPresentation
    }

    private static func resolveRowPresentation(
        name: String,
        preparedOrigins: [PreparedSearchOrigin]
    ) -> RowPresentation {
        let primaryIntroIndex = preparedOrigins.indices.max { lhs, rhs in
            preparedOrigins[lhs].presentation.introCharacterCount
                < preparedOrigins[rhs].presentation.introCharacterCount
        }

        let kinds = preparedOrigins.map(\.presentation.contentKind)
        let contentKind: OnlineBookContentKind
        if kinds.contains(.audio) {
            contentKind = .audio
        } else if kinds.contains(.manga) {
            contentKind = .manga
        } else {
            contentKind = kinds.first ?? .text
        }

        let cleanedName = SearchResultPresentationBuilder.cleanDisplayTitle(name)
        let displayName: String
        if !cleanedName.isEmpty,
           !SearchResultPresentationBuilder.isOnlyListNumber(cleanedName) {
            displayName = cleanedName
        } else if let firstChapter = preparedOrigins.first(where: {
            !$0.origin.lastChapter.isEmpty
        }) {
            displayName = firstChapter.presentation.lastChapterTitleCandidate
        } else if let primaryIntroIndex,
                  !preparedOrigins[primaryIntroIndex].presentation.introTitleCandidate.isEmpty {
            displayName = preparedOrigins[primaryIntroIndex]
                .presentation.introTitleCandidate
        } else {
            displayName = name.isEmpty ? "未知書名" : cleanedName
        }

        let displayIntro = primaryIntroIndex.map {
            preparedOrigins[$0].presentation.displayIntro
        } ?? ""

        return RowPresentation(
            displayName: displayName,
            displayIntro: displayIntro,
            contentKind: contentKind,
            primaryIntroIndex: primaryIntroIndex
        )
    }
}

// MARK: - Search Aggregation Engine
//
// Core design:
// 1. TaskGroup schedules at most GlobalSettings.searchConcurrency active source tasks
// 2. Each book source independently bound to a 15s timeout; timed-out tasks are cancelled to free resources
// 3. As soon as any single source returns results, stream its visible books into the UI
// 4. Publishes result-list snapshots through a bounded scene-aware cadence

/// Where a search was started, recorded on its `search.firstResult` span so the 搜索 tab's
/// numbers are not mixed with 換源's.
enum SearchOrigin: String, Sendable {
    case searchTab
    case changeSource
}

/// How one search tells its books apart.
enum SearchMergeRule: Sendable {
    /// 搜索 (unified search 4c-1, maintainer's decision 1): `WorkMatchKey` titles, so
    /// 三體／三体／三體！ are one row; a title merges only when both sides name compatible
    /// authors (a result without one is its own row) and the content kind is the same.
    case work
    /// 換源 and 尋找可用來源 (4d, maintainer 2026-10-14): the same `WorkMatchKey` titles, but
    /// an empty author merges with any (`SearchBook.isLikelySameBook`) and kinds are not
    /// compared.
    case changeSource

    init(_ origin: SearchOrigin) {
        self = origin == .searchTab ? .work : .changeSource
    }
}

@MainActor
class SearchAggregator: ObservableObject {
    /// UI-facing result list. Updated from `internalResults` only through the
    /// scene-aware publication gate so bursts do not trigger unbounded list diffs.
    /// Merging and sorting always operate on `internalResults`.
    private(set) var results: [SearchBook] = []
    /// Bumped with every publication of `results`. A row's snapshot compares by id alone, so a
    /// row that gained origins compares equal; 搜索's one list re-reads the results by this
    /// (unified search 4c-3).
    private(set) var publicationRevision = 0
    /// The search is running: page 1, then for 搜索 the later pages (search 9e).
    @Published var isSearching = false
    /// Paused — either automatically (auto-pause threshold reached) or manually
    /// (floating pause control). Results stay on screen and `resume()` continues
    /// over the sources that had not finished.
    @Published var isPaused = false
    private(set) var progress: SearchProgress = SearchProgress()

    /// Search progress
    struct SearchProgress {
        var total: Int = 0
        var completed: Int = 0
        var failed: Int = 0
        var timedOut: Int = 0
        /// Sources skipped this search because they are in a timeout cooldown.
        var skipped: Int = 0
        /// Of `completed`, the sources whose fetch failed and that are shown as no results
        /// (Phase 0b), so a caller can tell 「沒有找到」 from a search no source answered.
        var failedAsEmpty: Int = 0

        var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(completed + failed + timedOut) / Double(total)
        }
    }

    /// Concurrency limit (max simultaneous requests) — lower reduces timeouts/failures.
    /// User-configurable via `GlobalSettings.searchConcurrency` (網路設定 → 並發數);
    /// resolved per search so changes take effect on the next search.
    private var maxConcurrency: Int {
        NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency)
    }

    /// Timeout seconds per book source. Kept tight so dead/unreachable hosts
    /// free their concurrency slot quickly (fail-fast) instead of stalling the
    /// whole search; repeat offenders are then skipped via `SourceHealthStore`.
    private let perSourceTimeout: UInt64 = 12

    /// Longer budget for JS-driven (`<js>`/`@js:`) search sources. Aggregate
    /// sources (光遇/大灰狼…) fan out to dozens of sub-sites server-side and take
    /// ~12–15s to return; the tight per-source timeout would cut them off and the
    /// search would look broken even when the cloud is aggregating correctly.
    private let perAggregateSourceTimeout: UInt64 = 30

    private func fanOut(concurrency: Int) -> BookSourceSearchFanOut {
        BookSourceSearchFanOut(
            concurrency: concurrency, timeout: perSourceTimeout, aggregateTimeout: perAggregateSourceTimeout,
            fetcher: fetcher
        )
    }

    private let fetcher: BookSourceFetcher
    private let device: SearchDeviceConditions

    init(fetcher: BookSourceFetcher = .shared, device: SearchDeviceConditions = .live) {
        self.fetcher = fetcher
        self.device = device
    }

    /// Current search task (used for cancellation)
    private var searchTask: Task<Void, Never>?

    /// Authoritative merged results. `results` mirrors this array at a throttled
    /// cadence; keeping the working copy un-published means per-book merges and
    /// per-batch sorts don't each pay a SwiftUI diff.
    private var internalResults: [SearchBook] = []
    private var internalProgress = SearchProgress()
    /// Set by a merge, consumed by the next publication — see `mergeBatch`.
    private var resultsNeedSort = false

    /// Single publication path (`internalResults` → `results`). The retained task
    /// provides one cancellable trailing update; the pure gate owns cadence and
    /// scene-activity policy.
    private var resultsPublicationTask: Task<Void, Never>?
    private var publicationGate = SearchResultPublicationGate(minimumInterval: 0.5)
    private var publicationMetrics = ResultPublicationMetrics()

    private struct ResultPublicationMetrics {
        var mutations = 0
        var publications = 0
        var coalesced = 0
        var suppressed = 0
    }

    /// Dedup table: name key → indices of `internalResults` sharing that title.
    /// Within a bucket, candidates merge only when their authors are compatible.
    private var deduplicationMap: [String: [Int]] = [:]

    // Resume bookkeeping. `allSources` is the full source list for the current
    // query; `completedSourceIds` are the ones already finished. A manual or
    // automatic pause re-runs only the remainder. `autoPausePolicy` is captured
    // per search; auto-pause is applied to the initial run only — once the user
    // resumes, the search runs to completion (no repeated auto-pausing).
    private var allSources: [BookSource] = []
    private var completedSourceIds: Set<UUID> = []
    private var currentQuery = ""
    /// The current search's rule: 搜索's work rule, or 換源's (set per search).
    private var mergeRule = SearchMergeRule.work
    private var autoPausePolicy = SearchAutoPausePolicy(count: 0)

    /// Sources declaring `coverDecodeJs`, keyed by id — merged results register
    /// their cover URLs so the cover loader can decrypt them after download.
    private var coverDecodeSourcesById: [UUID: BookSource] = [:]

    // Later pages (cross-source paging, Legado-style). 搜索 fetches them by itself once page 1
    // is in, round after round, at the pace the phone allows (search 9e, maintainer
    // 2026-10-15: no paging for the reader to do, no freeze, no hot phone). `searchPage` is the
    // last page every paged source finished; a source that stops yielding NEW merged results
    // (or fails a page) enters `exhaustedSourceIds` and is skipped from then on — Legado's
    // exhaustedSources idea. Only sources whose page 1 had books (`pagedSourceIds`) are paged.
    private var searchPage = 1
    private var pagedSourceIds: Set<UUID> = []
    private var exhaustedSourceIds: Set<UUID> = []
    /// 搜索 pages on; 換源 and 尋找可用來源 never did and still stop at page 1.
    private var pagesLaterPages = false
    /// Upper bound on rounds (maintainer, 2026-10-15: 10), so a misbehaving source that
    /// returns new books on every page cannot drive unbounded fan-outs.
    private let maxSearchPages = 10

    /// `search.firstResult`: from `search(query:sources:origin:)` to the end of the first
    /// merge that added a book to that search. The generation ties the span to one search,
    /// so a superseded run's late merge cannot end the next search's span. Cleared by
    /// pause and cancel; a resumed search records nothing, since its time includes the pause.
    private var searchGeneration = 0
    /// How this search's sources answered, for the completion log line: with books,
    /// legitimately empty, or failed but shown as no results (Phase 0b).
    private var answerTally = SourceAnswerTally()

    private struct SourceAnswerTally {
        var withResults = 0
        var empty = 0
        var failedAsEmpty = 0

        mutating func count(_ outcome: SearchSourceOutcome) {
            switch outcome {
            case .results: withResults += 1
            case .empty: empty += 1
            case .failedAsEmpty: failedAsEmpty += 1
            case .timedOut, .failed: break
            }
        }

        var logFields: String {
            "answered=\(withResults) empty=\(empty) failedAsEmpty=\(failedAsEmpty)"
        }
    }
    private var firstResultTrace: (generation: Int, start: TimeInterval, detail: String)?

    // MARK: - Start Search

    func search(query: String, sources: [BookSource], origin: SearchOrigin = .searchTab) {
        let startedAt = SourcePerfTrace.now
        // Cancel previous search
        searchTask?.cancel()

        // Skip sources cooling down from repeated timeouts — but only when
        // searching across many sources. An explicitly chosen single source is
        // always attempted (respect the user's pick).
        let activeSources: [BookSource]
        let skippedCount: Int
        if sources.count > 1 {
            let split = SourceHealthStore.shared.partition(sources)
            activeSources = split.active
            skippedCount = split.skipped.count
        } else {
            activeSources = sources
            skippedCount = 0
        }

        // Reset state for a brand-new query.
        resultsPublicationTask?.cancel()
        resultsPublicationTask = nil
        let presentationIsActive = publicationGate.isActive
        publicationGate = SearchResultPublicationGate(
            minimumInterval: 0.5,
            isActive: presentationIsActive
        )
        publicationMetrics = ResultPublicationMetrics()
        internalResults = []
        resultsNeedSort = false
        internalProgress = SearchProgress(
            total: activeSources.count,
            skipped: skippedCount
        )
        requestResultsPublication(force: true, reason: "reset")
        deduplicationMap = [:]
        answerTally = SourceAnswerTally()
        completedSourceIds = []
        searchPage = 1
        pagedSourceIds = []
        exhaustedSourceIds = []
        pagesLaterPages = origin == .searchTab
        isPaused = false

        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        mergeRule = SearchMergeRule(origin)
        allSources = activeSources
        coverDecodeSourcesById = Dictionary(
            uniqueKeysWithValues: activeSources
                .filter { !$0.coverDecodeJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ($0.id, $0) }
        )

        let autoPauseCount = NetworkSearchSettings.effectiveAutoPauseCount(
            configured: GlobalSettings.shared.searchAutoPauseCount,
            sourceCount: activeSources.count
        )
        autoPausePolicy = SearchAutoPausePolicy(count: autoPauseCount)

        searchGeneration += 1
        firstResultTrace = (
            generation: searchGeneration,
            start: startedAt,
            detail: "origin=\(origin.rawValue) sources=\(activeSources.count) "
                + "cacheDays=\(GlobalSettings.shared.searchCacheDays)"
        )

        runSearch(sources: activeSources, applyAutoPause: true)
    }

    /// Fan out over `sources`, merging each as it returns. Shared by the initial
    /// `search(query:sources:)` and by `resume()` (which passes only the sources
    /// that had not finished). Never resets `results`/`progress`, so resuming
    /// keeps filling the existing list.
    ///
    /// `applyAutoPause` is true only for the initial run: the network-settings
    /// auto-pause stops the search once enough hits are found. When the user then
    /// resumes, auto-pause is off so the remaining sources run to completion (or
    /// until the user pauses again manually).
    private func runSearch(sources: [BookSource], applyAutoPause: Bool) {
        // Cancel any prior run first. An auto-paused task is not cancelled by
        // itself, so without this a resume started while its cancelled children
        // are still draining could let the old task's trailing cleanup clobber
        // `isSearching`.
        searchTask?.cancel()

        guard !sources.isEmpty else {
            isSearching = false
            isPaused = false
            return
        }

        isSearching = true
        isPaused = false

        let q = currentQuery
        let generation = searchGeneration
        let policy = applyAutoPause ? autoPausePolicy : SearchAutoPausePolicy(count: 0)
        let fanOut = fanOut(concurrency: maxConcurrency)

        searchTask = Task { [weak self] in
            if applyAutoPause, let trace = self?.firstResultTrace, trace.generation == generation {
                SourcePerfTrace.record("search.dispatch", trace.detail, since: trace.start, thresholdMs: 0)
            }
            // Streaming: merge each returned source without animation.
            // Large imported packs can contain 1000+ sources, so animated
            // mutations here overwhelm SwiftUI's list diffing on iOS 18.
            await fanOut.run(query: q, sources: sources, request: .firstPage { [weak self] source, books in
                await self?.mergeBatch(books, source: source, query: q, generation: generation)
            }) { source, answer in
                guard let self else { return false }
                let sourceId = source.id
                switch answer.outcome {
                case .results, .empty, .failedAsEmpty:
                    await self.mergeBatch(answer.books, source: source, query: q, generation: generation)
                    self.internalProgress.completed += 1
                    self.completedSourceIds.insert(sourceId)
                    // A page 1 without books has no page 2 worth asking for.
                    if answer.outcome == .results { self.pagedSourceIds.insert(sourceId) }
                    self.answerTally.count(answer.outcome)
                    if answer.outcome == .failedAsEmpty { self.internalProgress.failedAsEmpty += 1 }
                    // Phase 0b: a failure the fetcher reported as "no results" still
                    // counts as a success here. Counting it in SourceHealthStore (cooldown)
                    // is design §17 item 9, not yet decided.
                    SourceHealthStore.shared.recordSuccess(sourceId, responseMs: answer.elapsedMs)
                case .timedOut:
                    self.internalProgress.timedOut += 1
                    self.completedSourceIds.insert(sourceId)
                    SourceHealthStore.shared.recordFailure(sourceId)
                case .failed:
                    self.internalProgress.failed += 1
                    self.completedSourceIds.insert(sourceId)
                    SourceHealthStore.shared.recordFailure(sourceId)
                }
                self.requestResultsPublication(force: false, reason: "progress")

                // Auto-pause enters the same resumable paused state as the
                // manual control, so the user can tap to continue the rest.
                if self.shouldAutoPause(query: q, policy: policy) {
                    self.requestResultsPublication(force: true, reason: "autoPause")
                    self.logPublicationSummary(reason: "autoPause")
                    self.isPaused = true
                    self.isSearching = false
                    SourceHealthStore.shared.flush()
                    return false
                }
                return true
            }

            // Only a run that finished on its own goes on; a paused or superseded run is
            // cancelled and leaves state for resume(), and an auto-paused one waits for it.
            let device: SearchDeviceConditions? = {
                guard let self, !Task.isCancelled, !self.isPaused else { return nil }
                self.requestResultsPublication(force: true, reason: "firstPageComplete")
                self.logPublicationSummary(reason: "firstPageComplete")
                return self.device
            }()
            guard let device else { return }
            await SearchAggregator.runLaterPagesThenFinish(query: q, device: device) { [weak self] in self }
        }
    }

    // MARK: - Later pages (cross-source paging, search 9e)

    private struct LaterPageRound {
        let page: Int
        let sources: [BookSource]
    }

    /// The next round, or nil when 搜索 has no page left to ask for.
    private func nextLaterPageRound() -> LaterPageRound? {
        guard pagesLaterPages, !isPaused, !internalResults.isEmpty, searchPage < maxSearchPages else { return nil }
        let sources = allSources.filter { pagedSourceIds.contains($0.id) && !exhaustedSourceIds.contains($0.id) }
        guard !sources.isEmpty else { return nil }
        return LaterPageRound(page: searchPage + 1, sources: sources)
    }

    /// Runs the later pages after page 1 (or from where a pause stopped them), then ends the
    /// search. The aggregator is held weakly between rounds, so a search page that went away
    /// stops its search, as page 1's fan-out always did.
    private static func runLaterPagesThenFinish(query q: String, device: SearchDeviceConditions,
                                                aggregator: @escaping @MainActor () -> SearchAggregator?) async {
        await runLaterPages(query: q, device: device, aggregator: aggregator)
        guard !Task.isCancelled, let finished = aggregator() else { return }
        finished.requestResultsPublication(force: true, reason: "complete")
        finished.isSearching = false
        SourceHealthStore.shared.flush()
        finished.logPublicationSummary(reason: "complete")
    }

    /// One round per page, every paged source asked for it at the width the phone allows
    /// (`SearchDevicePacing`); while the phone is hot, the next round waits for it to cool.
    /// Ends when no source has more, at `maxSearchPages`, or when the task is cancelled.
    private static func runLaterPages(query q: String, device: SearchDeviceConditions,
                                      aggregator: @escaping @MainActor () -> SearchAggregator?) async {
        while !Task.isCancelled, let round = aggregator()?.nextLaterPageRound() {
            let pacing = device.current()
            if pacing.holdsLaterPages {
                AppLogger.parse("⏱ search.pages.hold page=\(round.page) thermal=\(pacing.thermalState.rawValue)")
                await device.waitUntilLaterPagesMayRun()
                continue
            }
            guard let fanOut = aggregator()?.fanOut(
                concurrency: pacing.laterPageConcurrency(configured: aggregator()?.maxConcurrency ?? 1)
            ) else { return }
            let started = SourcePerfTrace.now
            await fanOut.run(query: q, sources: round.sources, request: .page(round.page)) { source, answer in
                guard let aggregator = aggregator() else { return false }
                await aggregator.mergeLaterPage(answer, source: source, query: q)
                return true
            }
            guard !Task.isCancelled, let finished = aggregator() else { return }
            finished.searchPage = round.page
            // Through the gate's cadence: fast rounds share a publication, so the list and its
            // works are rebuilt at most twice a second however quickly the pages come.
            finished.requestResultsPublication(force: false, reason: "page")
            SourcePerfTrace.record(
                "search.page",
                "page=\(round.page) sources=\(round.sources.count) width=\(fanOut.concurrency) "
                    + "lowPower=\(pacing.isLowPower) thermal=\(pacing.thermalState.rawValue) rows=\(finished.internalResults.count)",
                since: started, thresholdMs: 0
            )
        }
    }

    /// Merges a source's later page. A page that adds nothing new, or that the source says is
    /// its last, exhausts the source; a failed or timed-out later page stops paging it without
    /// striking its health, since its page 1 succeeded.
    private func mergeLaterPage(_ answer: BookSourceSearchFanOut.Answer, source: BookSource, query q: String) async {
        let sourceId = source.id
        guard answer.outcome.answered else {
            exhaustedSourceIds.insert(sourceId)
            return
        }
        let newlyMerged = await mergeBatch(answer.books, source: source, query: q, generation: nil)
        // The source's own hasMoreRule verdict wins; without one, a page that contributed
        // nothing new means exhausted.
        if answer.hasMore == false || (answer.hasMore != true && newlyMerged == 0) {
            exhaustedSourceIds.insert(sourceId)
        }
        SourceHealthStore.shared.recordSuccess(sourceId, responseMs: answer.elapsedMs)
    }

    // MARK: - Pause / Resume / Cancel

    /// Manually pause an in-flight search. Results already returned stay on
    /// screen; sources that had not finished are remembered so `resume()` can
    /// pick up exactly where it stopped.
    func pause() {
        guard isSearching else { return }
        searchTask?.cancel()
        firstResultTrace = nil
        requestResultsPublication(force: true, reason: "pause")
        isSearching = false
        isPaused = true
        SourceHealthStore.shared.flush()
        logPublicationSummary(reason: "pause")
    }

    /// Continue a paused search over only the sources that had not finished yet, then
    /// 搜索's later pages; paused during those, it goes on from the page it was at.
    /// Auto-pause does not re-trigger here — resuming is an explicit request to
    /// keep going.
    func resume() {
        guard isPaused else { return }
        let pending = allSources.filter { !completedSourceIds.contains($0.id) }
        guard pending.isEmpty, pagesLaterPages else {
            runSearch(sources: pending, applyAutoPause: false)
            return
        }
        // Page 1 is in: on with the later pages; with none left, the search just ends.
        searchTask?.cancel()
        isPaused = false
        isSearching = true
        let q = currentQuery
        let device = device
        searchTask = Task { [weak self] in
            await SearchAggregator.runLaterPagesThenFinish(query: q, device: device) { [weak self] in self }
        }
    }

    func cancel() {
        searchTask?.cancel()
        firstResultTrace = nil
        requestResultsPublication(force: true, reason: "cancel")
        isSearching = false
        SourceHealthStore.shared.flush()
        isPaused = false
        logPublicationSummary(reason: "cancel")
    }

    /// Stops the current search and removes every query-scoped value.
    ///
    /// Scope changes use this command so results, progress, resume bookkeeping,
    /// and cross-source paging can never belong to a different source range than
    /// the range currently shown by the search screen.
    func cancelAndClear() {
        searchTask?.cancel()
        searchTask = nil
        firstResultTrace = nil
        resultsPublicationTask?.cancel()
        resultsPublicationTask = nil

        internalResults = []
        resultsNeedSort = false
        internalProgress = SearchProgress()
        deduplicationMap = [:]
        allSources = []
        completedSourceIds = []
        currentQuery = ""
        autoPausePolicy = SearchAutoPausePolicy(count: 0)
        coverDecodeSourcesById = [:]
        searchPage = 1
        pagedSourceIds = []
        exhaustedSourceIds = []
        pagesLaterPages = false
        publicationMetrics = ResultPublicationMetrics()
        isSearching = false
        isPaused = false

        requestResultsPublication(force: true, reason: "clear")
        SourceHealthStore.shared.flush()
    }

    // MARK: - Scene-aware result publication (internalResults → results)

    /// Called by the search screen when its scene moves between active and
    /// inactive states. Network work may continue in the background, but an
    /// inactive scene never receives a result-list assignment.
    func setResultPresentationActive(_ active: Bool) {
        if !active {
            resultsPublicationTask?.cancel()
            resultsPublicationTask = nil
        }

        guard publicationGate.setActive(active) == .publishNow else { return }
        publishResultsNow(reason: "resume")
    }

    private func requestResultsPublication(force: Bool, reason: String) {
        let decision = publicationGate.request(
            now: ProcessInfo.processInfo.systemUptime,
            force: force
        )
        handlePublicationDecision(decision, reason: reason)
    }

    private func handlePublicationDecision(
        _ decision: SearchResultPublicationDecision,
        reason: String
    ) {
        switch decision {
        case .publishNow:
            resultsPublicationTask?.cancel()
            resultsPublicationTask = nil
            publishResultsNow(reason: reason)

        case .schedule(let delay):
            guard resultsPublicationTask == nil else {
                publicationMetrics.coalesced += 1
                return
            }

            resultsPublicationTask = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.resultsPublicationTask = nil
                self.requestResultsPublication(force: false, reason: "trailing")
            }

        case .suppress:
            publicationMetrics.suppressed += 1
        }
    }

    private func publishResultsNow(reason: String) {
        guard publicationGate.isActive else {
            publicationMetrics.suppressed += 1
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if resultsNeedSort {
            resultsNeedSort = false
            sortResults(query: currentQuery)
        }
        let publishedResults = internalResults.map { $0.publicationSnapshot() }
        objectWillChange.send()
        results = publishedResults
        publicationRevision &+= 1
        progress = internalProgress
        publicationGate.didPublish(at: now)
        publicationMetrics.publications += 1
        // The sort and the snapshots run on the main actor: timed, since 搜索's later pages
        // multiply the rows (search 9e).
        SourcePerfTrace.record(
            "search.listPublish",
            "rows=\(results.count) reason=\(reason) publications=\(publicationMetrics.publications)",
            since: now, thresholdMs: 0
        )
    }

    private func logPublicationSummary(reason: String) {
        AppLogger.parse(
            "⏱ search.listPublish.summary reason=\(reason) "
                + "\(answerTally.logFields) "
                + "mutations=\(publicationMetrics.mutations) "
                + "publications=\(publicationMetrics.publications) "
                + "coalesced=\(publicationMetrics.coalesced) "
                + "suppressed=\(publicationMetrics.suppressed)"
        )
    }

    private func shouldAutoPause(query: String, policy: SearchAutoPausePolicy) -> Bool {
        guard policy.isEnabled else { return false }
        // Normalize the query the same way `sortResults` does, otherwise an exact
        // title (in a different case/width) is scored as fuzzy and undercounts.
        let normalizedQuery = queryKey(query)
        var exactCount = 0
        var fuzzyCount = 0
        // Count source hits (origins), not deduplicated titles. A single-title
        // search collapses every source into one `SearchBook`, so counting books
        // would stay at ~1 and the threshold would never be reached — that was
        // why auto-pause appeared to do nothing ("自動暫停不生效").
        for result in internalResults {
            let hits = result.origins.count
            if Self.matchScore(normalizedName: rowKey(result), query: normalizedQuery) == 3 {
                exactCount += hits
            } else {
                fuzzyCount += hits
            }
        }
        return policy.shouldPause(exactCount: exactCount, fuzzyCount: fuzzyCount)
    }

    // MARK: - Merge a batch of results (dedup + aggregate)
    //
    // Executed whenever any single source returns results:
    // 1. Build BookOrigin per book, dedup/merge into `internalResults`
    // 2. Sort ONCE per batch (not per book — a full sort per merged book was
    //    O(books × N log N) on the main actor and re-published every mutation)
    // 3. Request one scene-aware, cadence-bounded UI publication

    /// Returns how many books were newly merged (new titles or new origins) —
    /// the paging loop uses 0 to mark a source as exhausted.
    @discardableResult
    /// - Parameter generation: the search this batch belongs to; nil for 載入更多 pages,
    ///   which never end a `search.firstResult` span.
    private func mergeBatch(
        _ books: [OnlineBook],
        source: BookSource?,
        query: String,
        generation: Int?
    ) async -> Int {
        let preparedBooks = await SearchResultPresentationBuilder.prepareBatch(
            books,
            source: source,
            foldsWorkKeys: true
        )
        let mainMergeStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
            SourcePerfTrace.record(
                "search.presentation.mainMerge",
                "\(preparedBooks.count) books source=\(source?.bookSourceName ?? "unknown")",
                since: mainMergeStartedAt,
                thresholdMs: 4
            )
        }
        let q = queryKey(query)
        var mergedCount = 0
        var processed = 0
        for preparedBook in preparedBooks {
            if Task.isCancelled { break }
            if mergeBook(preparedBook, normalizedQuery: q) { mergedCount += 1 }
            processed += 1
            // Aggregate sources can stream 1000+ books in one batch; keep the
            // main actor responsive without paying a yield per book.
            if processed % 200 == 0 { await Task.yield() }
        }
        guard mergedCount > 0, !Task.isCancelled else { return mergedCount }
        if let trace = firstResultTrace, trace.generation == generation {
            firstResultTrace = nil
            SourcePerfTrace.record(
                "search.firstResult",
                trace.detail + " books=\(mergedCount)",
                since: trace.start,
                thresholdMs: 0
            )
        }
        // Sorting is deferred to publication. It used to run per merged batch — i.e.
        // once per answering source — so a few thousand sources meant a few thousand
        // full sorts of a list that only ever reaches the screen at the publication
        // cadence. Ordering the same list ~2×/second produces identical output for a
        // fraction of the work. Merging keeps `deduplicationMap` correct on its own;
        // only a sort invalidates the indices, and `sortResults` rebuilds it.
        resultsNeedSort = true
        publicationMetrics.mutations += mergedCount
        requestResultsPublication(force: false, reason: "batch")
        return mergedCount
    }

    @discardableResult
    private func mergeBook(
        _ preparedBook: PreparedSearchResult,
        normalizedQuery q: String
    ) -> Bool {
        let book = preparedBook.book
        let preparedOrigin = preparedBook.preparedOrigin
        let origin = preparedOrigin.origin

        // Filter out results completely unrelated to the search keyword, then find the row
        // this book belongs to under the search's rule.
        guard let keys = preparedBook.workKeys else {
            // `mergeBatch` asks for the keys; a book without them is a bug in that path,
            // not a book to show.
            assertionFailure("search merge without work keys")
            AppLogger.error("⟐ search merge without work keys", context: ["source": book.sourceName])
            return false
        }
        let isRelated = !q.isEmpty && (keys.title.contains(q) || keys.author.contains(q) || q.contains(keys.title))
        guard isRelated else { return false }
        let titleKey = keys.title
        let existingIndex = deduplicationMap[titleKey]?.first { idx in
            guard idx < internalResults.count, let rowKeys = internalResults[idx].workKeys else { return false }
            switch mergeRule {
            case .work:
                // Same work title, both authors named and compatible, same kind (design §7.2).
                return WorkMatchKey.authorKeysCompatible([keys.author], [rowKeys.author])
                    && internalResults[idx].inferredContentKind() == preparedOrigin.presentation.contentKind
            case .changeSource:
                // Same work title; an author missing on either side merges (4d).
                return SearchBook.isLikelySameBook(keys, rowKeys)
            }
        }

        if !origin.coverUrl.isEmpty {
            CoverDecodeService.shared.registerIfNeeded(
                coverUrl: origin.coverUrl,
                source: coverDecodeSourcesById[book.sourceId]
            )
        }

        if let existingIndex {
            // Same origin already merged (a later page repeating page-1 items,
            // or an aggregate channel echoing) → not new information.
            let duplicate = internalResults[existingIndex].origins.contains {
                $0.sourceId == origin.sourceId && $0.bookUrl == origin.bookUrl
            }
            guard !duplicate else { return false }
            // Compatible match -> merge into existing result's origin array.
            internalResults[existingIndex].append(preparedOrigin)
        } else {
            let searchBook = SearchBook(
                name: book.name,
                author: book.author,
                workKeys: preparedBook.workKeys,
                preparedOrigins: [preparedOrigin]
            )
            deduplicationMap[titleKey, default: []].append(internalResults.count)
            internalResults.append(searchBook)
        }
        return true
    }

    // MARK: - Three-tier Sorting

    private func sortResults(query: String) {
        let q = queryKey(query)

        // Decorate–sort–undecorate. A comparator body runs O(n log n) times, so
        // anything derived inside it is recomputed tens of thousands of times per
        // sort; `matchScore` used to normalize both names on every single
        // comparison. Each input is now derived exactly once per book.
        var decorated = internalResults.map { book in
            (
                score: Self.matchScore(normalizedName: rowKey(book), query: q),
                nameLength: book.name.count,
                originCount: book.origins.count,
                book: book
            )
        }
        decorated.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            // Tie-breaker: shorter name is more precise
            // (e.g. a short precise name beats a long one with extra description)
            if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
            return a.originCount > b.originCount
        }
        internalResults = decorated.map(\.book)

        rebuildDeduplicationMap()
    }

    /// The query as titles are compared: folded by `WorkMatchKey`, so a Simplified query
    /// finds and ranks a Traditional title (搜索 since 4c-1, 換源 since 4d).
    private func queryKey(_ query: String) -> String {
        WorkMatchKey.title(LegadoSearchKeyword.matchingTitle(from: query))
    }

    /// A row's folded title; also its dedup bucket. Never nil: rows are made only from books
    /// with keys (`mergeBook`); `normalizedName` only keeps the type total.
    private func rowKey(_ book: SearchBook) -> String {
        book.workKeys?.title ?? book.normalizedName
    }

    /// - Parameter normalizedName: already run through the same normalization the
    ///   query gets (`rowKey` for a merged result).
    private static func matchScore(normalizedName: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }

        if normalizedName == query { return 3 }
        if normalizedName.hasPrefix(query) { return 2 }
        if normalizedName.contains(query) { return 1 }
        if query.contains(normalizedName) && !normalizedName.isEmpty { return 1 }
        return 0
    }

    /// Rebuild dedup table (indices change after sorting)
    private func rebuildDeduplicationMap() {
        deduplicationMap.removeAll(keepingCapacity: true)
        for (index, book) in internalResults.enumerated() {
            // Keys pre-computed per row (`workKeys` were folded off the main actor) — no ICU
            // transform per entry per rebuild.
            deduplicationMap[rowKey(book), default: []].append(index)
        }
    }
}
