import Foundation
import Testing
@testable import yuedu_app

@Suite("iOS 17 native search result table")
struct IOS17SearchResultTableTests {
    @Test("search detail identity stays stable across destination rebuilds")
    func searchDetailIdentityStaysStable() {
        let searchBookID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let originID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!

        #expect(
            SearchResultDetailIdentity.onlineBookID(
                searchBookID: searchBookID,
                originID: originID
            ) == originID
        )
        #expect(
            SearchResultDetailIdentity.onlineBookID(
                searchBookID: searchBookID,
                originID: nil
            ) == searchBookID
        )
    }

    @Test("search result navigation uses one presentation mechanism per iOS version")
    func navigationUsesOnePresentationMechanismPerOSVersion() {
        #expect(
            SearchResultNavigationMode.mode(forIOSMajorVersion: 17)
                == .selectedItem
        )
        #expect(
            SearchResultNavigationMode.mode(forIOSMajorVersion: 18)
                == .valueRoute
        )
        #expect(
            SearchResultNavigationMode.mode(forIOSMajorVersion: 26)
                == .valueRoute
        )
    }

    @Test("unchanged content does not reload the UIKit table")
    func unchangedContentDoesNotReload() {
        let row = makeRow()
        let content = IOS17SearchResultTableContent(
            rows: [row],
            showsLoadMore: false
        )

        #expect(!content.requiresReload(comparedTo: content))
    }

    @Test("row or load-more changes reload the UIKit table")
    func changedContentReloads() {
        let original = IOS17SearchResultTableContent(
            rows: [makeRow()],
            showsLoadMore: false
        )
        let changedRow = IOS17SearchResultTableContent(
            rows: [makeRow(title: "第二本書")],
            showsLoadMore: false
        )
        let changedLoadMore = IOS17SearchResultTableContent(
            rows: [makeRow()],
            showsLoadMore: true
        )

        #expect(changedRow.requiresReload(comparedTo: original))
        #expect(changedLoadMore.requiresReload(comparedTo: original))
    }

    @Test("UIKit row maps only bounded search presentation values")
    @MainActor
    func rowUsesBoundedPresentation() {
        let sourceID = UUID()
        let origin = BookOrigin(
            sourceId: sourceID,
            sourceName: "測試書源",
            bookUrl: "https://example.com/book",
            tocUrl: "https://example.com/toc",
            coverUrl: "https://example.com/cover.jpg",
            intro: String(repeating: "<html>raw</html>", count: 10_000),
            lastChapter: "第十章",
            wordCount: "10 萬字",
            kind: "audio",
            runtimeVariables: nil
        )
        let book = SearchBook(
            name: "測試書",
            author: "作者",
            preparedOrigins: [
                PreparedSearchOrigin(
                    origin: origin,
                    presentation: SearchOriginPresentation(
                        contentKind: .audio,
                        displayIntro: "已截斷簡介",
                        introCharacterCount: origin.intro.count,
                        lastChapterTitleCandidate: "第十章",
                        introTitleCandidate: ""
                    )
                )
            ]
        )

        let row = IOS17SearchResultTableRow(searchBook: book)

        #expect(row.id == book.id)
        #expect(row.title == "測試書")
        #expect(row.intro == "已截斷簡介")
        #expect(row.coverURL == "https://example.com/cover.jpg")
        #expect(row.sourceCount == 1)
        #expect(row.showsAudiobookBadge)
    }

    private func makeRow(title: String = "第一本書") -> IOS17SearchResultTableRow {
        IOS17SearchResultTableRow(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: title,
            author: "作者",
            intro: "簡介",
            coverURL: "https://example.com/cover.jpg",
            sourceCount: 2,
            showsAudiobookBadge: false
        )
    }
}
