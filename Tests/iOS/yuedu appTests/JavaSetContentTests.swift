import Foundation
import Testing
@testable import yuedu_app

/// Legado's `java` in a rule step is that step's `AnalyzeRule`, and `java.setContent` sets its
/// content (`AnalyzeRule.setContent`): the step's later reads see it, and `BookList` gives the
/// reader each row with `setContent(item)` (legado-E `BookList.kt:217`) before the row's fields
/// are read. 爱发电 (YCK1331) sets its posts page in the discover list script; each row's URL
/// script then read that page instead of the row, and every album URL came out `album_id=`.
@Suite("java.setContent", .serialized)
struct JavaSetContentTests {
    private static let albums = #"{"data":{"list":[{"album_id":"a1","title":"A"},{"album_id":"a2","title":"B"}]}}"#

    private func exploreSource() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "setContent test"
        source.bookSourceUrl = "https://set-content.test"
        // The albums of the page, then the posts of a page the script sets.
        source.ruleExplore.bookList = #"""
            <js>var rows = java.getElements("$.data.list[*]"); java.setContent('{"data":{"list":[{"post_id":"p1","title":"P"}]}}'); rows.concat(java.getElements("$.data.list[*]"))</js>
            """#
        source.ruleExplore.name = "$.title"
        // 爱发电's bookUrl: a post's own id, or the album's — `album_id` without `$.`, which
        // Jayway reads as `$.album_id` (`PathCompiler.compile`).
        source.ruleExplore.bookUrl = #"""
            <js>String(java.getString("$.post_id")) ? "/post/" + java.getString("$.post_id") : "/album/" + java.getString("album_id")</js>
            """#
        return source
    }

    @Test("a row's scripts read the row, not what the list script set")
    func rowsReadTheirOwnContent() {
        let source = exploreSource()
        let books = ModernParserBridge(source: source).parseExploreResults(
            html: Self.albums, baseURL: "https://set-content.test/list", source: source
        )
        #expect(books.map(\.name) == ["A", "B", "P"])
        #expect(books.map(\.bookUrl) == [
            "https://set-content.test/album/a1",
            "https://set-content.test/album/a2",
            "https://set-content.test/post/p1",
        ])
    }

    @Test("what one parse's script set is gone in the next parse of the same context")
    func nextParseReadsItsOwnPage() throws {
        var source = exploreSource()
        source.ruleBookInfo.name = #"@js:java.getString("$.name")"#
        let parser = ModernParserBridge(source: source)
        _ = parser.parseExploreResults(html: Self.albums, baseURL: "https://set-content.test/list", source: source)
        let info = try parser.parseBookInfo(
            html: #"{"name":"本書"}"#, bookUrl: "https://set-content.test/b",
            baseURL: "https://set-content.test/b", source: source
        )
        #expect(info.name == "本書")
    }

    @Test("java.setContent(null) throws, as Kotlin's AssertionError does")
    func nullContentThrows() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://set-content.test"
        source.ruleBookInfo.name = #"@js:try { java.setContent(null); "no" } catch (e) { String(e.message || e) }"#
        let info = try ModernParserBridge(source: source).parseBookInfo(
            html: #"{"name":"x"}"#, bookUrl: "https://set-content.test/b",
            baseURL: "https://set-content.test/b", source: source
        )
        #expect(info.name == "内容不可空（Content cannot be null）")
    }
}
