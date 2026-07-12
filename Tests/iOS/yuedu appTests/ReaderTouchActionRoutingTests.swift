import Testing

@Suite("Reader Touch Action Routing")
struct ReaderTouchActionRoutingTests {
    @Test("every touch action maps to one explicit reader command")
    func mapsAction() {
        let mappings: [(TouchAction, ReaderTouchCommand)] = [
            (.none, .none),
            (.toggleMenu, .toggleMenu),
            (.prevPage, .previousPage),
            (.nextPage, .nextPage),
            (.previousChapter, .previousChapter),
            (.nextChapter, .nextChapter),
            (.toggleBookmark, .toggleBookmark),
            (.tableOfContents, .tableOfContents),
        ]

        for (action, command) in mappings {
            #expect(action.readerCommand == command)
        }
    }
}
