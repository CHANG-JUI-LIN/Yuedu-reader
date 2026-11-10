import Foundation
import SwiftSoup
import Testing
@testable import yuedu_app

/// Opt-in diagnostics for real responses saved during a source-pack audit.
/// No live request and no pass-rate assertion: this separates extraction defects
/// from a site's current transport behavior without changing production rules.
@Suite("Captured book source response audit", .serialized)
struct CapturedBookSourceResponseAuditTests {
    private struct Config: Decodable {
        struct Response: Decodable {
            let packIndex: Int
            let html: String
            let baseURL: String
        }
        let pack: String
        let responses: [Response]
        let urlIndices: [Int]
        let reportPath: String
    }
    private static let configPath = "/tmp/yuedu-source-response-audit.json"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: configPath)))
    func inspectCapturedResponses() async throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: Self.configPath)))
        let sources = try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: URL(fileURLWithPath: config.pack)))
        var rows: [[String: Any]] = []
        for entry in config.responses {
            let source = sources[entry.packIndex]
            let data = try Data(contentsOf: URL(fileURLWithPath: entry.html))
            let html = try #require(HTMLResponseDecoder.decode(data: data, response: nil))
            let (bookCount, bookNames, detailName) = try await BookSourceSession.session(for: source).parse { bridge in
                bridge.debugObserver = { event in
                    print("CAPTURED_RESPONSE \(entry.packIndex) \(event.legadoStyleLog)")
                }
                defer { bridge.debugObserver = nil }
                let books = try bridge.parseSearchResults(html: html, baseURL: entry.baseURL, source: source)
                let detailName = entry.packIndex == 81
                    ? try bridge.parseBookInfo(html: html, bookUrl: entry.baseURL,
                                               baseURL: entry.baseURL, source: source).name
                    : ""
                return (books.count, books.prefix(3).map(\.name), detailName)
            }
            var row: [String: Any] = [
                "packIndex": entry.packIndex,
                "sourceName": source.bookSourceName,
                "sourceIdentifier": source.bookSourceUrl,
                "responseBytes": data.count,
                "bookCount": bookCount,
                "bookNames": bookNames,
                "detailName": detailName,
            ]
            // A table row reparsed as a standalone document may lose its table-only
            // nodes. Record both sides using the app's actual SwiftSoup dependency.
            let document = try SwiftSoup.parse(html)
            let tableRows = try document.select("tr:has(td)")
            row["tableRowCount"] = tableRows.size()
            if let firstRow = tableRows.first() {
                row["firstRowCellsBeforeSerialization"] = try firstRow.select("td").size()
                let reparsed = try SwiftSoup.parse(firstRow.outerHtml())
                row["firstRowCellsAfterStandaloneParse"] = try reparsed.select("td").size()
            }
            rows.append(row)
        }
        var urls: [[String: Any]] = []
        for index in config.urlIndices {
            let source = sources[index]
            var expressions: [String] = []
            let parsed = AnalyzeUrl(ruleUrl: source.searchUrl, key: "我的", page: 1,
                                    baseUrl: source.bookSourceUrl, jsEvaluator: { script, _ in
                expressions.append(script)
                return script.contains("encodeURIComponent") ? "keyword" : "https://example.invalid"
            })
            urls.append(["packIndex": index, "sourceName": source.bookSourceName,
                         "rawURL": source.searchUrl, "expressions": expressions,
                         "parsedURL": parsed.url])
        }
        let report: [String: Any] = ["responses": rows, "urlTemplateDiagnostics": urls]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.reportPath), options: .atomic)
        #expect(rows.count == config.responses.count)
    }
}
