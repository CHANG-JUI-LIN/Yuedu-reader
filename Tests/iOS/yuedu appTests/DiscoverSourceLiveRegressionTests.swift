import Foundation
import Testing
@testable import yuedu_app

@Suite("Discover Source Live Regression", .serialized)
struct DiscoverSourceLiveRegressionTests {
    private static let isEnabled =
        ProcessInfo.processInfo.environment["RUN_ALL_SOURCE_LIVE_TESTS"] == "1"
    private static let reportPath = "/tmp/yuedu_discover_regression.json"

    private struct Attempt: Codable {
        let sourceName: String
        let itemTitle: String
        let rawURL: String
        let resolvedURL: String?
        let responseLength: Int?
        let responseHead: String?
        let bookCount: Int
        let jsError: String?
        let error: String?
    }

    private struct SourceResult: Codable {
        let sourceName: String
        let categoryCount: Int
        let attempts: [Attempt]
    }

    @Test(
        "Qimao and Shuqi categories return discover books",
        .enabled(if: isEnabled, "Set RUN_ALL_SOURCE_LIVE_TESTS=1 to run real discover endpoints"),
        .timeLimit(.minutes(10))
    )
    func discoverBooks() async throws {
        let paths = [
            "/Users/zhangruilin/Desktop/Test document/RULE/七猫四合一本地版（同人）.json",
            "/Users/zhangruilin/Desktop/Test document/RULE/书旗（同人）.json",
        ]
        var results: [SourceResult] = []

        for path in paths {
            var source = try loadSource(path)
            source.id = UUID()
            source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
            let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
            let items = await bridge.getExploreItems(page: 1)
            var attempts: [Attempt] = []

            for item in items.filter({
                !($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }).prefix(3) {
                let rawURL = item.url ?? ""
                do {
                    let (html, finalURL) = try await bridge.fetch(ruleUrl: rawURL, page: 1)
                    let books = bridge.parseExploreResults(
                        html: html,
                        baseURL: finalURL,
                        source: source
                    )
                    attempts.append(Attempt(
                        sourceName: source.bookSourceName,
                        itemTitle: item.title ?? "",
                        rawURL: String(rawURL.prefix(600)),
                        resolvedURL: redacted(finalURL),
                        responseLength: html.count,
                        responseHead: String(html.prefix(300)).replacingOccurrences(of: "\n", with: " "),
                        bookCount: books.count,
                        jsError: bridge.lastSourceScriptError,
                        error: nil
                    ))
                } catch {
                    attempts.append(Attempt(
                        sourceName: source.bookSourceName,
                        itemTitle: item.title ?? "",
                        rawURL: String(rawURL.prefix(600)),
                        resolvedURL: nil,
                        responseLength: nil,
                        responseHead: nil,
                        bookCount: 0,
                        jsError: bridge.lastSourceScriptError,
                        error: String(error.localizedDescription.prefix(400))
                    ))
                }
                write(results + [SourceResult(
                    sourceName: source.bookSourceName,
                    categoryCount: items.count,
                    attempts: attempts
                )])
            }

            results.append(SourceResult(
                sourceName: source.bookSourceName,
                categoryCount: items.count,
                attempts: attempts
            ))
            write(results)
        }

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.categoryCount > 0 })
        #expect(results.allSatisfy { result in
            result.attempts.contains { $0.bookCount > 0 }
        })
    }

    private func loadSource(_ path: String) throws -> BookSource {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let source = try? JSONDecoder().decode(BookSource.self, from: data) {
            return source
        }
        return try #require(JSONDecoder().decode([BookSource].self, from: data).first)
    }

    private func redacted(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.host != nil else {
            return String(value.prefix(300))
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? String(value.prefix(300))
    }

    private func write(_ results: [SourceResult]) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.reportPath), options: .atomic)
    }
}
