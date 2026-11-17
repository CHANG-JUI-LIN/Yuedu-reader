import Foundation
import Testing
@testable import yuedu_app

/// Sources tell the Legado forks apart by probing the runtime, and a source that decides it is
/// not on the fork it needs stops working: 哔哩哔哩（优+++, YCK 1331）opened a 「下载阅读Σ最新测试版」
/// page after every request. These pin the probes those sources use.
@Suite("Legado fork detection", .serialized)
struct LegadoForkDetectionTests {

    /// The probes as 蓝批小说 (YCK 1331) and 哔哩哔哩 write them: optional chaining compiles
    /// (not the original Legado's Rhino), `java.ajaxTestAll` exists (Sigma), and
    /// `java.readBookConfig` is defined (legado-E / MD3 / Sigma's `getReadBookConfig()` as
    /// Rhino's bean property).
    @Test("the fork probes report a legado-E / Sigma runtime")
    func forkProbes() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("""
            (function () {
              var official;
              try { eval('({})?.value'); official = false } catch (e) { official = true }
              return [official, typeof java.ajaxTestAll, typeof java.readBookConfig,
                      typeof java.getReadBookConfig, typeof cookie.setWebCookie].join(',');
            })()
            """)
        #expect(result == "false,function,string,function,function")
    }

    /// `java` in `loginCheckJs` is the request's AnalyzeUrl; the bridge's members still answer
    /// through it, so the check that opened the download page sees the property.
    @Test("loginCheckJs sees java.readBookConfig")
    func loginCheckSeesReadBookConfig() {
        var source = BookSource(
            bookSourceUrl: "fork-probe-fixture-\(UUID().uuidString)",
            bookSourceName: "fork probe fixture"
        )
        source.loginCheckJs = #"source.put("probe", typeof java.readBookConfig); result"#
        let bridge = ModernParserBridge(source: source)
        let body = "<html>ok</html>"

        let checked = bridge.applyLoginCheck(html: body, baseURL: "https://example.com/x")

        #expect(bridge.lastSourceScriptError == nil)
        #expect(checked == body)
        #expect(bridge.evaluateSourceScript(#"source.get("probe")"#) == "string")
    }

    /// 老福特源 colours its SVGs from `getReadBookConfigMap()["textColor"]` and
    /// `["textColorNight"]`, taking the last six characters as the hex.
    @Test("getReadBookConfig carries the reader's colours under Legado's names")
    func readBookConfigColours() throws {
        let engine = JSCoreEngine()
        let hex = #"^#[0-9A-F]{6}$"#
        for key in ["bgStr", "bgStrNight", "textColor", "textColorNight"] {
            let fromMap = try #require(engine.evaluate(#"String(java.getReadBookConfigMap()["\#(key)"])"#))
            let fromJSON = try #require(engine.evaluate(#"JSON.parse(java.readBookConfig)["\#(key)"]"#))
            #expect(fromMap.range(of: hex, options: .regularExpression) != nil, "\(key): \(fromMap)")
            #expect(fromJSON == fromMap)
        }
    }
}
