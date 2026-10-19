import Foundation
import os
import Testing
@testable import yuedu_app

/// A source's jsLib is evaluated while its bridge is still creating the JS runtime. Top-level
/// jsLib code that calls back into the bridge must reach that same runtime: the lock the
/// accessor used to hold deadlocked on it, and a `lazy` property would start a second one.
@Suite("JS runtime creation re-entered from jsLib", .serialized)
struct JSEngineCreationReentryTests {
    static func source(jsLib: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(ReentryProtocol.host)/\(UUID().uuidString.prefix(8).lowercased())",
            bookSourceName: "jsLib re-entry"
        )
        source.header = "@js:JSON.stringify({'X-Source-Token': 'abc'})"
        source.jsLib = jsLib
        return source
    }

    @Test("top-level jsLib reads the source's headers while the runtime is being created",
          .timeLimit(.minutes(1)))
    func jsLibReadsHeadersDuringCreation() async {
        let host = SourceScriptHost(bridgeFor: Self.source(
            jsLib: "var tokenAtLoad = String(source.getHeaderMap().get('X-Source-Token'));"
        ))

        #expect(await host.run { $0.evaluateSourceScript("tokenAtLoad") } == "abc")
    }

    /// A request with options goes through the bridge's `analyzeUrlHandler`, whose
    /// `applySourceAuthentication` reads the headers through `jsEngine`: the path the old lock
    /// deadlocked on. Keep the `,{…}` options: a plain `java.ajax(url)` made while jsLib loads
    /// runs before the bridge's `networkHandler` is wired, so it skips the bridge (and this
    /// test's URLProtocol) and goes to the live network.
    @Test("a top-level jsLib request goes out with the source's headers",
          .timeLimit(.minutes(1)))
    func jsLibRequestDuringCreation() async {
        ReentryProtocol.reset()
        let source = Self.source(
            jsLib: "var bodyAtLoad = String(java.ajax('https://\(ReentryProtocol.host)/load,{\"method\":\"GET\"}'));"
        )
        let host = SourceScriptHost(bridgeFor: source, requestSession: ReentryProtocol.session())

        #expect(await host.run { $0.evaluateSourceScript("bodyAtLoad") } == "loaded")
        #expect(ReentryProtocol.tokens == ["abc"])
    }
}

private final class ReentryProtocol: URLProtocol {
    static let host = "jslib-reentry.example"
    private static let recorded = OSAllocatedUnfairLock<[String?]>(initialState: [])

    static var tokens: [String?] { recorded.withLock { $0 } }
    static func reset() { recorded.withLock { $0 = [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReentryProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Source-Token")
        Self.recorded.withLock { $0.append(token) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("loaded".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
