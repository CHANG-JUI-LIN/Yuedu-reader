import Foundation
import Testing
@testable import yuedu_app

/// A source with a cookie jar (`enabledCookieJar`) keeps the cookies its stage pages set, as
/// Legado's network interceptor keeps them for a request it marks `CookieJar`
/// (`CookieManager.saveResponse`) — each redirect's included, since the interceptor sees every
/// hop. A source without one keeps none: Legado's OkHttp client has no cookie jar.
///
/// 起点(部分可看) (YCK 1330 #130) builds its 發現 URLs with
/// `cookie.getKey("https://qidian.com", "_csrfToken")`, a cookie m.qidian.com sets on the search
/// page the source check opens first. The native stage path kept no response cookie at all, so
/// every list was asked for with an empty token and answered with no books.
@Suite("Sources with a cookie jar keep their pages' cookies", .serialized)
struct SourceCookieJarTests {
    /// `/set/<id>` sets `jar_<id>`; `/hop/<id>` sets `hop_<id>` and redirects to `/land/<id>`,
    /// which sets `land_<id>`; `/form/<id>` (a POST) sets `form_<id>`.
    private static func server() throws -> LoopbackPageServer {
        try LoopbackPageServer { path in
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2 else { return .html("<p>none</p>") }
            let (kind, id) = (parts[0], parts[1])
            let page = Data("<p>\(kind)</p>".utf8)
            let type = "text/html; charset=utf-8"
            switch kind {
            case "set":
                return .answer(status: 200, headers: ["Content-Type": type, "Set-Cookie": "jar_\(id)=kept; Path=/"], body: page)
            case "hop":
                return .answer(status: 302, headers: ["Location": "/land/\(id)", "Set-Cookie": "hop_\(id)=hopped; Path=/"], body: Data())
            case "land":
                return .answer(status: 200, headers: ["Content-Type": type, "Set-Cookie": "land_\(id)=landed; Path=/"], body: page)
            case "form":
                return .answer(status: 200, headers: ["Content-Type": type, "Set-Cookie": "form_\(id)=posted; Path=/"], body: page)
            default:
                return .html("<p>none</p>")
            }
        }
    }

    private static func source(at base: URL, cookieJar: Bool) -> BookSource {
        var source = BookSource(bookSourceUrl: base.absoluteString, bookSourceName: "Cookie jar")
        source.enabledCookieJar = cookieJar
        return source
    }

    /// What a source's `cookie.getKey(url, key)` reads.
    private static func cookie(_ name: String, at base: URL) -> String {
        CookieStore.shared.getKey(url: base.absoluteString, key: name)
    }

    private static func forgetCookies(of id: String) {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where cookie.name.hasSuffix(id) {
            storage.deleteCookie(cookie)
        }
    }

    private static func fetch(
        _ path: String, method: String = "GET", body: String? = nil, base: URL, cookieJar: Bool
    ) async throws -> String {
        try await BookSourceFetcher().fetchStageHTML(
            url: try #require(URL(string: path, relativeTo: base)).absoluteURL,
            method: method, body: body, headers: [:], baseURL: base.absoluteString,
            source: source(at: base, cookieJar: cookieJar)
        )
    }

    @Test("a stage page's cookie is kept for a source with a cookie jar", .timeLimit(.minutes(1)))
    func jarKeepsStagePageCookie() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { Self.forgetCookies(of: id) }

        let html = try await Self.fetch("set/\(id)", base: base, cookieJar: true)

        #expect(html.contains("<p>set</p>"))
        #expect(Self.cookie("jar_\(id)", at: base) == "kept")
    }

    @Test("every hop's cookie is kept: the redirect's and the page it lands on", .timeLimit(.minutes(1)))
    func jarKeepsRedirectCookies() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { Self.forgetCookies(of: id) }

        let html = try await Self.fetch("hop/\(id)", base: base, cookieJar: true)

        #expect(html.contains("<p>land</p>"))
        #expect(Self.cookie("hop_\(id)", at: base) == "hopped")
        #expect(Self.cookie("land_\(id)", at: base) == "landed")
    }

    /// A cleartext POST goes out in one write (`SingleWriteHTTPExchange`), not through URLSession.
    @Test("a cleartext POST's cookie is kept for a source with a cookie jar", .timeLimit(.minutes(1)))
    func jarKeepsCleartextPostCookie() async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { Self.forgetCookies(of: id) }

        let html = try await Self.fetch("form/\(id)", method: "POST", body: "q=1", base: base, cookieJar: true)

        #expect(html.contains("<p>form</p>"))
        #expect(Self.cookie("form_\(id)", at: base) == "posted")
    }

    @Test("a source without a cookie jar keeps none", .timeLimit(.minutes(1)), arguments: ["GET", "POST"])
    func noJarKeepsNothing(method: String) async throws {
        let server = try Self.server()
        let base = try await server.start()
        defer { server.stop() }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { Self.forgetCookies(of: id) }
        let path = method == "GET" ? "hop/\(id)" : "form/\(id)"

        let html = try await Self.fetch(path, method: method, body: method == "POST" ? "q=1" : nil, base: base, cookieJar: false)

        #expect(!html.isEmpty)
        #expect(Self.cookie("hop_\(id)", at: base).isEmpty)
        #expect(Self.cookie("land_\(id)", at: base).isEmpty)
        #expect(Self.cookie("form_\(id)", at: base).isEmpty)
    }
}
