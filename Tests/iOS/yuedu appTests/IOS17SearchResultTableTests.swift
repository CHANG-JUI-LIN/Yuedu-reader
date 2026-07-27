import Foundation
import Testing
@testable import yuedu_app

@Suite("iOS 17 native search result table")
struct IOS17SearchResultTableTests {
    @Test("navigation route freezes the tapped search snapshot")
    func navigationRouteFreezesTappedSnapshot() {
        let id = UUID(uuidString: "B1111111-2222-3333-4444-555555555555")!
        let tapped = SearchBook(id: id, name: "點擊時書名", author: "作者")
        let replacement = SearchBook(id: id, name: "後續發布書名", author: "作者")

        let route = SearchResultRoute(id: id, snapshot: tapped)
        let replacementRoute = SearchResultRoute(id: id, snapshot: replacement)

        #expect(route.snapshot === tapped)
        #expect(route.snapshot !== replacement)
        #expect(route == replacementRoute)
        #expect(Set([route, replacementRoute]).count == 1)
    }

    @Test("detail intro is sanitized and bounded before SwiftUI layout")
    func detailIntroIsSanitizedAndBounded() {
        let raw = String(
            repeating: "<p>這是一段不應在詳情頁重複排版的原始 HTML。</p>",
            count: 10_000
        )

        let intro = OnlineBookDetailPresentationPolicy.sanitizeIntro(raw)

        #expect(!intro.contains("<p>"))
        #expect(
            intro.count
                <= OnlineBookDetailPresentationPolicy.maximumIntroCharacters + 1
        )
        #expect(intro.hasSuffix("…"))
    }

    @Test("sanitized detail book does not retain raw HTML intro")
    func sanitizedDetailBookDoesNotRetainRawIntro() {
        let raw = String(repeating: "<p>完整網頁</p>", count: 10_000)
        let book = OnlineBook(
            name: "測試書",
            author: "作者",
            intro: raw,
            coverUrl: "",
            bookUrl: "https://example.com/book",
            tocUrl: "",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: UUID(),
            sourceName: "測試書源"
        )

        let sanitized = OnlineBookDetailPresentationPolicy.sanitized(book)

        #expect(book.intro == raw)
        #expect(sanitized.intro != raw)
        #expect(!sanitized.intro.contains("<p>"))
        #expect(
            sanitized.intro.count
                <= OnlineBookDetailPresentationPolicy.maximumIntroCharacters + 1
        )
    }

    @Test("detail metadata treats JavaScript sentinel title as missing")
    func detailMetadataDropsUndefinedTitle() {
        let book = OnlineBook(
            name: "undefined",
            author: "作者",
            intro: "簡介",
            coverUrl: "",
            bookUrl: "https://example.com/book",
            tocUrl: "",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: UUID(),
            sourceName: "書山聚合"
        )

        let sanitized = OnlineBookDetailPresentationPolicy.sanitized(book)

        #expect(sanitized.name.isEmpty)
    }

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
                        detailIntro: "已清洗且有界的詳情簡介",
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
        #expect(book.detailIntro == "已清洗且有界的詳情簡介")
        #expect(book.detailIntro(for: origin) == "已清洗且有界的詳情簡介")
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
