import Testing
@testable import yuedu_app

/// 排版方向 is offered for books with no writing mode of their own — TXT and online
/// books. An EPUB follows its own declaration.
@Suite("排版方向 visibility")
struct WritingDirectionVisibilityTests {
    @Test("TXT and online books offer it; an EPUB does not")
    func visibility() {
        var txt = ReadingBook(title: "TXT", contentFilename: "book.txt")
        txt.contentPipelineKind = .txt
        #expect(txt.allowsVerticalWritingMode)

        var online = ReadingBook(title: "Online", contentFilename: "")
        online.isOnline = true
        online.contentPipelineKind = .html
        #expect(online.allowsVerticalWritingMode)

        let epub = ReadingBook(title: "EPUB", source: "local_epub", contentFilename: "book.epub")
        #expect(!epub.allowsVerticalWritingMode)
    }
}
