import Foundation

// legado-E / MD3 `SourceCallBack` events the reader sends (`SourceCallBackService`):
// startRead when the book opens, saveRead from its own progress saves, endRead on a real exit.
extension ReaderView {

    /// The online book on screen: the shelf record, or the reader's snapshot of a book read
    /// without adding it.
    private var callBackBook: ReadingBook? {
        let current = book ?? snapshotBook
        guard let current, current.isOnline else { return nil }
        return current
    }

    func notifySourceStartRead() {
        // However the reader is left later, its source hears endRead once.
        readerNavigator?.readerClosingHandler = { notifySourceEndRead() }
        guard let book = callBackBook else { return }
        SourceCallBackService.notify(
            .startRead, book: book, chapter: currentOnlineChapter.map(SourceCallBackService.chapterSnapshot)
        )
    }

    func notifySourceSaveRead(isPageTurn: Bool) {
        guard let book = callBackBook else { return }
        SourceCallBackService.noteSaveRead(book: book, chapter: currentOnlineChapter, isPageTurn: isPageTurn)
    }

    /// From the real exit — the coordinator's close, or `dismissReaderPresentation` for a
    /// reader presented without one — not `onDisappear`, which also fires when the reader is
    /// only covered by a sheet or a pushed page.
    func notifySourceEndRead() {
        guard let book = callBackBook else { return }
        SourceCallBackService.notify(
            .endRead, book: book, chapter: currentOnlineChapter.map(SourceCallBackService.chapterSnapshot)
        )
    }

    /// The online book's source, for its `customButton`.
    var readerSource: BookSource? {
        guard let id = callBackBook?.bookSourceId else { return nil }
        return BookSourceStore.shared.source(id: id)
    }

    /// The reader menu's 自訂按鈕 (legado `ReadMenu.tvCustomBtn`): clickCustomButton with the
    /// chapter on screen. A page the script builds shows in the 段評 sheet.
    func runSourceCustomButton() {
        guard let book = callBackBook, let source = readerSource else { return }
        let chapter = currentOnlineChapter.map(SourceCallBackService.chapterSnapshot)
        Task { @MainActor in
            let outcome = await SourceCallBackService.tap(
                .clickCustomButton, source: source,
                book: SourceCallBackService.snapshot(of: book, chapter: chapter),
                runtimeVariables: book.runtimeVariables ?? [:], chapter: chapter
            )
            if let page = outcome.page {
                reviewTarget = page
            }
        }
    }
}
