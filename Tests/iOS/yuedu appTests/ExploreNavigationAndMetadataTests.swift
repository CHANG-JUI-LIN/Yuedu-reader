import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

@Suite("Explore navigation and metadata")
struct ExploreNavigationAndMetadataTests {
    @Test("explore and search result routes can share one navigation path")
    func exploreAndSearchRoutesShareNavigationPath() {
        var navigation = ExploreNavigationPath()
        navigation.push(.searchInSource(sourceURL: "https://fixture.example"))
        navigation.path.append(
            SearchResultRoute(
                id: UUID(),
                snapshot: makeBook()
            )
        )

        #expect(navigation.path.count == 2)
        navigation.pop()
        #expect(navigation.path.count == 1)
        navigation.pop()
        #expect(navigation.path.isEmpty)
    }

    @Test("a source's search from its discover page is a route of its own for each query")
    func searchInSourceCarriesItsQuery() {
        let url = "https://fixture.example"
        #expect(ExploreNavigationRoute.searchInSource(sourceURL: url) == .searchInSource(sourceURL: url, query: ""))
        #expect(ExploreNavigationRoute.searchInSource(sourceURL: url, query: "三體")
            == .searchInSource(sourceURL: url, query: "三體"))
        #expect(ExploreNavigationRoute.searchInSource(sourceURL: url, query: "三體")
            != .searchInSource(sourceURL: url, query: "球狀閃電"))
        let routes: Set<ExploreNavigationRoute> = [.searchInSource(sourceURL: url, query: "三體"),
                                                   .searchInSource(sourceURL: url, query: "球狀閃電")]
        #expect(routes.count == 2, "the query is hashed with the source")
    }

    @Test("detail tags augment rather than erase discover tags")
    func detailTagsPreserveDiscoverTags() {
        let tags = OnlineBookMetadataFormatter.tags(
            detailKind: "玄幻\n東方玄幻",
            fallbackKind: "玄幻\n東方玄幻\n限免中"
        )

        #expect(tags == ["玄幻", "東方玄幻", "限免中"])
    }

    @Test("unit-only detail word count falls back to the discover value")
    func unitOnlyWordCountUsesFallback() {
        let wordCount = OnlineBookMetadataFormatter.wordCount(
            detailValue: "字",
            fallbackValue: "373.56萬字"
        )

        #expect(wordCount == "373.56萬字")
    }

    @Test("meaningful detail word count remains authoritative")
    func meaningfulDetailWordCountWins() {
        let wordCount = OnlineBookMetadataFormatter.wordCount(
            detailValue: "374萬字",
            fallbackValue: "373.56萬字"
        )

        #expect(wordCount == "374萬字")
    }

    // 2026-11-12: the length is said in the language's large unit, not counted out.

    @Test("a count is read in whatever unit the source wrote it")
    func wordCountUnits() {
        #expect(OnlineBookMetadataFormatter.characterCount(in: "373.56萬字") == 3_735_600)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "12.3万字") == 123_000)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "1,234,567字") == 1_234_567)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "3735600") == 3_735_600)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "1.2億字") == 120_000_000)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "2024-01-01 更新 · 200万字") == 2_000_000)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "連載中") == nil)
        #expect(OnlineBookMetadataFormatter.characterCount(in: "2024-01-01 更新") == nil)
    }

    @Test("繁體中文 says it in 萬, one decimal at most")
    func wordCountInTenThousands() {
        let locale = Locale(identifier: "zh-Hant")
        #expect(OnlineBookMetadataFormatter.compactCount(3_735_600, locale: locale) == "373.6萬")
        #expect(OnlineBookMetadataFormatter.compactCount(1_200_000, locale: locale) == "120萬")
        #expect(OnlineBookMetadataFormatter.compactCount(8_000, locale: locale) == "8000")
    }

    @Test("a text with no count is kept while it is short, and nothing is said of an empty one")
    func wordCountWithoutANumber() {
        let locale = Locale(identifier: "zh-Hant")
        #expect(OnlineBookMetadataFormatter.roundedWordCount("連載中", locale: locale) == "連載中")
        #expect(OnlineBookMetadataFormatter.roundedWordCount("  ", locale: locale) == nil)
        #expect(OnlineBookMetadataFormatter.roundedWordCount(String(repeating: "很長的說明", count: 5), locale: locale) == nil)
    }

    private func makeBook() -> OnlineBook {
        OnlineBook(
            name: "夜無疆",
            author: "辰東",
            intro: "",
            coverUrl: "",
            bookUrl: "https://example.com/book/1",
            tocUrl: "https://example.com/book/1",
            wordCount: "373.56萬字",
            lastChapter: "",
            kind: "玄幻\n東方玄幻\n限免中",
            sourceId: UUID(),
            sourceName: "Test Source"
        )
    }
}
