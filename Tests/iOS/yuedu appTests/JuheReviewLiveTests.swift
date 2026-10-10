import Foundation
import Testing
@testable import yuedu_app

private let juheReviewLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_JUHE_REVIEW_LIVE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_JUHE_REVIEW_LIVE_TESTS"] == "1"

/// 聚合段评: tapping a 段評 bubble showed a white sheet (reported 2026-10-10). Runs the real
/// source over the network and records exactly what the bubble's click hands the browser.
@Suite("聚合段评 review live", .serialized)
@MainActor
struct JuheReviewLiveTests {
    private static let sourcePath = "/Users/zhangruilin/Desktop/Test document/RULE/聚合段评.json"

    @Test(
        "a 段評 bubble opens a page with comments in it",
        .enabled(if: juheReviewLiveTestsEnabled, "Set RUN_JUHE_REVIEW_LIVE_TESTS=1"),
        .timeLimit(.minutes(4))
    )
    func bubbleOpensCommentPage() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        var loaded = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        loaded.id = UUID()
        let source = loaded

        let fetcher = BookSourceFetcher.shared
        let books = try await fetcher.search(query: "没钱修什么仙", in: source)
        print("⟐ juhe.live search=\(books.prefix(5).map(\.name))")
        let book = try #require(books.first { $0.name.contains("没钱修什么仙") })
        let info = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source, runtimeVariables: book.runtimeVariables)
        let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL, source: source, runtimeVariables: info.runtimeVariables,
            onFirstPageReady: nil, forceRefresh: true
        )
        var chapter = try #require(toc.chapters.first { $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator })
        if let runtimeVariables = toc.runtimeVariables ?? info.runtimeVariables, !runtimeVariables.isEmpty {
            chapter.runtimeVariables = runtimeVariables.merging(chapter.runtimeVariables ?? [:]) { _, own in own }
        }
        let bookID = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookID) }
        _ = try await fetcher.fetchChapterPackage(ref: chapter, bookId: bookID, source: source, chapterReferer: tocURL)
        let html = try #require(fetcher.loadNormalizedChapterHTMLSync(
            bookId: bookID, chapterIndex: chapter.index, expectedSourceURL: chapter.url, expectedTOCTitle: chapter.title
        ))
        print("⟐ juhe.live ydreview=\(html.components(separatedBy: "ydreview://").count - 1) img=\(html.components(separatedBy: "<img").count - 1) len=\(html.count)")
        let ns = html as NSString
        let marker = ns.range(of: "ydreview://")
        if marker.location != NSNotFound {
            let start = max(0, marker.location - 300)
            print("⟐ juhe.live sample=\(ns.substring(with: NSRange(location: start, length: min(900, ns.length - start))).replacingOccurrences(of: "\n", with: " "))")
        } else {
            print("⟐ juhe.live head=\(html.prefix(2000))")
        }
        let hrefStart = ns.range(of: "ydreview://")
        let tail = ns.substring(from: hrefStart.location)
        let href = String(tail.prefix { $0 != "\"" && $0 != "'" })
        let target = try #require(ReaderHTMLUtilities.reviewTarget(fromHref: href))
        print("⟐ juhe.live target url=\(target.url.prefix(200)) requiresJS=\(target.requiresSourceJS) js=\(target.sourceJS.prefix(300))")
        let resolved = try await LegadoReviewActionRunner.shared.resolve(target, source: source)
        let page = resolved.sourceBrowserPage
        print("⟐ juhe.live resolved url=\(resolved.url.prefix(200)) page=\(page != nil) htmlLen=\(page?.html?.count ?? -1) request=\(resolved.browserRequest?.url?.absoluteString.prefix(200) ?? "-")")
        print("⟐ juhe.live html head=\((page?.html ?? "").prefix(400).replacingOccurrences(of: "\n", with: " "))")
        // A page with no HTML of its own must come with the request that loads its URL —
        // the alternative is the white sheet that was reported.
        if let page, page.html == nil {
            #expect(resolved.browserRequest?.url?.absoluteString == page.baseURL)
        } else {
            #expect(!(page?.html ?? "").isEmpty || resolved.browserRequest != nil)
        }
    }
}
