import Foundation
import Testing
@testable import yuedu_app

/// jsLib is back in scope after a script timeout replaced the engine's context.
///
/// 番茄听书 (YCK 1330 #31): its audio decrypt ran past the 30 s timeout on the content stage,
/// the timeout reset the engine onto a fresh context (`JSCoreEngine.resetEngine`), and the 發現
/// list built next called `FQ_atoneKinds(java)` — a jsLib function the new context did not have.
/// Only the stages that build a request re-evaluated jsLib; the explore list and the image-decode
/// hooks run before any request does.
///
/// Each jsLib function here runs past the timeout on its second call — the call that resets the
/// engine — and answers on the others. A new context starts its count again with jsLib.
@Suite("jsLib after a timeout reset", .serialized)
struct JsLibAfterTimeoutResetTests {
    private static func bridge() -> ModernParserBridge {
        var source = BookSource(bookSourceUrl: "https://jslib-reset.example", bookSourceName: "jsLib reset")
        source.jsLib = """
        var calls = 0;
        function stallOnSecondCall() {
            calls++;
            if (calls === 2) { var t = Date.now(); while (Date.now() - t < 31000) {} }
        }
        function libKinds() { stallOnSecondCall(); return JSON.stringify([{ title: 'kind', url: '/kind' }]); }
        function libDecode(bytes) { stallOnSecondCall(); return bytes; }
        """
        source.exploreUrl = "@js:libKinds()"
        return ModernParserBridge(source: source)
    }

    @Test("the 發現 list still finds jsLib's functions", .timeLimit(.minutes(2)))
    func exploreAfterReset() throws {
        let bridge = Self.bridge()
        #expect(try bridge.exploreItems(page: 1, variableOverlay: [:]).map(\.title) == ["kind"])

        #expect(throws: ModernParserBridge.ExploreScriptError.self, "the second list should have timed out") {
            try bridge.exploreItems(page: 1, variableOverlay: [:])
        }

        #expect(try bridge.exploreItems(page: 1, variableOverlay: [:]).map(\.title) == ["kind"])
    }

    @Test("an image-decode rule still finds jsLib's functions", .timeLimit(.minutes(2)))
    func imageDecodeAfterReset() {
        let bridge = Self.bridge()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let src = "https://jslib-reset.example/a.png"
        #expect(bridge.decodeImageBytes(bytes, src: src, ruleJs: "@js:libDecode(result)") == bytes)

        #expect(bridge.decodeImageBytes(bytes, src: src, ruleJs: "@js:libDecode(result)") == nil,
                "the second decode should have timed out")

        #expect(bridge.decodeImageBytes(bytes, src: src, ruleJs: "@js:libDecode(result)") == bytes)
    }
}
