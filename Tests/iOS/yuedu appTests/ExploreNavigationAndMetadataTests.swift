import Foundation
import Testing
@testable import yuedu_app

@Suite("Explore navigation and metadata")
struct ExploreNavigationAndMetadataTests {
    @Test("closing a book opened from a category returns to that category")
    func closingBookReturnsToCategory() {
        let sectionID = UUID()
        var navigation = ExploreNavigationPath()
        navigation.push(.category(sectionID))
        navigation.push(.book(makeBook()))

        navigation.pop()

        #expect(navigation.path == [.category(sectionID)])
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
