import Foundation
import Testing
@testable import yuedu_app

/// `java.ajaxAll` waits on its workers while it occupies the engine's JS queue, so nothing a worker
/// does may need that queue. Its requests carry the source headers; resolving them used to `sync`
/// onto the queue on a cache miss, and every worker then blocked until the batch's 30 s timeout and
/// came back empty — for a source's first batch, or the first after a login, whenever no other
/// request had resolved the headers yet.
@Suite("java.ajaxAll source headers")
struct AjaxAllSourceHeadersTests {
    /// Far below the batch's 30 s timeout; the stubbed requests answer at once.
    private static let budget: Duration = .seconds(10)

    /// `header: nil` leaves the engine without a source.
    private static func engine(header: String?) -> JSCoreEngine {
        let engine = JSCoreEngine()
        if let header {
            var source = BookSource(bookSourceUrl: "ajaxall-headers-\(UUID().uuidString)", bookSourceName: "ajaxAll headers")
            source.header = header
            engine.bookSource = source
        }
        // Called from ajaxAll's workers, several at once: derive the answer from the request only.
        engine.networkHandler = { request in
            let header = request.value(forHTTPHeaderField: "X-Batch") ?? "-"
            return .bodyOnly(request: request, body: header + ":" + (request.url?.lastPathComponent ?? "?"))
        }
        return engine
    }

    private static func timedAjaxAll(_ engine: JSCoreEngine, _ urls: [String]) -> (value: String?, elapsed: Duration) {
        let list = urls.map { "'\($0)'" }.joined(separator: ", ")
        let clock = ContinuousClock()
        let start = clock.now
        let value = engine.evaluate("java.ajaxAll([\(list)]).map(function (r) { return r.body(); }).join('|');")
        return (value, clock.now - start)
    }

    @Test("A source without a header rule gets every body, without waiting for the timeout")
    func noHeaderRule() {
        let engine = Self.engine(header: "")
        let (value, elapsed) = Self.timedAjaxAll(engine, [
            "https://ajaxall.invalid/a", "https://ajaxall.invalid/b", "https://ajaxall.invalid/c",
        ])
        #expect(value == "-:a|-:b|-:c")
        #expect(elapsed < Self.budget)
    }

    @Test("A header rule nothing has resolved yet is resolved once, and every worker request carries it")
    func headerRuleUnresolvedBeforeBatch() {
        let engine = Self.engine(header: #"{"X-Batch":"lazy"}"#)
        let (value, elapsed) = Self.timedAjaxAll(engine, [
            "https://ajaxall.invalid/a", "https://ajaxall.invalid/b", "https://ajaxall.invalid/c",
        ])
        #expect(value == "lazy:a|lazy:b|lazy:c")
        #expect(elapsed < Self.budget)
    }

    @Test(
        "Option URLs go to the AnalyzeUrl handler, whose header lookup must not wait on the queue",
        arguments: [Optional(""), nil]
    )
    func analyzeUrlRouteWithoutHeaderRule(header: String?) {
        let engine = Self.engine(header: header)
        // As `ModernParserBridge.analyzeUrlHandler` does through `applySourceAuthentication`:
        // it reads the source headers while it builds the request, which `ajaxAll` does on the
        // JS thread before the request's fetch goes to a worker.
        engine.analyzeUrlHandler = { [weak engine] url in
            guard let headers = engine?.resolvedSourceHeaders() else { return nil }
            let path = url.components(separatedBy: ",{").first ?? url
            let response = PreparedSourceRequest.Response(
                body: "\(headers.count):" + (URL(string: path)?.lastPathComponent ?? "?"),
                url: path
            )
            return PreparedSourceRequest(fetch: { response }, finish: { $0.body })
        }
        let (value, elapsed) = Self.timedAjaxAll(engine, [
            #"https://ajaxall.invalid/a,{"method":"GET"}"#, #"https://ajaxall.invalid/b,{"method":"GET"}"#,
        ])
        #expect(value == "0:a|0:b")
        #expect(elapsed < Self.budget)
    }
}
