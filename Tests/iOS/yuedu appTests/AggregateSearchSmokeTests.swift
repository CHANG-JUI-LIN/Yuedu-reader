import Foundation
import Testing
@testable import yuedu_app

// Regression coverage for "聚合源只能搜默认子站，搜不到源内自带几十个网站".
//
// Mechanism: aggregate sources (光遇/大灰狼) build their *search* request from a
// per-source runtime variable. 光遇's searchUrl JS resolves the sub-site filter as
//   sourcesKey = 更多设置[搜索模式] || '全部'
// The discover page must NOT persist a single platform into 更多设置[类型], or
// search gets pinned to that one site. `DiscoverViewModel.sanitizeDiscoverVariable`
// strips such legacy keys; this suite proves both the pure migration and the
// end-to-end effect on the resolved `sourcesKey`.
//
// The 光遇 JSON file lives only on the author's machine, so the file-backed test
// skips silently elsewhere (like CommonSourcesSmokeTests).
@Suite("AggregateSearchSmoke", .serialized)
struct AggregateSearchSmokeTests {

    static var guangyuPath: String {
        ProcessInfo.processInfo.environment["GUANGYU_SOURCE_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/光遇聚合26.5.30.json"
    }

    /// Decode a Legado source JSON file, tolerating a leading UTF-8 BOM (these
    /// aggregate exports are saved as utf-8-sig).
    private func loadFirstSource(_ path: String) -> BookSource? {
        guard var data = FileManager.default.contents(atPath: path) else { return nil }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.count >= 3, Array(data.prefix(3)) == bom { data.removeFirst(3) }
        let sources = (try? JSONDecoder().decode([BookSource].self, from: data)) ?? []
        return sources.first
    }

    /// Run a source's jsLib + searchUrl `<js>` with a given runtime variable and
    /// return the resolved URL string (the `data:;base64,…` pseudo-URL for 光遇).
    private func resolveSearchURL(
        source: BookSource, variableJSON: String, key: String, page: Int
    ) -> String? {
        let engine = JSCoreEngine()
        engine.bookSource = source
        engine.sourceBridge.getVariableHandler = { variableJSON }
        _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        var js = source.searchUrl
        for token in ["<js>", "</js>", "@js:"] {
            js = js.replacingOccurrences(of: token, with: "")
        }
        return engine.evaluate(js, bindings: [
            "key": key, "page": page, "baseUrl": source.bookSourceUrl,
        ])
    }

    /// Decode the base64 payload of a `data:;base64,<b64>,{options}` pseudo-URL into
    /// the aggregate search params (key / tab / sourcesKey / page).
    private func decodeSearchParams(_ dataURL: String) -> [String: Any]? {
        guard let sep = dataURL.range(of: ";base64,") else { return nil }
        let rest = dataURL[sep.upperBound...]
        // base64 alphabet has no ',', so it runs up to the options separator.
        let b64 = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(rest)
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Pure migration logic — no files, always runs.
    /// A legacy polluted variable (`更多设置[类型] = 单一平台`) must be normalized:
    /// the per-类型 platform moves to the app-private memory key, the source's own
    /// meta keys stay, and 更多设置 no longer pins search to one sub-site.
    @Test("sanitizeDiscoverVariable strips per-类型 platform out of 更多设置")
    func sanitizeStripsSearchPollution() {
        let polluted: [String: Any] = [
            "更多设置": ["搜索模式": "小说", "小说": "番茄", "漫画": "腾讯", "强制搜索": "0"],
            "发现页来源": "番茄",
            "发现页类型": "小说",
            "线路": "https://v1.gyks.cf",
        ]

        let cleaned = DiscoverViewModel.sanitizeDiscoverVariable(polluted)
        let more = cleaned["更多设置"] as? [String: Any] ?? [:]

        // Per-类型 platform selections are gone (search now falls back to '全部').
        #expect(more["小说"] == nil)
        #expect(more["漫画"] == nil)
        // The source's own meta settings are preserved.
        #expect(more["搜索模式"] as? String == "小说")
        #expect(more["强制搜索"] as? String == "0")
        // Unrelated top-level keys (token/线路/discover) are untouched.
        #expect(cleaned["线路"] as? String == "https://v1.gyks.cf")
        #expect(cleaned["发现页来源"] as? String == "番茄")
        // The discover platform choice is remembered in the app-private key.
        let memory = cleaned[DiscoverViewModel.discoverPlatformMemoryKey] as? [String: Any] ?? [:]
        #expect(memory["小说"] as? String == "番茄")
        #expect(memory["漫画"] as? String == "腾讯")

        // Idempotent: a clean variable is returned unchanged.
        let again = DiscoverViewModel.sanitizeDiscoverVariable(cleaned)
        #expect(DiscoverViewModel.canonicalJSON(again) == DiscoverViewModel.canonicalJSON(cleaned))
    }

    /// End-to-end proof on 光遇: the SAME variable that pinned search to one site
    /// resolves `sourcesKey` to '全部' once sanitized — without it, it stays pinned.
    /// Skips (no failure) when the local 光遇 JSON isn't available.
    @Test("光遇 search resolves sourcesKey to 全部 after sanitize")
    func guangyuSourcesKeyAfterSanitize() {
        guard let source = loadFirstSource(Self.guangyuPath) else {
            print("⏭️  Skipping 光遇 sourcesKey test: \(Self.guangyuPath) not found")
            return
        }

        // 1) Polluted variable (what an older build persisted from discover).
        let pollutedDict: [String: Any] = ["更多设置": ["搜索模式": "小说", "小说": "番茄"]]
        let pollutedJSON = DiscoverViewModel.canonicalJSON(pollutedDict) ?? "{}"
        let pollutedParams = resolveSearchURL(
            source: source, variableJSON: pollutedJSON, key: "斗罗大陆", page: 1
        ).flatMap(decodeSearchParams)
        // Sanity: with the legacy pollution, search WAS pinned to a single site.
        #expect(pollutedParams?["sourcesKey"] as? String == "番茄")

        // 2) After sanitize, the per-类型 platform is gone → search hits '全部'.
        let cleanedDict = DiscoverViewModel.sanitizeDiscoverVariable(pollutedDict)
        let cleanedJSON = DiscoverViewModel.canonicalJSON(cleanedDict) ?? "{}"
        let cleanedParams = resolveSearchURL(
            source: source, variableJSON: cleanedJSON, key: "斗罗大陆", page: 1
        ).flatMap(decodeSearchParams)
        #expect(cleanedParams?["sourcesKey"] as? String == "全部")

        // An empty variable (fresh import, untouched discover) also means '全部'.
        let emptyParams = resolveSearchURL(
            source: source, variableJSON: "{}", key: "斗罗大陆", page: 1
        ).flatMap(decodeSearchParams)
        #expect(emptyParams?["sourcesKey"] as? String == "全部")
    }
}
