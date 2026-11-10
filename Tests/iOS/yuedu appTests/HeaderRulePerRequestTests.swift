import Foundation
import os
import Testing
@testable import yuedu_app

/// Legado evaluates a source's `header` rule again for every request — `AnalyzeUrl.init`
/// (legado-E `AnalyzeUrl.kt:133`) and `java.get`/`java.post`/`java.head`
/// (`JsExtensions.kt:224/257/292`) each call `BaseSource.getHeaderMap` — and the request sends
/// the map that evaluation returned. Rules depend on it: 漫画台 and the other qyyuapi sources
/// (YCK 1329) `cache.put` their headers under a key built from a variable their login script
/// sets, and the search rule reads that key back after a later request evaluated the rule with
/// the variable in place. The engine kept its first evaluation instead, made before the variable
/// existed, and the search rule read nothing (`TypeError: null is not an object`).
@Suite("Header rule evaluated per request", .serialized)
struct HeaderRulePerRequestTests {
    /// A `<js>` rule that counts its evaluations in the source's cache, sends the count, and puts
    /// a key built from `stage` as 漫画台's rule builds one from `Get('url')`.
    private static func countingSource() -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://header-per-request-\(UUID().uuidString.prefix(8).lowercased()).invalid",
            bookSourceName: "header per request"
        )
        source.header = """
        <js>
        var n = Number(cache.get('n') || 0) + 1;
        cache.put('n', String(n));
        cache.put('hdr:' + String(cache.get('stage') || ''), 'put');
        JSON.stringify({"X-N": String(n)});
        </js>
        """
        return source
    }

    @Test("state a script sets after one request reaches the rule on the next")
    func ruleSeesStateSetBetweenRequests() {
        let engine = JSCoreEngine()
        engine.bookSource = Self.countingSource()
        let sent = SentHeaderValues()
        engine.networkHandler = { request, _ in
            sent.append(request.value(forHTTPHeaderField: "X-N"))
            return .bodyOnly(request: request, body: "ok")
        }
        let value = engine.evaluate("""
            java.ajax('https://site.invalid/a');
            cache.put('stage', 'logged-in');
            java.ajax('https://site.invalid/b');
            String(cache.get('hdr:logged-in'))
            """)
        #expect(value == "put")
        #expect(sent.values == ["1", "2"])
    }

    /// 点众阅读 (YCK 1330#255) starts its rule with `let randomUuid`: run in the global context,
    /// the second evaluation threw `SyntaxError: Can't create duplicate variable` and its book
    /// page went out without the signed `datas` header. Legado's `BaseSource.evalJS` gives each
    /// run a fresh scope. 漫画台 assigns `headers=` without declaring it.
    @Test("a rule with top-level declarations resolves on every request")
    func topLevelDeclarationsRunAgain() {
        var source = Self.countingSource()
        source.header = """
        <js>
        let id = String(java.randomUUID());
        const fixed = 'k';
        headers = {"X-Id": id, "X-Fixed": fixed};
        JSON.stringify(headers);
        </js>
        """
        let engine = JSCoreEngine()
        engine.bookSource = source
        let first = engine.resolvedSourceHeaders()
        let second = engine.resolvedSourceHeaders()
        #expect(first["X-Fixed"] == "k")
        #expect(second["X-Fixed"] == "k")
        #expect(first["X-Id"] != nil && second["X-Id"] != nil && first["X-Id"] != second["X-Id"])
    }

    @Test("an AnalyzeUrl request evaluates the rule once and sends what that evaluation returned")
    func analyzeUrlRequestEvaluatesOnce() throws {
        let bridge = ModernParserBridge(source: Self.countingSource())
        let sent = SentHeaderValues()
        bridge.sourceScriptNetworkHandler = { request, _ in
            sent.append(request.value(forHTTPHeaderField: "X-N"))
            return .bodyOnly(request: request, body: "ok")
        }
        let value = try #require(bridge.evaluateSourceScript("""
            var a = Number(cache.get('n') || 0);
            java.ajax('https://site.invalid/a,{"method":"GET"}');
            var b = Number(cache.get('n'));
            java.ajax('https://site.invalid/b,{"method":"GET"}');
            var c = Number(cache.get('n'));
            [b - a, c - b, b, c].join(',')
            """))
        let parts = value.split(separator: ",").map(String.init)
        try #require(parts.count == 4, "script answered \(value)")
        #expect(parts[0] == "1" && parts[1] == "1", "evaluations per request: \(parts[0]), \(parts[1])")
        #expect(sent.values == [parts[2], parts[3]])
    }

    @Test("a native request resolves the rule again instead of reusing the last result")
    func nativeRequestResolvesAgain() async throws {
        let source = Self.countingSource()
        let first = try #require(Int(await source.resolvedHeaders()["X-N"] ?? ""))
        let second = try #require(Int(await source.resolvedHeaders()["X-N"] ?? ""))
        #expect(second == first + 1)
    }

    /// Prints the per-request cost, for the record: a `<js>` rule with three `cache` calls, and a
    /// plain JSON rule. The bound only catches a pathological regression.
    @Test("evaluating the rule per request stays cheap")
    func perRequestCost() {
        var plain = Self.countingSource()
        plain.header = #"{"User-Agent": "okhttp/4.9.2", "Referer": "https://site.invalid/"}"#
        let rounds = 200
        for (label, source) in [("<js>", Self.countingSource()), ("JSON", plain)] {
            let engine = JSCoreEngine()
            engine.bookSource = source
            _ = engine.resolvedSourceHeaders()
            let elapsed = ContinuousClock().measure {
                for _ in 0..<rounds { _ = engine.resolvedSourceHeaders() }
            }
            print("⏱ header rule per request (\(label)): \(elapsed / rounds)")
            #expect(elapsed / rounds < .milliseconds(20))
        }
    }
}

private final class SentHeaderValues: Sendable {
    private let values_ = OSAllocatedUnfairLock<[String?]>(initialState: [])
    func append(_ value: String?) { values_.withLock { $0.append(value) } }
    var values: [String?] { values_.withLock { $0 } }
}
