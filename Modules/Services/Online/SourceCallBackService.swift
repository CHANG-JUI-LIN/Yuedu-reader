import Foundation

/// legado-E / MD3 `SourceCallBack`: hands a book source's `ruleContent.callBackJs` the book and
/// UI events it asked for (`eventListener`). Every screen goes through here; the script itself
/// runs in `LegadoReviewActionRunner.runCallBack`, on the source's shared session.
///
/// Events are fired from the places the reader acts — the detail page's buttons, the reader
/// opening and closing, its own progress saves, a shelf refresh — never from the library store:
/// the store is also written by iCloud and Firestore merges, imports and migrations, and legado
/// never runs a source's script for those.
@MainActor
enum SourceCallBackService {

    /// The source of an online book, when it listens for events and has a script to run.
    static func listeningSource(id: UUID?) -> BookSource? {
        guard let id, let source = BookSourceStore.shared.source(id: id), isListening(source) else { return nil }
        return source
    }

    static func isListening(_ source: BookSource?) -> Bool {
        guard let source, source.eventListener == true else { return false }
        return !(source.ruleContent.callBackJs ?? "").isEmpty
    }

    /// legado shows the source-controlled button whenever the source sets `customButton`.
    static func showsCustomButton(_ source: BookSource?) -> Bool {
        source?.customButton == true
    }

    /// `book` as the script sees it, from a shelf record.
    static func snapshot(
        of book: ReadingBook,
        chapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot? = nil
    ) -> ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot {
        let variables = book.runtimeVariables ?? [:]
        return .init(
            durChapterIndex: chapter?.index ?? Int(variables["book.durChapterIndex"] ?? "") ?? 0,
            durChapterTitle: chapter?.title ?? variables["book.durChapterTitle"] ?? "",
            order: Int(variables["book.order"] ?? "") ?? 0,
            type: Int(variables["book.type"] ?? "") ?? 0,
            imageStyle: variables["book.imageStyle"] ?? "",
            name: book.title,
            author: book.author,
            coverURL: book.coverUrl ?? "",
            bookURL: book.bookInfoURL ?? book.source,
            tocURL: book.tocURL ?? "",
            abstract: variables["book.abstract"] ?? ""
        )
    }

    // MARK: - Notifications (legado `callBackBook` / `callBackSource`)

    /// addBookShelf, delBookShelf, startRead, endRead, saveRead: the app does not wait.
    static func notify(
        _ event: SourceCallBackEvent,
        book: ReadingBook,
        chapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot? = nil,
        result: String? = nil
    ) {
        guard book.isOnline, let source = listeningSource(id: book.bookSourceId) else { return }
        let snapshot = snapshot(of: book, chapter: chapter)
        let variables = book.runtimeVariables ?? [:]
        Task {
            _ = await LegadoReviewActionRunner.shared.runCallBack(
                event, source: source, book: snapshot, chapter: chapter, result: result,
                runtimeVariables: variables, presentToast: presentToast
            )
        }
    }

    /// `chapter` for a script, from the TOC entry the reader is on.
    static func chapterSnapshot(_ chapter: OnlineChapterRef) -> ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot {
        .init(index: chapter.index, title: chapter.title, order: chapter.index, url: chapter.url, isVip: chapter.isVip)
    }

    /// The chapter `saveRead` last reported for each book.
    private static var lastSavedChapter: [UUID: Int] = [:]

    /// saveRead, as legado's `ReadBook.saveRead` sends it: when the chapter changed, or on a
    /// save that is not a page turn (leaving the reader, going to the background) — not on
    /// every page. `result` is the save time in milliseconds, legado's `durChapterTime`.
    static func noteSaveRead(book: ReadingBook, chapter: OnlineChapterRef?, isPageTurn: Bool) {
        guard let chapter else { return }
        let changed = lastSavedChapter[book.id] != chapter.index
        guard changed || !isPageTurn else { return }
        lastSavedChapter[book.id] = chapter.index
        notify(
            .saveRead, book: book, chapter: chapterSnapshot(chapter),
            result: String(Int64(Date().timeIntervalSince1970 * 1000))
        )
    }

    /// startShelfRefresh / endShelfRefresh, once per listening source among the shelf's
    /// online books — legado runs these with no book or chapter.
    static func notifyShelfRefresh(_ event: SourceCallBackEvent, books: [ReadingBook]) {
        let sources = Set(books.filter(\.isOnline).compactMap(\.bookSourceId)).compactMap { listeningSource(id: $0) }
        for source in sources {
            let empty = ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot(
                durChapterIndex: 0, durChapterTitle: "", order: 0, type: 0, imageStyle: "",
                name: "", author: "", coverURL: "", bookURL: "", tocURL: "", abstract: ""
            )
            Task {
                _ = await LegadoReviewActionRunner.shared.runCallBack(
                    event, source: source, book: empty, chapter: nil, result: nil,
                    runtimeVariables: [:], presentToast: presentToast
                )
            }
        }
    }

    // MARK: - Taps (legado `callBackBtn`)

    /// Runs a tap event. When the source does not listen, nothing runs and the tap is not
    /// handled, so the caller does what it does without a script.
    static func tap(
        _ event: SourceCallBackEvent,
        source: BookSource?,
        book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot,
        runtimeVariables: [String: String],
        chapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot? = nil,
        result: String? = nil
    ) async -> SourceCallBackOutcome {
        guard let source, isListening(source) else {
            return SourceCallBackOutcome(handled: false, failed: false, page: nil)
        }
        return await LegadoReviewActionRunner.shared.runCallBack(
            event, source: source, book: book, chapter: chapter, result: result,
            runtimeVariables: runtimeVariables, presentToast: presentToast
        )
    }

    /// Whether the app should go on with its own action: the script neither took the tap over
    /// nor failed (legado: a failing script only logs).
    static func shouldFallBack(_ outcome: SourceCallBackOutcome) -> Bool {
        !outcome.handled && !outcome.failed
    }

    // MARK: - legado's own actions when a script does not take a tap

    /// legado `SearchActivity.start(keyword)` / `start(source, keyword)`: the app-wide search
    /// sheet, scoped to one source when `sourceURL` is given.
    static func requestSearch(keyword: String, sourceURL: String? = nil) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var info: [String: String] = ["keyword": trimmed]
        if let sourceURL { info["sourceURL"] = sourceURL }
        NotificationCenter.default.post(name: .bookSourceRequestedSearch, object: nil, userInfo: info)
    }

    private static func presentToast(_ message: String) {
        BookSourceFormLoginView.presentToastAlert(message: message)
    }
}
