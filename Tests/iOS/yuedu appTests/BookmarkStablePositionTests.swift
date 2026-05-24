import Testing
import Foundation
@testable import yuedu_app

@Suite("BookmarkStablePosition", .serialized)
struct BookmarkStablePositionTests {

    @Test("top bar bookmark stores chapter start as stable position")
    func topBarBookmarkStoresChapterStart() {
        let bookmark = Bookmark(
            chapterIndex: 3,
            chapterTitle: "第三章",
            position: .chapterStart(3),
            excerpt: "章內中段"
        )

        #expect(bookmark.position == CoreTextReadingPosition(spineIndex: 3, charOffset: 0))
        #expect(bookmark.isChapterStartBookmark)
    }

    @Test("chapter start bookmarks in the same chapter share identity")
    func sameChapterTopBarBookmarksShareIdentity() {
        let first = Bookmark(
            chapterIndex: 2,
            chapterTitle: "第二章",
            position: .chapterStart(2),
            excerpt: "第一頁"
        )
        let second = Bookmark(
            chapterIndex: 2,
            chapterTitle: "第二章",
            position: .chapterStart(2),
            excerpt: "同章不同頁"
        )

        #expect(first.hasSameStableLocation(as: second))
    }

    @Test("stable sort follows spine and char offset")
    func stableSortFollowsPosition() {
        let later = Bookmark(
            chapterIndex: 4,
            chapterTitle: "第四章",
            position: CoreTextReadingPosition(spineIndex: 4, charOffset: 0)
        )
        let earlier = Bookmark(
            chapterIndex: 1,
            chapterTitle: "第一章",
            position: CoreTextReadingPosition(spineIndex: 1, charOffset: 120)
        )

        #expect([later, earlier].sortedByStablePosition().map(\.chapterIndex) == [1, 4])
    }

    @Test("legacy page index bookmark decodes to chapter start")
    func legacyPageIndexBookmarkDecodesToChapterStart() throws {
        let json = """
        {
            "chapterIndex": 7,
            "chapterTitle": "第七章",
            "pageIndex": 123,
            "note": "",
            "excerpt": "舊資料"
        }
        """

        let bookmark = try JSONDecoder().decode(Bookmark.self, from: Data(json.utf8))

        #expect(bookmark.position == .chapterStart(7))
        #expect(bookmark.isChapterStartBookmark)
    }
}
