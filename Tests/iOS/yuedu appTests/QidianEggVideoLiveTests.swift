@testable import YueduCoreText
import Foundation
import Testing
import UIKit
import WebKit
@testable import yuedu_app

private let qidianEggVideoLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_QIDIAN_EGG_LIVE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_QIDIAN_EGG_LIVE_TESTS"] == "1"

/// The user's recipe (2026-10-10): 《没钱修什么仙》, chapter 「彩蛋：视频：鄙视链顶端的白真真」,
/// tap play, the video plays inline in the page with its 弹幕 (as qimo_yuedu's player shows
/// them). Runs the real source over the network.
@Suite("Qidian egg video live", .serialized)
@MainActor
struct QidianEggVideoLiveTests {
    private static var sourcePath: String {
        ProcessInfo.processInfo.environment["TEST_RUNNER_QIDIAN_EGG_SOURCE"]
            ?? ProcessInfo.processInfo.environment["QIDIAN_EGG_SOURCE"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/起点读书qm-行內影片.json"
    }

    @Test(
        "the egg chapter reaches the reader as the source's player page, with its 弹幕, and plays",
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
        // The 彩蛋 arrives as the source's own player page — video plus 弹幕 — loaded in place.
        let srcPattern = try NSRegularExpression(pattern: #"<iframe[^>]*\ssrc="(data:text/html[^"]+)""#)
        let ns = normalizedHTML as NSString
        let match = try #require(srcPattern.firstMatch(in: normalizedHTML, range: NSRange(location: 0, length: ns.length)))
        let embed = ReaderWebEmbed(src: ns.substring(with: match.range(at: 1)), title: nil, referer: nil)
        let page = try #require(embed.inlinePage)
        #expect(page.baseURL?.absoluteString == "https://m.qidian.com/")
        #expect(page.html.contains("<video"))
        // 弹幕 fetched with the exact SourceId (it is above 2^53; a rounded one returns none).
        let danmu = try #require(page.html.range(of: "var D=").map { String(page.html[$0.upperBound...].prefix(400)) })
        print("⟐ egg.live danmu=\(danmu)")
        #expect(danmu.hasPrefix("[{"))

        // The page plays its video only because it loads as m.qidian.com: the CDN answers 403
        // to a request without that Referer.
        #expect(try await Self.videoDuration(html: page.html, baseURL: page.baseURL) > 0)
        #expect(try await Self.videoDuration(html: page.html, baseURL: nil) < 0)
    }

    private final class MetadataHandler: NSObject, WKScriptMessageHandler {
        var continuation: CheckedContinuation<Double, Never>?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            continuation?.resume(returning: (message.body as? Double) ?? -1)
            continuation = nil
        }
    }

    /// Loads `html` the way `ReaderWebEmbedManager` does and reports the video's duration once
    /// its metadata arrives, or -1 when the video fails to load.
    private static func videoDuration(html: String, baseURL: URL?) async throws -> Double {
        let handler = MetadataHandler()
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let probe = """
            var v=document.querySelector('video');
            v.addEventListener('loadedmetadata',function(){webkit.messageHandlers.m.postMessage(v.duration)});
            v.addEventListener('error',function(){webkit.messageHandlers.m.postMessage(-1)});
            v.preload='auto';v.load();
            """
        configuration.userContentController.addUserScript(
            WKUserScript(source: probe, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.add(handler, name: "m")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 568), configuration: configuration)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        window?.addSubview(webView)
        defer { webView.removeFromSuperview() }
        return await withCheckedContinuation { continuation in
            handler.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }
}
