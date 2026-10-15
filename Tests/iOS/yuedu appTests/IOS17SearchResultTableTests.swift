import Foundation
import Testing
import UIKit
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
        let content = IOS17SearchResultTableContent(rows: [row], hasMore: false)

        #expect(!content.requiresReload(comparedTo: content))
    }

    @Test("row, more-pages and can-load changes reload the UIKit table")
    func changedContentReloads() {
        let original = IOS17SearchResultTableContent(rows: [makeRow()], hasMore: false)
        let changedRow = IOS17SearchResultTableContent(rows: [makeRow(title: "第二本書")], hasMore: false)
        let changedMore = IOS17SearchResultTableContent(rows: [makeRow()], hasMore: true)
        let nowLoadable = IOS17SearchResultTableContent(rows: [makeRow()], hasMore: true, canLoadMore: true)

        #expect(changedRow.requiresReload(comparedTo: original))
        #expect(changedMore.requiresReload(comparedTo: original))
        // A search that ends with the spinner on screen asks again: the reload redisplays it.
        #expect(nowLoadable.requiresReload(comparedTo: changedMore))
    }

    @Test("the works' rows and status lines reload the UIKit table")
    func worksChangesReload() {
        // Rewritten in unified search 4c-3: the tab root's 書架, 我的書庫, 來源配置, 公有書庫 and
        // 書目資料庫 sections became one list of works, so its parts reload as one section.
        func content(_ rows: [IOS17SearchResultTableRow], leading: String? = nil) -> IOS17SearchResultTableContent {
            var status = UnifiedSearchStatus()
            status.leading = leading
            return IOS17SearchResultTableContent(rows: [], hasMore: false,
                                                 works: IOS17SearchWorksSection(rows: rows, status: status))
        }
        let typed = content([makeRow(title: "羅生門")])
        #expect(!typed.requiresReload(comparedTo: typed))
        #expect(content([]).requiresReload(comparedTo: typed))
        #expect(content([], leading: "搜索中…").requiresReload(comparedTo: content([])))
    }

    /// Search 9b: no 載入更多 to tap. The list's last row is a spinner while more pages exist,
    /// and showing it asks for the next page, once the search is idle.
    @Test("showing the last row loads the next page by itself, only when it can")
    @MainActor
    func lastRowLoadsMore() throws {
        let controller = IOS17SearchResultTableViewController()
        var loads = 0
        func show(canLoadMore: Bool) throws {
            controller.update(
                content: IOS17SearchResultTableContent(rows: [makeRow(), makeRow(title: "第二本書", id: UUID())], hasMore: true,
                                                       canLoadMore: canLoadMore),
                onSelect: { _ in }, onLoadMore: { loads += 1 }, onSelectWork: { _ in })
            let table = controller.tableView!
            let last = IndexPath(row: table.numberOfRows(inSection: 0) - 1, section: 0)
            #expect(last.row == 2, "the two books, then the spinner")
            let cell = try #require(table.dataSource?.tableView(table, cellForRowAt: last))
            #expect(cell.accessibilityLabel == localized("正在載入更多"))
            #expect(!(controller.tableView(table, shouldHighlightRowAt: last)), "nothing to tap")
            controller.tableView(table, willDisplay: cell, forRowAt: last)
        }
        try show(canLoadMore: false)
        #expect(loads == 0, "a search still running is not asked again")
        try show(canLoadMore: true)
        #expect(loads == 1)
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
        #expect(row.content.title == "測試書")
        #expect(row.content.titleTag == localized("有聲書"))
        // The tag names the kind, so the detail is the source count alone.
        #expect(row.content.detail == String(format: localized("%d 源"), 1))
        // The row lists no description, so the source's raw HTML never reaches it.
        #expect(!row.content.accessibilityLabel.contains("<html>"))
        #expect(row.coverURL == "https://example.com/cover.jpg")
        #expect(book.detailIntro == "已清洗且有界的詳情簡介")
        #expect(book.detailIntro(for: origin) == "已清洗且有界的詳情簡介")
    }

    private func makeRow(title: String = "第一本書",
                         id: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!) -> IOS17SearchResultTableRow {
        IOS17SearchResultTableRow(
            id: id,
            content: SearchBookListRowContent(
                title: title,
                titleTag: nil,
                author: "作者",
                detail: "小說 · 2 源"
            ),
            coverURL: "https://example.com/cover.jpg"
        )
    }
}
