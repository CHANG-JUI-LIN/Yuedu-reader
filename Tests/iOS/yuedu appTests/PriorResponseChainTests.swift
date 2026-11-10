import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

/// A response's `raw().priorResponse()` is okhttp's: the redirect that led to it, with no body,
/// and through its own `priorResponse()` the one before it — `null` once no redirect led there.
///
/// 八叉书库 (YCK 1330 #23) checks for a moved mirror in its `loginCheckJs` with
/// `result.raw().priorResponse()` and `isRedirect()`; without the method every stage threw a
/// TypeError. The redirects are recorded by the transport that followed them, on every route a
/// response comes back by: URLSession (`BoundedResponseLoader`, a stage page and a `java.*`
/// request) and a cleartext POST sent in one write (`SingleWriteHTTPExchange`).
///
/// No oracle case: the oracle runs Rhino and jsoup, not okhttp. The expected chains are okhttp
/// 4's own: `RetryAndFollowUpInterceptor` hands each followed response on as the next one's
/// `priorResponse`, rebuilt with `.body(null)`, and `Response.isRedirect` is 300, 301, 302, 303,
/// 307 or 308. A body we answer as "" where okhttp's is `null`; no source reads one.
@Suite("Responses keep the redirects that led to them", .serialized)
struct PriorResponseChainTests {
    /// `/hop1/<id>` 302s to `/hop2/<id>`, which 301s to `/land/<id>`; `/post/<id>` 302s to
    /// `/land/<id>`; `/land/<id>` and `/plain/<id>` answer a page.
    private static func server() throws -> LoopbackPageServer {
        try LoopbackPageServer { path in
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2 else { return .html("<p>none</p>") }
            let (kind, id) = (parts[0], parts[1])
            switch kind {
            case "hop1": return .answer(status: 302, headers: ["Location": "/hop2/\(id)"], body: Data())
            case "hop2": return .answer(status: 301, headers: ["Location": "/land/\(id)"], body: Data())
            case "post": return .answer(status: 302, headers: ["Location": "/land/\(id)"], body: Data())
            default: return .html("<p>\(kind)</p>")
            }
        }
    }

    /// What a script reads walking the chain from `response`: each prior's code, URL path,
    /// `isRedirect()` and body length, then whether the chain ends in `null`.
    private static let walk = """
    (function (r) {
        var out = [String(r.code())], p = r.raw().priorResponse(), n = 0;
        while (p != null && n < 5) {
            out.push([p.code(), p.url().replace(/^https?:\\/\\/[^\\/]+/, ''), p.isRedirect(), p.body().length].join(' '));
            p = p.priorResponse(); n++;
        }
        out.push(p === null ? 'null' : 'not null');
        return out.join(' | ');
    })(response)
    """

    private static func chain(of result: LegadoHTTPResult) -> String? {
        let context = JSContext()!
        context.setObject(LegadoStrResponse(result: result), forKeyedSubscript: "response" as NSString)
        return context.evaluateScript(walk)?.toString()
    }

    private static func stagePage(_ path: String, method: String = "GET", body: String? = nil, base: URL) async throws -> LegadoHTTPResult {
        let page = try await WebFetcher.shared.fetchPage(
            url: try #require(URL(string: path, relativeTo: base)).absoluteURL,
            method: method, body: body, headers: [:], baseURL: base.absoluteString, client: .okHttp
        )
        return LegadoHTTPResult.make(request: page.request, data: page.data, response: page.response)
    }

    @Test("a stage page's two redirects come back newest first, ending in null", .timeLimit(.minutes(1)))
    func stagePageRedirectChain() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }

        let result = try await Self.stagePage("hop1/a", base: base)

        #expect(Self.chain(of: result) == "200 | 301 /hop2/a true 0 | 302 /hop1/a true 0 | null")
    }

    /// A cleartext POST goes out in one write; the GET its 302 leads to goes through URLSession.
    @Test("a cleartext POST's redirect is the prior of the page it lands on", .timeLimit(.minutes(1)))
    func cleartextPostRedirectChain() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }

        let result = try await Self.stagePage("post/b", method: "POST", body: "q=1", base: base)

        #expect(Self.chain(of: result) == "200 | 302 /post/b true 0 | null")
    }

    @Test("a page no redirect led to has no prior response", .timeLimit(.minutes(1)))
    func noRedirectIsNull() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }

        let result = try await Self.stagePage("plain/c", base: base)

        #expect(Self.chain(of: result) == "200 | null")
    }

    @Test("a java.connect response walks the same chain", .timeLimit(.minutes(1)))
    func javaConnectRedirectChain() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let url = try #require(URL(string: "hop1/d", relativeTo: base)).absoluteString

        let walked = await Task.detached {
            JSCoreEngine().evaluate("var response = java.connect('\(url)');\n" + Self.walk)
        }.value

        #expect(walked == "200 | 301 /hop2/d true 0 | 302 /hop1/d true 0 | null")
    }
}
