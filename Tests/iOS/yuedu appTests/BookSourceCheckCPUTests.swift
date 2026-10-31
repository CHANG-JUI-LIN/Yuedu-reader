import Foundation
import os
import Testing
@testable import yuedu_app

/// The two stages that put 書源檢查 over MetricKit's CPU budget (90 s in 180 s; Crashlytics
/// 20727455, c0ec35f1, 77f93443, bdd4dca3), each on its own path. Measured on a 1492-source
/// check: one table of contents with a `~` rule took 129 s of CPU, and audio sources with no
/// content rule had their streams downloaded and parsed as pages — 61 s for one 37.8 MB file,
/// and a stack overflow on another.
@Suite("Book-source check CPU", .serialized)
struct BookSourceCheckCPUTests {

    // MARK: - Audio sources with no content rule

    @Test("an audio source with no content rule reads its chapter URL, unfetched")
    func audioSourceWithoutContentRuleReadsChapterURL() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: MediaURLProtocol.session()))
        let source = Self.sourceWithoutContentRule(type: 1)
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }

        let urls = [
            "https://\(MediaURLProtocol.host)/audio/1.mp3",
            "https://\(MediaURLProtocol.host)/audio/2.m4a,{\"headers\":{\"Referer\":\"https://\(MediaURLProtocol.host)/\"}}",
        ]
        for (index, url) in urls.enumerated() {
            let requestsBefore = MediaURLProtocol.requests
            let ref = OnlineChapterRef(index: index, title: "第\(index + 1)集", url: url)
            let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
            #expect(package.content == url)
            #expect(MediaURLProtocol.requests == requestsBefore, "the chapter URL was fetched: \(url)")
            #expect(DirectChapterAudioResolver.request(from: package.content) != nil)
        }
    }

    @Test("a text source with no content rule still reads its page through the heuristic")
    func textSourceWithoutContentRuleReadsPage() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: MediaURLProtocol.session()))
        let source = Self.sourceWithoutContentRule(type: 0)
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }

        let requestsBefore = MediaURLProtocol.requests
        let ref = OnlineChapterRef(index: 0, title: "第一章", url: "https://\(MediaURLProtocol.host)/text/1.html")
        let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
        #expect(MediaURLProtocol.requests == requestsBefore + 1)
        #expect(package.content.contains("第一段正文"))
        #expect(!package.content.contains("https://"))
    }

    // MARK: - General-sibling TOC rules

    /// ❤️图书迷子's rule on its page's shape: twelve 最新章节 entries under the first `dt`, the
    /// chapters under the second. SwiftSoup 2.13.7 walked back through every earlier sibling
    /// for each `dd`, rebuilding the sibling list at each step, so the rule grew cubically.
    /// Timed against a rule that selects the same entries without a combinator, on the same
    /// page, so the bound holds on any machine.
    @Test("a general-sibling TOC rule costs about what a plain one does")
    func generalSiblingTOCRule() throws {
        let sibling = Self.tocSource(chapterList: "#list > dl > dt:nth-of-type(2) ~ dd")
        let plain = Self.tocSource(chapterList: "#list > dl > dd")
        let siblingBridge = ModernParserBridge(source: sibling)
        let plainBridge = ModernParserBridge(source: plain)
        let baseURL = "https://\(Self.tocHost)/book/1/"

        var cells: [String] = []
        var ratio = 0.0
        for count in [150, 300, 600] {
            let html = Self.tocPage(chapters: count)
            var chapters: [OnlineChapterRef] = []
            var plainChapters: [OnlineChapterRef] = []
            let siblingMs = try Self.median {
                chapters = try siblingBridge.parseTOC(html: html, baseURL: baseURL, source: sibling)
            }
            let plainMs = try Self.median {
                plainChapters = try plainBridge.parseTOC(html: html, baseURL: baseURL, source: plain)
            }
            #expect(chapters.count == count)
            #expect(chapters.first?.url.hasSuffix("/book/1/1.html") == true)
            #expect(chapters.last?.url.hasSuffix("/book/1/\(count).html") == true)
            #expect(!chapters.contains { $0.url.contains("/latest/") })
            #expect(chapters.map(\.url) == plainChapters.dropFirst(12).map(\.url))
            ratio = siblingMs / plainMs
            cells.append("\(count)=\(String(format: "%.1f", siblingMs))ms/\(String(format: "%.1f", plainMs))ms")
        }
        print("TOC-SIBLING ~rule/plain \(cells.joined(separator: " ")) ratio@600=\(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "\(cells)")
    }

    // MARK: - Fixtures

    static let tocHost = "toc-sibling.test"

    static func tocSource(chapterList: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(tocHost)#\(UUID().uuidString)",
            bookSourceName: "TOC \(chapterList)"
        )
        source.ruleToc.chapterList = chapterList
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }

    static func sourceWithoutContentRule(type: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(MediaURLProtocol.host)/source-\(type)#\(UUID().uuidString)",
            bookSourceName: "No content rule \(type)"
        )
        source.bookSourceType = type
        return source
    }

    static func tocPage(chapters: Int) -> String {
        var html = "<html><body><div id=\"list\"><dl><dt>最新章节</dt>"
        for index in 1...12 {
            html += "<dd><a href=\"/latest/\(index).html\">最新第\(index)章</a></dd>"
        }
        html += "<dt>正文卷</dt>"
        for index in 1...chapters {
            html += "<dd><a href=\"/book/1/\(index).html\">第\(index)章 标题\(index)</a></dd>"
        }
        return html + "</dl></div></body></html>"
    }

    static func median(runs: Int = 3, _ work: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try work()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }
}

/// Serves `/audio/…` as an audio stream (binary, `audio/mpeg`) and `/text/…` as a chapter page,
/// and counts every request so a test can tell whether a chapter URL was fetched at all.
private final class MediaURLProtocol: URLProtocol {
    static let host = "media-source.test"
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    static var requests: Int { counter.withLock { $0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.counter.withLock { $0 += 1 }
        let body: Data
        let contentType: String
        if url.path.hasPrefix("/audio/") {
            var generator = SystemRandomNumberGenerator()
            body = Data("ID3".utf8) + Data((0..<262_144).map { _ in UInt8.random(in: 0...255, using: &generator) })
            contentType = "audio/mpeg"
        } else {
            let paragraphs = (1...30).map { "<p>第\($0 == 1 ? "一" : "\($0)")段正文，内容足够长，让正文识别认出这是章节。</p>" }
            body = Data(("<html><body><div id=\"content\">" + paragraphs.joined() + "</div></body></html>").utf8)
            contentType = "text/html; charset=utf-8"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
