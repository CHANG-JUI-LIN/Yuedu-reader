import Combine
import CryptoKit
import Foundation

/// The chapter being read, as a module is asked about it.
struct ChapterCommentQuery: Hashable, Sendable {
    /// The book, as 讀者評論 names a work.
    var work: WorkReviewQuery
    var chapterTitle: String
    /// Every chapter of the reader's copy, in order: what tells the book when it names no
    /// author, and whether a chapter's number is its alone.
    var chapterTitles: [String]
}

/// Where a chapter's comments are: the module, its record of the book, and the site's chapter.
struct ChapterCommentThread: Equatable, Sendable {
    var module: RuleModule
    var record: RuleListItem
    var chapter: ModuleCommentChapter

    /// The orders the site lists the chapter's comments in; empty when it has one.
    var sorts: [RuleModule.Option] { module.comments?.chapter.sorts ?? [] }
    /// The orders it lists one paragraph's in.
    var paragraphSorts: [RuleModule.Option] { module.comments?.paragraph?.sorts ?? [] }
}

/// 本章說 (maintainer, 2026-11-15; `Technotes/ChapterCommentsModule-2026-11-15-design.md`): a
/// chapter's comments from an installed module, for any book — a file, or a source that has no
/// comments of its own. The first module, in 資料來源's order, that has the book and the chapter:
///
/// - the book as 讀者評論 finds a work (`ModuleReviewProvider.records`): the module's own record,
///   its ISBN, or its title and a compatible author. A book that names no author (most TXT files)
///   is the search result of its title whose chapters are its chapters
///   (`ChapterTitleMatch.isSameBook`);
/// - the chapter by its title among the site's (`ChapterTitleMatch.Index`), never by position.
///
/// A book or a chapter that cannot be told is not shown comments: nothing is guessed. Reading a
/// chapter sends the book's title and author to the module's site, as opening 作品詳情 does;
/// unchecking the module in 資料來源 stops it.
@MainActor
enum ChapterComments {
    /// Records whose chapters are read per module: each is a request under its `rateLimit`.
    nonisolated static let recordLimit = 3
    nonisolated static let timeout: Duration = .seconds(20)

    /// The modules with 本章說 that 資料來源 has checked, in its order.
    static func modules(in library: RuleModuleLibrary = .shared, order: MetadataFillOrderStore = .shared) -> [RuleModule] {
        WorkReviews.modules(in: library, order: order) { $0.comments != nil }
    }

    /// Where the chapter's comments are, nil when no module has the book and the chapter.
    static func thread(for query: ChapterCommentQuery, library: RuleModuleLibrary = .shared,
                       order: MetadataFillOrderStore = .shared,
                       client: RuleModuleClient = RuleModuleClient()) async -> ChapterCommentThread? {
        guard !query.work.title.isEmpty, !query.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        await library.loadIfNeeded()
        let modules = Self.modules(in: library, order: order)
        guard !modules.isEmpty else { return nil }
        let started = SourcePerfTrace.now
        let numbers = ChapterTitleMatch.numberCounts(query.chapterTitles)
        for module in modules {
            guard !Task.isCancelled, let block = module.comments else { return nil }
            do {
                let finder = ModuleReviewProvider(provider: ModuleProvider(module: module, client: client), client: client)
                // The module's own record, an ISBN, or a title with its author: the book. A title
                // alone: a candidate, until its chapters say so.
                var records = try await finder.records(for: query.work)
                let isCertain = !records.isEmpty
                if records.isEmpty, query.work.authors.isEmpty { records = try await finder.titleRecords(for: query.work) }
                for record in records.filter({ RuleModuleClient.canAskComments(of: $0, by: block) }).prefix(recordLimit) {
                    let chapters = try await LibrarySearch.within(timeout) {
                        try await client.commentChapters(of: record, by: block, in: module)
                    }
                    let titles = chapters.map(\.title)
                    guard isCertain || ChapterTitleMatch.isSameBook(localTitles: query.chapterTitles, remoteTitles: titles) else { continue }
                    guard let position = ChapterTitleMatch.Index(titles: titles).position(of: query.chapterTitle, localNumbers: numbers) else {
                        continue
                    }
                    SourcePerfTrace.record("reader.comments.thread", "module=\(module.id) chapters=\(chapters.count)",
                                           since: started, thresholdMs: 0)
                    return ChapterCommentThread(module: module, record: record, chapter: chapters[position])
                }
            } catch is CancellationError {
                return nil
            } catch {
                // The site's own failure: the next module is asked. Nothing is retried here.
                AppLogger.network("⟐ chapter comments: module failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id])
            }
        }
        SourcePerfTrace.record("reader.comments.thread", "modules=\(modules.count) found=0", since: started, thresholdMs: 0)
        return nil
    }

    /// One page of the thread's comments (`page` from 1), in the order `sort` names: the
    /// chapter's, or with `paragraphID` that paragraph's.
    static func comments(in thread: ChapterCommentThread, paragraphID: String? = nil, sort: String?, page: Int,
                         client: RuleModuleClient = RuleModuleClient()) async throws -> (comments: [WorkReview], total: Int?) {
        guard let block = thread.module.comments else { return ([], nil) }
        let module = thread.module, record = thread.record, chapterID = thread.chapter.id
        return try await LibrarySearch.within(timeout) {
            try await client.chapterComments(chapterID: chapterID, paragraphID: paragraphID, of: record, sort: sort, page: page,
                                             by: block, in: module)
        }
    }

    /// The thread's 段評 counts, 熱評 and 作者說.
    static func notes(in thread: ChapterCommentThread, client: RuleModuleClient = RuleModuleClient()) async -> RuleModuleChapterNotes {
        guard let block = thread.module.comments else { return RuleModuleChapterNotes(fetchedAt: .now) }
        return await client.chapterNotes(chapterID: thread.chapter.id, of: thread.record, by: block, in: thread.module)
    }
}

/// What a bubble or a card in the text opens: a chapter's comments, or one paragraph's.
struct ModuleCommentTarget: Equatable, Sendable {
    var thread: ChapterCommentThread
    /// The paragraph, by the site's id of it; nil for the chapter's own comments.
    var paragraphID: String?
    /// What the list is headed: the chapter's title, or the paragraph's first words.
    var heading: String
}

/// The comments the laid-out chapters' bubbles and cards are tapped for, by the token their
/// anchor carries (`ReaderHTMLUtilities.moduleReviewHref`). In memory only: an anchor lives as
/// long as its chapter's layout, and is made again with it.
@MainActor
enum ModuleCommentTargets {
    private static var held: [String: ModuleCommentTarget] = [:]

