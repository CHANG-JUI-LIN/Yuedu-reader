import Foundation
import Observation

/// 全書搜尋 for the open book: the last search and its results, kept while the book is open
/// so reopening the sheet shows them again, and the hit the reader is stepping through.
///
/// Reads each chapter from the device only (`localChapterText`): an online chapter that is
/// not downloaded is skipped and counted, never fetched.
@MainActor
@Observable
final class ReaderBookSearchSession {
    enum Phase: Equatable {
        case idle
        case searching
        case finished
        case failed(ReaderBookSearchError)
    }

    struct Options: Equatable {
        var isRegex = false
        /// On: search the text as the reader shows it, after 替換規則. Off: the source's own
        /// text, to find words a rule removed or changed.
        var appliesReplaceRules = true
    }

    /// What the results were found in. A different one means they no longer match the page.
    struct ContentSignature: Equatable {
        /// The book, its source and its chapters — 換源 changes it.
        let source: ReaderAISourceIdentity
        let conversion: TextConversion
        let rulesRevision: Int
    }

    /// How the current results were searched, which a jump needs to find a hit again even
    /// after the options have been switched.
    struct Searched: Equatable {
        let query: ReaderBookSearchQuery
        let appliesReplaceRules: Bool
        let conversion: TextConversion
    }

    /// One chapter's run of hits, for the results list's sections.
    struct ChapterSection: Identifiable, Equatable {
        let chapterIndex: Int
        let title: String
        var hitIndices: Range<Int>
        var id: Int { chapterIndex }
    }

    /// The results list stops here. A one-character search in a long novel matches hundreds
    /// of thousands of times, and every one would be a row; this many is already more than
    /// anyone reads, and the list says that it stopped.
    static let hitLimit = 5000

    var options = Options()
    private(set) var query = ""
    private(set) var phase: Phase = .idle
    private(set) var hits: [ReaderBookSearchHit] = []
    private(set) var sections: [ChapterSection] = []
    private(set) var searchedChapterCount = 0
    private(set) var totalChapterCount = 0
    /// Chapters skipped because they are not on the device — the list's footer says how many.
    private(set) var notDownloadedChapterCount = 0
    private(set) var reachedHitLimit = false
    private(set) var signature: ContentSignature?
    private(set) var searched: Searched?

    /// The hit the reader last jumped to, while stepping through them in the reader.
    private(set) var currentHitIndex: Int?
    /// Where the reader was before the first jump, for ✕'s 回到原位置. Kept across new
    /// searches until the stepping ends, so it is always where the search began.
    private(set) var origin: CoreTextReadingPosition?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var currentHit: ReaderBookSearchHit? {
        currentHitIndex.flatMap { hits.indices.contains($0) ? hits[$0] : nil }
    }

    var isNavigating: Bool { currentHit != nil }

    func isStale(for signature: ContentSignature) -> Bool {
        self.signature != nil && self.signature != signature
    }

