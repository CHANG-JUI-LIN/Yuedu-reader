import Foundation
import Testing
@testable import yuedu_app

// Regression coverage for 「书源设置里勾选默认搜索网站没有效果，还是会全局搜索」.
//
// Mechanism: aggregate sources (光遇/大灰狼) resolve their *search* sub-site filter
// from a per-source runtime variable the user edits in the source's OWN 书源设置 page:
//   tab        = 更多设置['搜索模式']
//   sourcesKey = 更多设置[tab] || '全部'
// So `更多设置` is source-owned state. The discover page may only write the variables
// the source's filter actions name (发现页类型/发现页来源) plus its app-private per-类型
// memory; touching 更多设置 (an earlier build stripped 更多设置[类型] and rewrote
// 搜索模式) silently reverts search to 全部 = 全局搜索.
//
// The 光遇 JSON file lives only on the author's machine, so the file-backed test
// skips silently elsewhere (like CommonSourcesSmokeTests).
@Suite("AggregateSearchSmoke", .serialized)
struct AggregateSearchSmokeTests {

    static var guangyuPath: String {
        ProcessInfo.processInfo.environment["GUANGYU_SOURCE_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/光遇聚合26.7.10.json"
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

    /// The core invariant — no files, always runs. Browsing the 發現 page (switching
    /// 类型, then 平台) must leave every key of the source-owned `更多设置` exactly as
    /// the user saved it in 书源设置, so search keeps hitting their 默认搜索网站.
    @MainActor
    @Test("discover filters never rewrite the source's 更多设置")
    func discoverFiltersPreserveSourceSettings() throws {
        var source = BookSource()
        source.bookSourceUrl = "aggregate-search-settings-\(UUID().uuidString)"
        source.bookSourceName = "Aggregator"
        source.enabledExplore = true

        let runtimeStore = BookSourceRuntimeStateStore.shared
        // What the source's 书源设置 page writes: 搜索模式 + one 默认搜索网站 row per 类型.
        let savedSettings: [String: String] = [
            "搜索模式": "小说",
            "小说": "番茄",
            "听书": "喜马拉雅,懒人",
            "漫画": "全部",
            "短剧": "全部",
            "显示图片": "true",
            "强制搜索": "false",
            "目录显示来源": "true",
        ]
        let initial: [String: Any] = ["发现页类型": "小说", "更多设置": savedSettings]
        runtimeStore.setSourceVariableJSON(
            DiscoverViewModel.canonicalJSON(initial) ?? "{}", for: source.bookSourceUrl
        )
        defer { runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let model = DiscoverViewModel()
        model.exploreSources = [source]
        model.selectedSourceId = source.id
        model.filters = [
            DiscoverFilter(
                title: "类型", paramKey: "发现页类型",
                options: ["小说", "听书"], selected: "小说"
            ),
            DiscoverFilter(
                title: "平台", paramKey: "发现页来源",
                options: ["全部", "番茄", "喜马拉雅"], selected: "全部"
            ),
        ]

        model.selectFilter(try #require(model.filters.first), value: "听书")
        model.selectFilter(try #require(model.filters.last), value: "喜马拉雅")

        let stored = try #require(runtimeStore.sourceVariableJSON(for: source.bookSourceUrl))
        let dict = try #require(Self.jsonObject(stored))
        let more = try #require(dict["更多设置"] as? [String: String])

        // Source-owned settings survive byte-for-byte…
        #expect(more == savedSettings)
        // …while the discover page's own choices land in its own keys.
        #expect(dict["发现页类型"] as? String == "听书")
        #expect(dict["发现页来源"] as? String == "喜马拉雅")
        let memory = try #require(
            dict[DiscoverViewModel.discoverPlatformMemoryKey] as? [String: Any]
        )
        #expect(memory["听书"] as? String == "喜马拉雅")
    }

    /// End-to-end proof on 光遇: the 默认搜索网站 stored in 更多设置[类型] is what its
    /// searchUrl resolves as `sourcesKey`; only an absent/全部 row means 全局搜索.
    /// Skips (no failure) when the local 光遇 JSON isn't available.
    @Test("光遇 search resolves sourcesKey from the configured 默认搜索网站")
    func guangyuSourcesKeyFollowsConfiguredSite() {
        guard let source = loadFirstSource(Self.guangyuPath) else {
            print("⏭️  Skipping 光遇 sourcesKey test: \(Self.guangyuPath) not found")
            return
        }

        func sourcesKey(for variables: [String: Any]) -> String? {
            resolveSearchURL(
                source: source,
                variableJSON: DiscoverViewModel.canonicalJSON(variables) ?? "{}",
                key: "斗罗大陆",
                page: 1
            )
            .flatMap(decodeSearchParams)
            .flatMap { $0["sourcesKey"] as? String }
        }

        // A configured single site pins search to it…
        #expect(sourcesKey(for: ["更多设置": ["搜索模式": "小说", "小说": "番茄"]]) == "番茄")
        // …a multi-site pick is passed through verbatim…
        #expect(sourcesKey(for: ["更多设置": ["搜索模式": "小说", "小说": "番茄,七猫"]]) == "番茄,七猫")
        // …and 搜索模式 picks which row is read.
        #expect(
            sourcesKey(for: ["更多设置": ["搜索模式": "听书", "小说": "番茄", "听书": "喜马拉雅"]])
                == "喜马拉雅"
        )
        // Only an unset (or 全部) row falls back to searching every sub-site.
        #expect(sourcesKey(for: ["更多设置": ["搜索模式": "小说"]]) == "全部")
        #expect(sourcesKey(for: [:]) == "全部")
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
