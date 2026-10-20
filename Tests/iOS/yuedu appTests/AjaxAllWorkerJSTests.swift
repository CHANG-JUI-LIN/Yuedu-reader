import Foundation
import Testing
@testable import yuedu_app

/// `java.ajaxAll` waits on its workers while it occupies the engine's JS queue, so nothing a worker
/// does may need that queue. An option URL (`url,{…}`) goes to `ModernParserBridge`'s AnalyzeUrl
/// handler on the worker thread, and that handler evaluates source JS — the URL's `{{…}}`
/// templates and its `bodyJs` — through `JSCoreEngine.evaluateIsolated`, which dispatches onto
/// the occupied queue.
@Suite("java.ajaxAll worker JS")
struct AjaxAllWorkerJSTests {
    /// Far below the batch's 30 s timeout; the stubbed requests answer at once.
    private static let budget: Duration = .seconds(10)

    private static func bridge() -> ModernParserBridge {
        let source = BookSource(
            bookSourceUrl: "https://ajaxall-worker-js-\(UUID().uuidString).invalid",
            bookSourceName: "ajaxAll worker JS"
        )
        let bridge = ModernParserBridge(source: source)
        // Called from ajaxAll's workers, several at once: derive the answer from the request only.
        bridge.sourceScriptNetworkHandler = { request, _ in
            let url = request.url
            let query = url?.query.map { "?" + $0 } ?? ""
            return .bodyOnly(request: request, body: (url?.lastPathComponent ?? "?") + query)
        }
        return bridge
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    private static func timedAjaxAll(_ bridge: ModernParserBridge, _ urls: [String]) -> (value: String?, elapsed: Duration) {
        let list = urls.map(jsString).joined(separator: ", ")
        let clock = ContinuousClock()
        let start = clock.now
        let value = bridge.evaluateSourceScript(
            "java.ajaxAll([\(list)]).map(function (r) { return r.body(); }).join('|')"
        )
        return (value, clock.now - start)
    }

    @Test("A {{…}} template in an option URL is evaluated without waiting for the batch timeout")
    func templateInOptionURL() {
        let bridge = Self.bridge()
        let urls = [
            #"https://ajaxall.invalid/a?n={{1+1}},{"method":"GET"}"#,
            #"https://ajaxall.invalid/b?n={{2+2}},{"method":"GET"}"#,
        ]
        // Control: the same URL through one `java.ajax`, on the JS thread.
        #expect(bridge.evaluateSourceScript("java.ajax(\(Self.jsString(urls[0])))") == "a?n=2")

        // The JS timeout resets the engine; state the script set before the batch must survive it.
        _ = bridge.evaluateSourceScript("var __ajaxAllProbe = 'kept'; 0")
        let (value, elapsed) = Self.timedAjaxAll(bridge, urls)
        #expect(bridge.evaluateSourceScript("typeof __ajaxAllProbe") == "string")
        #expect(value == "a?n=2|b?n=4")
        #expect(elapsed < Self.budget)
    }

    @Test("An option URL's js option is evaluated without waiting for the batch timeout")
    func jsOptionInOptionURL() {
        let bridge = Self.bridge()
        let urls = [
            #"https://ajaxall.invalid/a,{"method":"GET","js":"java.put('ajaxAllJsOption', 'ran')"}"#,
            #"https://ajaxall.invalid/b,{"method":"GET","js":"java.put('ajaxAllJsOption', 'ran')"}"#,
        ]
        #expect(bridge.evaluateSourceScript("java.ajax(\(Self.jsString(urls[0])))") == "a")

        let (value, elapsed) = Self.timedAjaxAll(bridge, urls)
        #expect(value == "a|b")
        #expect(elapsed < Self.budget)
    }

    @Test("An option URL's bodyJs runs without waiting for the batch timeout")
    func bodyJsInOptionURL() {
        let bridge = Self.bridge()
        let urls = [
            #"https://ajaxall.invalid/a,{"method":"GET","bodyJs":"result + '!'"}"#,
            #"https://ajaxall.invalid/b,{"method":"GET","bodyJs":"result + '!'"}"#,
        ]
        #expect(bridge.evaluateSourceScript("java.ajax(\(Self.jsString(urls[0])))") == "a!")

        // The JS timeout resets the engine; state the script set before the batch must survive it.
        _ = bridge.evaluateSourceScript("var __ajaxAllProbe = 'kept'; 0")
        let (value, elapsed) = Self.timedAjaxAll(bridge, urls)
        #expect(bridge.evaluateSourceScript("typeof __ajaxAllProbe") == "string")
        #expect(value == "a!|b!")
        #expect(elapsed < Self.budget)
    }

    /// 段評 sources batch 50–150 option URLs with no JS in them. Building each AnalyzeUrl request
    /// (parse, authentication, cookies) is CPU work; this times a batch whose transport answers at
    /// once, so what is left is that work and how it is scheduled.
    @Test("A large batch of option URLs without JS")
    func largeOptionURLBatch() {
        let bridge = Self.bridge()
        let urls = (0..<150).map { #"https://ajaxall.invalid/p\#($0),{"headers":{"X-Review":"1"}}"# }
        _ = Self.timedAjaxAll(bridge, Array(urls.prefix(16))) // warm-up: jsLib, header cache
        var samples: [Duration] = []
        var value: String?
        for _ in 0..<5 {
            let run = Self.timedAjaxAll(bridge, urls)
            value = run.value
            samples.append(run.elapsed)
        }
        let ms = samples.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
        print("⏱ ajaxAll 150 option URLs ms=\(ms) median=\(ms.sorted()[ms.count / 2])")
        #expect(value == (0..<150).map { "p\($0)" }.joined(separator: "|"))
        #expect(samples.allSatisfy { $0 < Self.budget })
    }
}