    /// The token of `target`, the same for the same comments however often it is asked.
    static func token(for target: ModuleCommentTarget) -> String {
        let name = [target.thread.module.id, target.thread.record.bookUrl, target.thread.record.id ?? "",
                    target.thread.chapter.id, target.paragraphID ?? ""].joined(separator: "\u{1F}")
        let token = SHA256.hash(data: Data(name.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        held[token] = target
        return token
    }

    static func target(_ token: String) -> ModuleCommentTarget? {
        token.isEmpty ? nil : held[token]
    }
}

/// A list of comments (本章說, or one paragraph's 段評): finds the chapter's thread, then reads
/// it a page at a time.
@MainActor
final class ChapterCommentsModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// No module has the book and the chapter.
        case unavailable
        case loaded
        case failed(String)
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var comments: [WorkReview] = []
    @Published private(set) var thread: ChapterCommentThread?
    /// The chosen order's `value`; nil for a site with one order.
    @Published private(set) var sort: String?
    /// Another page is being read, or none is left.
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false

    /// What the list is headed: the chapter's title, or the paragraph's first words.
    let heading: String
    /// The paragraph whose comments these are; nil for the chapter's.
    let paragraphID: String?
    private let findThread: () async -> ChapterCommentThread?
    /// The thread, the paragraph, the order, the page.
    private let readPage: (ChapterCommentThread, String?, String?, Int) async throws -> [WorkReview]
    private var page = 0
    private var seen = Set<String>()
    private var generation = 0

    /// The site's orders for this list; empty when it has one.
    var sorts: [RuleModule.Option] {
        (paragraphID == nil ? thread?.sorts : thread?.paragraphSorts) ?? []
    }

    init(heading: String, paragraphID: String? = nil, findThread: @escaping () async -> ChapterCommentThread?,
         readPage: @escaping (ChapterCommentThread, String?, String?, Int) async throws -> [WorkReview] = {
             try await ChapterComments.comments(in: $0, paragraphID: $1, sort: $2, page: $3).comments
         }) {
        self.heading = heading
        self.paragraphID = paragraphID
        self.findThread = findThread
        self.readPage = readPage
    }

    /// The comments a bubble or a card in the text was tapped for: their thread is known.
    convenience init(target: ModuleCommentTarget) {
        self.init(heading: target.heading, paragraphID: target.paragraphID, findThread: { target.thread })
    }

    /// Finds the thread and reads its first page.
    func load() async {
        phase = .loading
        guard let thread = await findThread() else {
            phase = .unavailable
            return
        }
        self.thread = thread
        sort = sorts.first?.value
        await restart()
    }

    /// The comments again, in another of the site's orders.
    func choose(sort value: String) async {
        guard value != sort, thread != nil else { return }
        sort = value
        phase = .loading
        await restart()
    }

    private func restart() async {
        generation += 1
        page = 0
        seen = []
        comments = []
        hasMore = true
        await loadMore()
    }

    /// The next page, when the last row comes on screen. The thread ends at a page that brings
    /// nothing new: a site that ignores `{{page}}` answers the same comments again.
    func loadMore() async {
        guard let thread, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let asked = generation
        do {
            let found = try await readPage(thread, paragraphID, sort, page + 1)
            // Another order was chosen while this page was read: its answer is not this list's.
            guard asked == generation else { return }
            let fresh = found.filter { seen.insert("\($0.author ?? "")\u{1F}\($0.text)").inserted }
            page += 1
            comments += fresh
            hasMore = !fresh.isEmpty
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard asked == generation else { return }
            AppLogger.network("⟐ chapter comments: page failed", error: SourceFailure.loggable(error),
                              context: ["module": thread.module.id, "page": page + 1])
            hasMore = false
            // A first page that fails is the page's error; a later one leaves what was read.
            if comments.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }
}
