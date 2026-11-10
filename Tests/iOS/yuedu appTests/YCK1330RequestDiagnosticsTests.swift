import Foundation
import Testing
@testable import yuedu_app

/// Opt-in request diagnostics: records the current engine's bytes without sending requests.
@Suite("YCK1330 request diagnostics", .serialized)
struct YCK1330RequestDiagnosticsTests {
    private static let configPath = "/tmp/yuedu-source-request-audit.json"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: configPath)))
    func inspectRequests() async throws {
        struct Config: Decodable {
            let pack: String
            let reportPath: String
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: Self.configPath)))
        let sources = try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: URL(fileURLWithPath: config.pack)))
        var rows: [[String: Any]] = []
        for index in [15, 33, 65, 118] {
            let source = sources[index]
            let parsed = AnalyzeUrl(ruleUrl: source.searchUrl, key: "我的", page: 1, baseUrl: source.bookSourceUrl)
            let request = try #require(parsed.toURLRequest())
            rows.append([
                "kind": "searchCharset", "packIndex": index, "sourceName": source.bookSourceName,
                "charset": parsed.charset ?? "", "method": request.httpMethod ?? "",
                "url": request.url?.absoluteString ?? "",
                "body": request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                "expectedGBKKeyword": "%CE%D2%B5%C4",
            ])
        }
        let engine = JSCoreEngine()
        for index in [13, 93] {
            let source = sources[index]
            let entries = try #require(try JSONSerialization.jsonObject(with: Data(source.exploreUrl.utf8)) as? [[String: Any]])
            let raw = try #require(entries.compactMap { $0["url"] as? String }.first { !$0.isEmpty })
            let parsed = AnalyzeUrl(ruleUrl: raw, page: 1, baseUrl: source.bookSourceUrl, jsEvaluator: { code, bindings in
                engine.evaluateIsolated(code, bindings: bindings)
            })
            rows.append([
                "kind": "emptyTemplate", "packIndex": index, "sourceName": source.bookSourceName,
                "rawURL": raw, "parsedURL": parsed.url,
                "requestURL": parsed.toURLRequest()?.url?.absoluteString ?? "",
                "scriptError": engine.lastError ?? "",
            ])
        }
        let nativeSource = sources[40]
        let nativeRequest = await nativeSource.renderSearchURL(query: "我的", page: 1)
        rows.append([
            "kind": "nativePageTemplate", "packIndex": 40, "sourceName": nativeSource.bookSourceName,
            "rawURL": nativeSource.searchUrl, "renderedURL": nativeRequest.url,
            "routesToRuntime": nativeSource.shouldUseLegadoRuntimeFetch(for: nativeSource.searchUrl),
        ])
        let report: [String: Any] = ["requests": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.reportPath), options: .atomic)
        #expect(rows.count == 7)
    }
}
