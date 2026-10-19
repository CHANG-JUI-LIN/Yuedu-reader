import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

/// The JS hops that carry JavaScriptCore values in a `JSConfined`: each still delivers its result
/// to the caller exactly as before.
@Suite("JSConfined hand-offs")
struct JSConfinedHandoffTests {
    @Test("java.ajaxAll answers every URL in order through the configured handler, with the source headers")
    func ajaxAllKeepsOrderAndUsesHandler() {
        let engine = JSCoreEngine()
        var source = BookSource(bookSourceUrl: "ajaxall-handoff-\(UUID().uuidString)", bookSourceName: "ajaxAll")
        source.header = #"{"X-Batch":"handoff"}"#
        engine.bookSource = source
        // Resolved (and cached) before the batch, as a source's first request does. An unresolved
        // header rule makes every worker wait on the JS queue the batch occupies — a separate,
        // pre-existing issue (REPORT-6e1, "Found").
        #expect(engine.resolvedSourceHeaders()["X-Batch"] == "handoff")
        // Called from ajaxAll's workers, several at once: derive the answer from the request only.
        engine.networkHandler = { request in
            let header = request.value(forHTTPHeaderField: "X-Batch") ?? "-"
            return .bodyOnly(request: request, body: header + ":" + (request.url?.lastPathComponent ?? "?"))
        }
        let value = engine.evaluate("""
        java.ajaxAll(['https://ajaxall.invalid/a', 'https://ajaxall.invalid/b', 'https://ajaxall.invalid/c'])
            .map(function (r) { return r.body(); }).join('|');
        """)
        #expect(value == "handoff:a|handoff:b|handoff:c")
    }

    @Test("JSSandbox evaluates on its own thread and hands the value back")
    func sandboxReturnsValue() throws {
        let context = try #require(JSContext())
        JSSandbox.configure(context)
        let result = JSSandbox.evaluateWithTimeout(context, script: "[1, 2, 3].map(function (n) { return n * 2; }).join(',')")
        #expect(result?.toString() == "2,4,6")
    }
}