    /// Searches every chapter in order, one at a time, publishing results as they come.
    /// A new call, `stop()` or `clear()` ends the one before; its late results are dropped.
    ///
    /// - Parameter load: one chapter's text from the device, rules applied or not.
    /// - Returns: the search's task, nil for empty words.
    @discardableResult
    func search(
        _ text: String,
        chapterTitles: [String],
        signature: ContentSignature,
        load: @escaping @MainActor (Int, Bool) async -> AILocalChapterText
    ) -> Task<Void, Never>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelTask()
        currentHitIndex = nil
        query = trimmed
        hits = []
        sections = []
        searchedChapterCount = 0
        totalChapterCount = chapterTitles.count
        notDownloadedChapterCount = 0
        reachedHitLimit = false
        self.signature = signature
        searched = nil
        guard !trimmed.isEmpty else {
            phase = .idle
            return nil
        }
        phase = .searching
        // The text is searched as converted to the reader's 繁簡 setting, so the words are
        // too: what was typed in one script still finds the other.
        let searchQuery = ReaderBookSearchQuery(text: trimmed.converted(to: signature.conversion),
                                                isRegex: options.isRegex)
        let appliesRules = options.appliesReplaceRules
        searched = Searched(query: searchQuery, appliesReplaceRules: appliesRules, conversion: signature.conversion)
        let current = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await run(searchQuery, appliesRules: appliesRules, chapterTitles: chapterTitles,
                      conversion: signature.conversion, generation: current, load: load)
        }
        self.task = task
        return task
    }

    func stop() {
        guard phase == .searching else { return }
        cancelTask()
        phase = .finished
    }

    /// Forgets the search, its words and results — the field was cleared.
    func clear() {
        cancelTask()
        query = ""
        hits = []
        sections = []
        searchedChapterCount = 0
        totalChapterCount = 0
        notDownloadedChapterCount = 0
        reachedHitLimit = false
        signature = nil
        searched = nil
        currentHitIndex = nil
        phase = .idle
    }

    /// A hit placed on the page: its range in the laid-out chapter, and the words drawn there.
    struct LocatedHit: Equatable {
        let range: NSRange
        let drawnText: String
    }

    /// Where `hit` sits in the laid-out chapter, or nil when it cannot be placed there. Reads
    /// the hit's chapter again as it was searched, and the chapter as laid out.
    ///
    /// - Parameters:
    ///   - loadSource: the chapter's text from the device, rules applied or not.
    ///   - loadLaidOut: the chapter as laid out, laying it out first if it is not.
    func locate(
        _ hit: ReaderBookSearchHit,
        loadSource: @MainActor (Int, Bool) async -> AILocalChapterText,
        loadLaidOut: @MainActor (Int) async -> String?
    ) async -> LocatedHit? {
        guard let searched else { return nil }
        let source = await loadSource(hit.chapterIndex, searched.appliesReplaceRules)
        guard let laidOut = await loadLaidOut(hit.chapterIndex),
              let range = await ReaderBookSearchMatcher.locate(hit, query: searched.query, sourceText: source.text,
                                                               laidOutText: laidOut, conversion: searched.conversion)
        else { return nil }
        return LocatedHit(range: range, drawnText: (laidOut as NSString).substring(with: range))
    }

    /// Makes `index` the current hit. The first jump of a search session remembers where the
    /// reader was.
    func select(_ index: Int, from position: CoreTextReadingPosition?) {
        guard hits.indices.contains(index) else { return }
        if origin == nil { origin = position }
        currentHitIndex = index
    }

    /// The hit `offset` places from the current one, or nil past either end.
    func hitIndex(offsetBy offset: Int) -> Int? {
        guard let currentHitIndex else { return nil }
        let index = currentHitIndex + offset
        return hits.indices.contains(index) ? index : nil
    }

    /// Ends stepping through hits. Returns where the reader was before the first jump.
    @discardableResult
    func endNavigation() -> CoreTextReadingPosition? {
        let position = origin
        origin = nil
        currentHitIndex = nil
        return position
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    private func run(
        _ query: ReaderBookSearchQuery,
        appliesRules: Bool,
        chapterTitles: [String],
        conversion: TextConversion,
        generation: Int,
        load: @MainActor (Int, Bool) async -> AILocalChapterText
    ) async {
        let started = SourcePerfTrace.now
        var pending: [ReaderBookSearchHit] = []
        var lastPublish = started
        var searched = 0, available = 0, notDownloaded = 0, failed = 0, unsupported = 0
        var failure: ReaderBookSearchError?
        func isCurrent() -> Bool { !Task.isCancelled && self.generation == generation }
        func publish() {
            append(pending, chapterTitles: chapterTitles)
            pending = []
            searchedChapterCount = searched
            notDownloadedChapterCount = notDownloaded
            lastPublish = SourcePerfTrace.now
        }

        for index in chapterTitles.indices {
            guard isCurrent() else { return }
            let chapter = await load(index, appliesRules)
            guard isCurrent() else { return }
            switch chapter.status {
            case .available: available += 1
            case .notDownloaded: notDownloaded += 1
            case .extractionFailed: failed += 1
            case .unsupported: unsupported += 1
            }
            if chapter.status == .available, let text = chapter.text {
                do {
                    pending += try await ReaderBookSearchMatcher.hits(
                        of: query, chapterIndex: index, text: text, conversion: conversion,
                        limit: Self.hitLimit - hits.count - pending.count)
                } catch {
                    failure = error
                }
                guard isCurrent() else { return }
            }
            searched = index + 1
            if failure != nil { break }
            if hits.count + pending.count >= Self.hitLimit {
                reachedHitLimit = true
                break
            }
            // Publishing every chapter would rebuild the list a thousand times on a long
            // local book, which searches a chapter in a millisecond.
            if SourcePerfTrace.now - lastPublish >= 0.15 { publish() }
        }
        publish()
        if failed > 0 || unsupported > 0 {
            AppLogger.parse("全書搜尋 skipped chapters: extractionFailed=\(failed) unsupported=\(unsupported) of \(chapterTitles.count)")
        }
        SourcePerfTrace.record(
            "ReaderSearch.book",
            "chapters=\(searched)/\(chapterTitles.count) hits=\(hits.count) regex=\(query.isRegex) rules=\(appliesRules)",
            since: started, thresholdMs: 0, mainThreadStallBreadcrumb: false)
        if let failure {
            hits = []
            sections = []
            phase = .failed(failure)
        } else if available == 0, unsupported > 0, notDownloaded == 0 {
            phase = .failed(.unsupported)
        } else {
            phase = .finished
        }
        task = nil
    }

    private func append(_ newHits: [ReaderBookSearchHit], chapterTitles: [String]) {
        guard !newHits.isEmpty else { return }
        // Published between chapters only, so each chapter's hits arrive together.
        var index = hits.count
        hits += newHits
        while index < hits.count {
            let chapter = hits[index].chapterIndex
            var end = index + 1
            while end < hits.count, hits[end].chapterIndex == chapter { end += 1 }
            let title = chapterTitles.indices.contains(chapter) ? chapterTitles[chapter] : ""
            sections.append(ChapterSection(chapterIndex: chapter, title: title, hitIndices: index..<end))
            index = end
        }
    }
}
