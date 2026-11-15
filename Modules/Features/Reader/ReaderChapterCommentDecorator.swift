import Combine
import SwiftUI

/// A module's comments in the text of the book being read (maintainer, 2026-11-15: 段評、熱評、
/// 本章說、作者說都在閱讀介面): a count bubble at the end of a paragraph, a 熱評 card under one,
/// 作者說 and 本章說 cards after the chapter, each drawn as a 來源配置's own is and opening the
/// comments it stands for.
///
/// A chapter is asked about once, when it is first built; its answer is kept for the reading
/// session and said on `updates`, on which the reader builds the chapter again. Nothing is
/// asked for a chapter whose source drew comments of its own, with the switch off, or with no
/// module that has comments.
@MainActor
final class ReaderChapterCommentDecorator: ReaderChapterDecorationSource {
    /// What a module's site holds about one chapter.
    struct ChapterData: Equatable {
        var thread: ChapterCommentThread
        var notes: RuleModuleChapterNotes
        /// The chapter's first comments, for its 本章說 card.
        var top: [WorkReview] = []
        var total: Int?

        var isEmpty: Bool {
            notes.counts.isEmpty && notes.hot.isEmpty && notes.authorSay == nil && top.isEmpty && (total ?? 0) == 0
        }
    }

    private enum State {
        case loading
        /// Nil: no module has the chapter, or it has nothing about it.
        case ready(ChapterData?)
    }

    /// 設定 → 模組's 「在正文顯示模組的評論」; on unless the reader turned it off.
    nonisolated static let enabledKey = "yd_module_chapter_comments"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Comments drawn on a 本章說 card.
    nonisolated static let cardComments = 3

    /// A chapter's answer is in: the spine to build again.
    let updates = PassthroughSubject<Int, Never>()
    /// The book, as a module is asked about it; nil until a book is being read.
    var work: WorkReviewQuery?
    /// Every chapter's title, in order, read when a chapter is asked about.
    var chapterTitles: () -> [String] = { [] }

    private var states: [Int: State] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let load: (ChapterCommentQuery) async -> ChapterData?

    init(load: @escaping (ChapterCommentQuery) async -> ChapterData? = ReaderChapterCommentDecorator.load) {
        self.load = load
    }

