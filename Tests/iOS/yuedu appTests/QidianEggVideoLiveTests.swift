@testable import YueduCoreText
import AVFoundation
import Foundation
import Testing
import UIKit
@testable import yuedu_app

private let qidianEggVideoLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_QIDIAN_EGG_LIVE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_QIDIAN_EGG_LIVE_TESTS"] == "1"

/// The user's recipe (2026-10-10): 《没钱修什么仙》, chapter 「彩蛋：视频：鄙视链顶端的白真真」,
/// tap play, the video plays inline in the page. Runs the real source over the network.
@Suite("Qidian egg video live", .serialized)
@MainActor
struct QidianEggVideoLiveTests {
    private static let sourcePath =
        "/Users/zhangruilin/Desktop/Test document/RULE/起点读书qm-行內影片.json"

    @Test(
        "the egg chapter reaches the reader as an inline video with its Referer",
        .enabled(if: qidianEggVideoLiveTestsEnabled, "Set RUN_QIDIAN_EGG_LIVE_TESTS=1"),
        .timeLimit(.minutes(3))
    )
    func eggChapterIsInlineVideo() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        var loaded = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        loaded.id = UUID()
        loaded.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        let source = loaded

        let fetcher = BookSourceFetcher.shared
        let books = try await fetcher.search(query: "没钱修什么仙", in: source)
        print("⟐ egg.live search=\(books.prefix(5).map(\.name))")
        let book = try #require(books.first { $0.name.contains("没钱修什么仙") })
        let info = try await fetcher.fetchBookInfoPackage(
            url: book.bookUrl, source: source, runtimeVariables: book.runtimeVariables
        )
        let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL, source: source, runtimeVariables: info.runtimeVariables,
            onFirstPageReady: nil, forceRefresh: true
        )
        let eggs = toc.chapters.filter { $0.title.contains("彩蛋") }
        print("⟐ egg.live toc=\(toc.chapters.count) eggs=\(eggs.map(\.title))")
        var chapter = try #require(toc.chapters.first { $0.title.contains("彩蛋") && $0.title.contains("鄙视链顶端的白真真") })
        if let runtimeVariables = toc.runtimeVariables ?? info.runtimeVariables, !runtimeVariables.isEmpty {
            chapter.runtimeVariables = runtimeVariables.merging(chapter.runtimeVariables ?? [:]) { _, own in own }
        }

        let bookID = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookID) }
        let package = try await fetcher.fetchChapterPackage(
            ref: chapter, bookId: bookID, source: source, chapterReferer: tocURL
        )
        print("⟐ egg.live content=\(package.content.prefix(1200))")
        let normalizedHTML = try #require(fetcher.loadNormalizedChapterHTMLSync(
            bookId: bookID, chapterIndex: chapter.index,
            expectedSourceURL: chapter.url, expectedTOCTitle: chapter.title
        ))
        print("⟐ egg.live normalized=\(normalizedHTML.prefix(1600))")
        #expect(normalizedHTML.contains("<video"))
        // The Referer the CDN requires survives into the chapter (403 without it).
        #expect(normalizedHTML.contains("#yd-imgh="))

        // The player sends that Referer: the asset built the way the reader builds it plays,
        // the same URL without headers does not (the CDN's 403, measured with curl).
        let srcPattern = try NSRegularExpression(pattern: #"<video[^>]*\ssrc="([^"]+)""#)
        let ns = normalizedHTML as NSString
        let match = try #require(srcPattern.firstMatch(in: normalizedHTML, range: NSRange(location: 0, length: ns.length)))
        let src = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
        let request = try await EPUBMediaURLResolver.playableRequest(
            for: EPUBMediaAttachment(kind: .video, sourceHref: src)
        )
        print("⟐ egg.live video=\(request.url) headers=\(request.headers)")
        let headered = HeaderedMediaAsset.make(url: request.url, headers: request.headers)
        #expect(try await headered.load(.isPlayable))
        let bare = AVURLAsset(url: request.url)
        let barePlayable = (try? await bare.load(.isPlayable)) ?? false
        #expect(!barePlayable)
    }
}
