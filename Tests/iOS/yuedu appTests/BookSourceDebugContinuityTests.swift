import Foundation
import Testing
@testable import yuedu_app

/// 調試源 runs search → 詳情 → 目錄 → 正文 on one bridge, so whatever a stage's scripts leave
/// in the source's JS runtime is still there for the next stage — as on Legado, where the
/// debug activity drives one source session through the chain. Each stage's rule marks the
/// JS global scope; the content rule reads every mark back. A stage that ran on a different
/// bridge (a fresh JSContext) would drop the marks before it.
@Suite("Book source debug continuity", .serialized)
@MainActor
struct BookSourceDebugContinuityTests {
    @Test("stages run one at a time share one source runtime")
    func separateStagesShareTheRuntime() async throws {
        let engine = BookSourceDebugEngine(source: Self.source(), requestSession: DebugContinuityURLProtocol.session())

        await engine.runSearch(keyword: "三體")
        #expect(engine.logs.contains { $0.step == "搜索結果" && $0.level == .success })
        await engine.runBookInfo(url: "\(Self.origin)/book/1")
        #expect(engine.logs.contains { $0.step == "書籍詳情" && $0.level == .success })
        await engine.runTOC(url: "\(Self.origin)/toc/1")
        #expect(engine.logs.contains { $0.step == "目錄結果" && $0.level == .success })
        await engine.runContent(url: "\(Self.origin)/c/1")

        #expect(Self.content(in: engine) == "SITC")
    }

    @Test("一鍵全流程 carries the runtime from search to content")
    func fullPipelineSharesTheRuntime() async throws {
        let engine = BookSourceDebugEngine(source: Self.source(), requestSession: DebugContinuityURLProtocol.session())

        await engine.runFullPipeline(keyword: "三體")

        #expect(engine.logs.contains { $0.step == "全流程" && $0.level == .success })
        #expect(Self.content(in: engine) == "SITC")
    }

    @Test("the marks belong to that engine's runtime, not to every engine")
    func freshEngineStartsClean() async throws {
        let marked = BookSourceDebugEngine(source: Self.source(), requestSession: DebugContinuityURLProtocol.session())
        await marked.runSearch(keyword: "三體")

        let fresh = BookSourceDebugEngine(source: Self.source(), requestSession: DebugContinuityURLProtocol.session())
        await fresh.runContent(url: "\(Self.origin)/c/1")

        #expect(Self.content(in: fresh) == "C")
    }

    // MARK: - Helpers

    static let origin = "https://\(DebugContinuityURLProtocol.host)"

    /// A native source whose every stage marks the JS global scope; the content rule answers
    /// with the marks present, in stage order, plus its own.
    static func source() -> BookSource {
        func mark(_ stage: String) -> String {
            "@js:var m = globalThis.debugMarks || (globalThis.debugMarks = {}); m.\(stage) = true; result"
        }
        var source = BookSource(
            bookSourceUrl: "\(origin)#\(UUID().uuidString)",
            bookSourceName: "Debug continuity"
        )
        source.searchUrl = "\(origin)/search?q={{key}}"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text" + mark("S")
        source.ruleSearch.bookUrl = "a@href"
        source.ruleBookInfo.name = "h1@text" + mark("I")
        source.ruleBookInfo.tocUrl = "a.toc@href"
        source.ruleToc.chapterList = "li.ch"
        source.ruleToc.chapterName = "a@text" + mark("T")
        source.ruleToc.chapterUrl = "a@href"
        source.ruleContent.content = """
        @js:var m = globalThis.debugMarks || {}; ['S', 'I', 'T'].filter(function (k) { return m[k]; }).join('') + 'C'
        """
        return source
    }

    static func content(in engine: BookSourceDebugEngine) -> String? {
        engine.logs.last { $0.step == "正文結果" }?.detail
    }
}

/// Serves the four pages of `BookSourceDebugContinuityTests`' source from the session's
/// configuration (`URLProtocol.registerClass` does not reach a custom session).
private final class DebugContinuityURLProtocol: URLProtocol {
    static let host = "debug-continuity.test"

    private static let pages: [String: String] = [
        "/search": #"<ul><li class="book"><a href="/book/1">三體</a></li></ul>"#,
        "/book/1": #"<h1>三體</h1><a class="toc" href="/toc/1">目錄</a>"#,
        "/toc/1": #"<ul><li class="ch"><a href="/c/1">第一章</a></li></ul>"#,
        "/c/1": #"<div id="c">正文</div>"#,
    ]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugContinuityURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let page = Self.pages[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(page.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
