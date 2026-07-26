import Foundation
import Testing
@testable import yuedu_app

@Suite("Search result cover URL policy")
struct SearchResultCoverURLPolicyTests {
    @Test("accepts bounded HTTPS cover URLs")
    func acceptsHTTPSURL() {
        let raw = "  https://img.example.com/封面.jpg?size=large  "

        let normalized = SearchResultCoverURLPolicy.normalizedString(raw)

        #expect(normalized.hasPrefix("https://img.example.com/"))
        #expect(normalized.contains("size=large"))
    }

    @Test("resolves a bounded relative cover against the source")
    func resolvesRelativeURL() {
        let normalized = SearchResultCoverURLPolicy.normalizedString(
            "/covers/book.jpg",
            baseURL: "https://books.example.com/search?q=test"
        )

        #expect(normalized == "https://books.example.com/covers/book.jpg")
    }

    @Test("rejects inline data, HTML, and oversized cover payloads")
    func rejectsUnboundedPayloads() {
        let oversized = "https://img.example.com/" + String(
            repeating: "a",
            count: SearchResultCoverURLPolicy.maximumUTF8ByteCount
        )

        #expect(SearchResultCoverURLPolicy.normalizedString(
            "data:image/jpeg;base64,AAAA"
        ).isEmpty)
        #expect(SearchResultCoverURLPolicy.normalizedString(
            #"<img src="https://img.example.com/cover.jpg">"#
        ).isEmpty)
        #expect(SearchResultCoverURLPolicy.normalizedString(oversized).isEmpty)
    }

    @Test("presentation preparation removes an oversized cover before MainActor")
    func preparationRemovesOversizedCover() async {
        let source = BookSource(
            bookSourceUrl: "https://books.example.com",
            bookSourceName: "測試源"
        )
        let oversizedCover = "https://img.example.com/" + String(
            repeating: "a",
            count: SearchResultCoverURLPolicy.maximumUTF8ByteCount
        )
        let book = OnlineBook(
            name: "測試書",
            author: "作者",
            intro: "",
            coverUrl: oversizedCover,
            bookUrl: "https://books.example.com/book/1",
            tocUrl: "",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName
        )

        let prepared = await SearchResultPresentationBuilder.prepareBatch(
            [book],
            source: source
        )

        #expect(prepared.count == 1)
        #expect(prepared[0].preparedOrigin.origin.coverUrl.isEmpty)
    }
}
