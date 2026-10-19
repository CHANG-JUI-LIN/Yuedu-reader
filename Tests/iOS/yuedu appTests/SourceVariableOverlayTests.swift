import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-5: an Explore home section's own discover filter values, read by the
/// source's explore rule in place of the stored ones and never stored (Phase 5 plan,
/// decision 23; `LegadoSourceBridge.withVariableOverlay`).
@Suite("Source variable overlay", .serialized)
struct SourceVariableOverlayTests {
    private let store = BookSourceRuntimeStateStore.shared

    private func source(_ explore: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "overlay"
        source.bookSourceUrl = "https://overlay-\(UUID().uuidString).test"
        source.exploreUrl = explore
        source.enabledExplore = true
        return source
    }

    private func object(_ json: String?) -> [String: String] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    @Test("the rule reads the overlay through getVariable and get; the stored variable is left as it was")
    func readsTheOverlay() async {
        let source = source("""
        <js>var v = JSON.parse(source.getVariable() || '{}');
        JSON.stringify([{title: v['頻道'] + '/' + source.get('頻道'), url: 'https://x.test/' + v['頻道']}]);</js>
        """)
        let stored = #"{"頻道":"男","云端配置":"a"}"#
        store.setSourceVariableJSON(stored, for: source.bookSourceUrl)
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }
        let host = SourceScriptHost(bridgeFor: source)

        let overlaid = await host.getExploreItems(page: 1, variableOverlay: ["頻道": "女"])
        #expect(overlaid.map(\.title) == ["女/女"])
        #expect(overlaid.map(\.url) == ["https://x.test/女"])
        #expect(store.sourceVariableJSON(for: source.bookSourceUrl) == stored, "byte for byte")

        let plain = await host.getExploreItems(page: 1)
        #expect(plain.map(\.title) == ["男/男"], "the next evaluation reads the stored values")
    }

    @Test("a script that writes the variable back keeps its own keys; the overlay's are not stored")
    func writesKeepTheStoredValues() async {
        let source = source("""
        <js>var v = JSON.parse(source.getVariable() || '{}');
        v['云端配置'] = 'b';
        source.setVariable(JSON.stringify(v));
        source.put('線路', 'two');
        JSON.stringify([{title: v['頻道'] + v['排序'], url: 'https://x.test/'}]);</js>
        """)
        store.setSourceVariableJSON(#"{"頻道":"男","云端配置":"a"}"#, for: source.bookSourceUrl)
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let items = await SourceScriptHost(bridgeFor: source).getExploreItems(page: 1, variableOverlay: ["頻道": "女", "排序": "新書"])
        #expect(items.map(\.title) == ["女新書"])
        let after = object(store.sourceVariableJSON(for: source.bookSourceUrl))
        #expect(after == ["頻道": "男", "云端配置": "b", "線路": "two"], "排序 stays absent, 頻道 stays 男")
    }

    @Test("a variable that is not a JSON object is read as stored")
    func skipsANonObjectVariable() async {
        let source = source("<js>JSON.stringify([{title: source.getVariable(), url: 'https://x.test/'}]);</js>")
        store.setSourceVariableJSON("token-1", for: source.bookSourceUrl)
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let items = await SourceScriptHost(bridgeFor: source).getExploreItems(page: 1, variableOverlay: ["頻道": "女"])
        #expect(items.map(\.title) == ["token-1"])
        #expect(store.sourceVariableJSON(for: source.bookSourceUrl) == "token-1")
    }
}