    /// Another book: nothing of the last one's is kept.
    func reset(work: WorkReviewQuery?, chapterTitles: @escaping () -> [String]) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        states = [:]
        self.work = work
        self.chapterTitles = chapterTitles
    }

    // MARK: - Asking

    /// The chapter's thread, its notes and its first comments. A part that fails is logged where
    /// it is read and left out.
    static func load(_ query: ChapterCommentQuery) async -> ChapterData? {
        guard let thread = await ChapterComments.thread(for: query) else { return nil }
        var data = ChapterData(thread: thread, notes: await ChapterComments.notes(in: thread))
        do {
            let page = try await ChapterComments.comments(in: thread, sort: nil, page: 1)
            data.top = Array(page.comments.prefix(cardComments))
            data.total = page.total
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.network("⟐ chapter comments: the chapter's own comments failed", error: SourceFailure.loggable(error),
                              context: ["module": thread.module.id])
        }
        return data
    }

    private func data(forSpine spine: Int, title: String) -> ChapterData? {
        switch states[spine] {
        case .ready(let data): return data
        case .loading: return nil
        case nil:
            ask(spine: spine, title: title)
            return nil
        }
    }

    private func ask(spine: Int, title: String) {
        guard Self.isEnabled, let work, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            states[spine] = .ready(nil)
            return
        }
        states[spine] = .loading
        let query = ChapterCommentQuery(work: work, chapterTitle: title, chapterTitles: chapterTitles())
        tasks[spine] = Task { [weak self, load] in
            let found = await load(query)
            guard let self, !Task.isCancelled else { return }
            let data = found.flatMap { $0.isEmpty ? nil : $0 }
            self.states[spine] = .ready(data)
            self.tasks[spine] = nil
            if data != nil { self.updates.send(spine) }
        }
    }

    // MARK: - ReaderChapterDecorationSource

    func placements(forSpine spineIndex: Int, title: String, paragraphs: [String]) -> ReaderCommentPlacements? {
        guard let data = data(forSpine: spineIndex, title: title) else { return nil }
        let body = ChapterParagraphMatch.body(of: paragraphs, title: title)
        let keys = body.map(\.key)
        let chapterToken = ModuleCommentTargets.token(for: ModuleCommentTarget(thread: data.thread, paragraphID: nil, heading: title))
        let hasParagraphComments = data.thread.module.comments?.paragraph != nil
        var placements = ReaderCommentPlacements()

        /// The paragraph a site's item is about, and the comments tapping it opens: that
        /// paragraph's when the module reads them, else the chapter's.
        func place(_ reference: ModuleParagraphReference) -> (position: Int, token: String)? {
            guard let index = ChapterParagraphMatch.index(of: reference, in: keys, remoteCount: data.notes.paragraphCount) else { return nil }
            let position = body[index].position
            guard hasParagraphComments, !reference.id.isEmpty else { return (position, chapterToken) }
            let heading = String(paragraphs[position].trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return (position, ModuleCommentTargets.token(for: ModuleCommentTarget(thread: data.thread, paragraphID: reference.id,
                                                                                  heading: heading)))
        }

        for count in data.notes.counts {
            guard let place = place(count.paragraph), placements.bubbles[place.position] == nil,
                  let href = ReaderHTMLUtilities.moduleReviewHref(count: String(count.count), title: localized("段評"), token: place.token)
            else { continue }
            placements.bubbles[place.position] = .init(count: count.count, href: href, title: localized("段評"))
        }
        let hotTitle = ReaderCommentCardKind.hotComment.localizedTitle
        for hot in data.notes.hot {
            // One card under a paragraph: the site's first for it.
            guard let place = place(hot.paragraph), placements.cards[place.position] == nil,
                  let href = ReaderHTMLUtilities.moduleReviewHref(count: "", title: hotTitle, token: place.token) else { continue }
            placements.cards[place.position] = [.init(content: ReviewCardContent(
                kind: .hotComment, title: hotTitle, count: "", number: "",
                comments: [.init(user: hot.comment.author ?? "", likes: hot.comment.likes.map(String.init) ?? "", content: hot.comment.text)]),
                href: href)]
        }
        let sayTitle = ReaderCommentCardKind.authorSay.localizedTitle
        if let say = data.notes.authorSay,
           let href = ReaderHTMLUtilities.moduleReviewHref(count: "", title: sayTitle, token: chapterToken) {
            placements.chapterEnd.append(.init(content: ReviewCardContent(
                kind: .authorSay, title: sayTitle, count: "", number: "",
                comments: [.init(user: say.author ?? "", likes: "", content: say.text)]), href: href))
        }
        let chapterTitle = ReaderCommentCardKind.chapterSay.localizedTitle
        if !data.top.isEmpty || (data.total ?? 0) > 0,
           let href = ReaderHTMLUtilities.moduleReviewHref(count: String(data.total ?? data.top.count), title: chapterTitle,
                                                           token: chapterToken) {
            placements.chapterEnd.append(.init(content: ReviewCardContent(
                kind: .chapterSay, title: chapterTitle,
                count: data.total.map { String(format: localized("%d 條評論"), $0) } ?? "", number: data.total.map(String.init) ?? "",
                comments: data.top.map { .init(user: $0.author ?? "", likes: $0.likes.map(String.init) ?? "", content: $0.text) }),
                href: href))
        }
        return placements.isEmpty ? nil : placements
    }
}

/// What a tapped bubble or card opens: a module's comments in the app's own list, a source's
/// in its own page.
struct ReaderReviewSheetContent: View {
    let target: ReaderHTMLUtilities.ReviewTarget
    let onDismiss: (_ body: String?) -> Void

    var body: some View {
        if let comments = ModuleCommentTargets.target(target.moduleToken) {
            ChapterCommentsSheet(target: comments)
        } else {
            LegadoReviewBrowserView(target: target, onDismiss: onDismiss)
        }
    }
}
