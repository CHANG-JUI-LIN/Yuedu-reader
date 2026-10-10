import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for 封面搜索 on the open web.
///
/// `OnlineCoverSearchService` calls `URLSession.shared` directly, so a `URLProtocol`
/// registered with `registerClass` answers for both providers. The two providers run
/// concurrently and their order varies, so results are compared as sets.
@Suite("Online cover search (characterization)", .serialized)
struct OnlineCoverSearchServiceTests {
    @Test("results from both providers combine, and one URL is kept once")
    func combinesProvidersAndDeduplicates() async {
        let covers = await search(name: "三體", author: "劉慈欣", tuishujun: .items([
            ["title": "三體", "author_nickname": "劉慈欣", "cover": "https://img.phase0.test/a.jpg"],
            ["title": "三體", "author_nickname": "劉慈欣", "cover": "https://img.phase0.test/shared.jpg"],
        ]), ypshuo: .items([
            ["novel_name": "三體", "author_name": "劉慈欣", "novel_img": "https://img.phase0.test/b.jpg"],
            ["novel_name": "三體", "author_name": "劉慈欣", "novel_img": "https://img.phase0.test/shared.jpg"],
        ]))

        #expect(covers.count == 3)
        #expect(Set(covers.map(\.coverUrl)) == [
            "https://img.phase0.test/a.jpg",
            "https://img.phase0.test/b.jpg",
            "https://img.phase0.test/shared.jpg",
        ])
        #expect(covers.contains { $0.coverUrl == "https://img.phase0.test/a.jpg" && $0.providerName == localized("推書君") })
        #expect(covers.contains { $0.coverUrl == "https://img.phase0.test/b.jpg" && $0.providerName == localized("一片書喽") })
    }

    @Test("the local title must contain the remote title")
    func localTitleContainsRemoteTitle() async {
        let covers = await search(name: "三體", author: "劉慈欣", tuishujun: .items([
            ["title": "三體", "author_nickname": "劉慈欣", "cover": "https://img.phase0.test/exact.jpg"],
            ["title": "三體II", "author_nickname": "劉慈欣", "cover": "https://img.phase0.test/sequel.jpg"],
            // Current behavior: a shorter remote title the local one contains also passes.
            ["title": "三", "author_nickname": "劉慈欣", "cover": "https://img.phase0.test/short.jpg"],
        ]), ypshuo: .items([]))

        #expect(Set(covers.map(\.coverUrl)) == [
            "https://img.phase0.test/exact.jpg",
            "https://img.phase0.test/short.jpg",
        ])
    }

    @Test("authors that contain one another match; others do not")
    func authorContainment() async {
        let covers = await search(name: "三體", author: "劉慈欣", tuishujun: .items([
            ["title": "三體", "author_nickname": "劉慈欣 著", "cover": "https://img.phase0.test/suffix.jpg"],
            ["title": "三體", "author_nickname": "慈欣", "cover": "https://img.phase0.test/part.jpg"],
            ["title": "三體", "author_nickname": "王晉康", "cover": "https://img.phase0.test/other.jpg"],
            ["title": "三體", "author_nickname": "", "cover": "https://img.phase0.test/no-remote-author.jpg"],
        ]), ypshuo: .items([]))

        #expect(Set(covers.map(\.coverUrl)) == [
            "https://img.phase0.test/suffix.jpg",
            "https://img.phase0.test/part.jpg",
            "https://img.phase0.test/no-remote-author.jpg",
        ])
    }

    @Test("an unknown local author matches on the title alone")
    func unknownLocalAuthorMatchesAnyAuthor() async {
        for localAuthor in ["", localized("未知作者")] {
            let covers = await search(name: "三體", author: localAuthor, tuishujun: .items([
                ["title": "三體", "author_nickname": "王晉康", "cover": "https://img.phase0.test/any.jpg"],
            ]), ypshuo: .items([]))

            #expect(covers.map(\.coverUrl) == ["https://img.phase0.test/any.jpg"])
        }
    }

    @Test("one provider failing still returns the other's covers")
    func oneProviderFailing() async {
        let covers = await search(name: "三體", author: "劉慈欣", tuishujun: .status(500), ypshuo: .items([
            ["novel_name": "三體", "author_name": "劉慈欣", "novel_img": "https://img.phase0.test/b.jpg"],
        ]))

        #expect(covers.map(\.coverUrl) == ["https://img.phase0.test/b.jpg"])
    }

    @Test("an empty title makes no request")
    func emptyTitleMakesNoRequest() async {
        let covers = await search(name: "  ", author: "劉慈欣", tuishujun: .items([]), ypshuo: .items([]))

        #expect(covers.isEmpty)
        #expect(CoverProviderURLProtocol.requestCount == 0)
    }

    // MARK: - Helpers

    private func search(
        name: String,
        author: String,
        tuishujun: CoverProviderURLProtocol.Reply,
        ypshuo: CoverProviderURLProtocol.Reply
    ) async -> [OnlineCoverSearchService.Result] {
        CoverProviderURLProtocol.install(replies: [
            "pre-api.tuishujun.com": tuishujun,
            "m.ypshuo.com": ypshuo,
        ])
        URLProtocol.registerClass(CoverProviderURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(CoverProviderURLProtocol.self)
        }
        return await OnlineCoverSearchService.searchCovers(name: name, author: author)
    }
}

/// Answers the two cover providers' hosts from a per-test table.
private final class CoverProviderURLProtocol: URLProtocol {
    enum Reply {
        case items([[String: String]])
        case status(Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { lock.withLock { requests } }

    static func install(replies: [String: Reply]) {
        lock.withLock {
            self.replies = replies
            requests = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { replies[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.requests += 1
            return Self.replies[host]
        }
        let status: Int
        let body: Data
        switch reply {
        case .items(let items):
            status = 200
            body = (try? JSONSerialization.data(withJSONObject: ["data": ["data": items]])) ?? Data()
        case .status(let code):
            status = code
            body = Data()
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
