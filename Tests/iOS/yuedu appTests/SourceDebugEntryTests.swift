import Foundation
import Testing
@testable import yuedu_app

/// Which source-debugging actions each kind of book gets (#84, #102, #104, #105): the detail
/// page's 「更多」 and the reader's 更多 build their items from these same functions.
@MainActor
struct SourceDebugEntryTests {
    private let book = ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot.detailPage(
        name: "示例書",
        author: "作者",
        coverURL: "",
        bookURL: "https://example.com/book/1",
        tocURL: "https://example.com/book/1/toc",
        intro: "",
        runtimeVariables: [:]
    )

    private func source(listening: Bool, customButton: Bool = false) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "示例來源")
        source.eventListener = listening
        source.ruleContent.callBackJs = listening ? "result" : nil
        source.customButton = customButton
        return source
    }

    private func callBacks(for source: BookSource) -> BookDetailSourceCallBacks? {
        BookDetailSourceCallBacks(
            source: source,
            book: book,
            runtimeVariables: [:],
            labels: [],
            shelfBookId: nil,
            bookStore: BookStore(metadataFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SourceDebugEntryTests-\(UUID().uuidString).json")),
            send: { _ in }
        )
    }

    private func routes(for source: BookSource) -> [BookDetailMoreRoute]? {
        BookDetailSourceMenuActions(source: source, book: book, callBacks: callBacks(for: source))?
            .items.map(\.route)
    }

    // MARK: - Detail page 「更多」

    /// #105: the copies were reached only through a listening source's callbacks, so only
    /// 書山聚合 (which listens) had them.
    @Test func sourceThatDoesNotListenGetsOpenWebPageAndBothCopies() {
        let plain = source(listening: false)
        #expect(callBacks(for: plain) == nil)
        #expect(routes(for: plain) == [.openWebPage, .copyBookURL, .copyTOCURL])
    }

    /// `customButton` without `callBackJs` has nothing to send its tap to.
    @Test func customButtonFlagWithoutListeningAddsNothing() {
        #expect(routes(for: source(listening: false, customButton: true)) == [.openWebPage, .copyBookURL, .copyTOCURL])
    }

    @Test func listeningSourceKeepsShareAndClearCacheAroundTheNewItems() {
        #expect(routes(for: source(listening: true))
            == [.openWebPage, .share, .copyBookURL, .copyTOCURL, .clearCache])
    }

    @Test func listeningSourceWithCustomButtonPutsItFirst() {
        #expect(routes(for: source(listening: true, customButton: true))
            == [.customButton, .openWebPage, .share, .copyBookURL, .copyTOCURL, .clearCache])
    }

    @Test func pageWithoutSourceHasNoSourceItems() {
        #expect(BookDetailSourceMenuActions(source: nil, book: book, callBacks: nil) == nil)
    }

    // MARK: - Reader 更多

    @Test func onlineChapterWithSourceGetsCopyAndDebug() {
        #expect(ReaderSourceDebugActions.ids(chapterURL: "https://example.com/1.html", hasSource: true)
            == [.copyChapterURL, .debugContent])
    }

    /// With the source gone there is no 調試規則 to open.
    @Test func onlineChapterWithoutSourceGetsNeither() {
        #expect(ReaderSourceDebugActions.ids(chapterURL: "https://example.com/1.html", hasSource: false).isEmpty)
    }

    @Test func bookWithoutOnlineChapterGetsNeither() {
        #expect(ReaderSourceDebugActions.ids(chapterURL: nil, hasSource: true).isEmpty)
        #expect(ReaderSourceDebugActions.ids(chapterURL: "", hasSource: true).isEmpty)
    }

    /// Not 自定義 items, so 自定義 cannot hide them.
    @Test func readerDebugActionsAreNotChromeCustomizationItems() {
        #expect(ReaderChromeActionItem(.copyChapterURL) == nil)
        #expect(ReaderChromeActionItem(.debugContent) == nil)
    }
}
