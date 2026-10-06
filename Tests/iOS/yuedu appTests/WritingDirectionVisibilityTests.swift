import Foundation
import Testing
@testable import yuedu_app

/// 排版方向 is offered for books with no writing mode of their own — TXT, online
/// books and converted Aozora texts. Any other EPUB follows its own declaration.
@Suite("排版方向 visibility")
struct WritingDirectionVisibilityTests {
    @Test("TXT, online and converted Aozora books offer it; any other EPUB does not")
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

        #expect(Self.aozoraBook().allowsVerticalWritingMode)
    }

    @Test("a converted Aozora book opens the way 排版方向 lays it out, any other EPUB as its package declares")
    func openingDirection() {
        let epub = ReadingBook(title: "EPUB", source: "local_epub", contentFilename: "book.epub")
        #expect(epub.opensWithDeclaredEPUBFlow)

        let aozora = Self.aozoraBook()
        #expect(aozora.resolvedPipelineKind == .epub)
        #expect(!aozora.opensWithDeclaredEPUBFlow)

        var txt = ReadingBook(title: "TXT", contentFilename: "book.txt")
        txt.contentPipelineKind = .txt
        #expect(!txt.opensWithDeclaredEPUBFlow)
    }

    private static func aozoraBook() -> ReadingBook {
        var book = ReadingBook(title: "青空", source: "local_epub", contentFilename: "book.epub")
        book.aozora = AozoraBookSource(originalFilename: "book.aozora.txt",
                                       sourceEncoding: String.Encoding.shiftJIS.rawValue)
        return book
    }
}
