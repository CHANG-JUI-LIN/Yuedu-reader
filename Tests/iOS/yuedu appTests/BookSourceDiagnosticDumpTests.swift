import Foundation
import os
import Testing

@testable import yuedu_app

/// One source at a time through the 書源驗證 probe, with everything it saw written down: every
/// request and response body (`WebCrawlerDebugger`) and every rule step (`RuleDebugEvent`).
///
/// The pack audit (`BookSourceCompatibilityAuditTests`) says which stage of which source failed;
/// this says why — what the site answered and what each rule read from it — so a failure can
/// be told apart as the site's (an error page, a block, nothing there) or ours (a rule our
/// engine reads differently), and a saved body can become an offline regression fixture.
///
/// Off by default: it makes live requests. It runs only when `/tmp/yuedu-source-diag.json`
/// exists:
///
///     {"pack": "/abs/pack.json", "indices": [3, 17], "outDir": "/abs/dir"}
///
/// `indices` count sources the way the audit report's `index` does: every media type, sources
/// without a URL skipped, the first of each `bookSourceUrl` kept. `names` (substrings) may be
/// given instead. One `<index>.json` per source lands in `outDir`.
@Suite("Book source diagnostic dump")
struct BookSourceDiagnosticDumpTests {

    private struct DumpConfig: Decodable {
        let pack: String
        let indices: [Int]?
        let names: [String]?
        let outDir: String
        /// Bytes of each response body kept; the whole page by default.
        let bodyLimit: Int?
    }

    private static let configPath = "/tmp/yuedu-source-diag.json"

    private static var config: DumpConfig? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(DumpConfig.self, from: data)
    }

    @Test(.enabled(if: BookSourceDiagnosticDumpTests.config != nil), .timeLimit(.minutes(60)))
    @MainActor
    func dumpSources() async throws {
        let config = try #require(Self.config)
        let data = try #require(FileManager.default.contents(atPath: config.pack))
        let all = try JSONDecoder().decode([BookSource].self, from: data)
        var seen = Set<String>()
        let listed = all.filter { source in
            guard !source.bookSourceUrl.isEmpty else { return false }
            return seen.insert(source.bookSourceUrl).inserted
        }
        let selected: [(Int, BookSource)] = listed.enumerated().filter { index, source in
            if let indices = config.indices { return indices.contains(index) }
            if let names = config.names {
                return names.contains(where: { source.bookSourceName.contains($0) })
            }
            return false
        }.map { ($0.offset, $0.element) }
        try FileManager.default.createDirectory(
            atPath: config.outDir, withIntermediateDirectories: true
        )

        let browserPresenter = LegadoJSBridge.sharedBrowserPresenter
        let captchaPresenter = LegadoJSBridge.sharedCaptchaPresenter
        LegadoJSBridge.sharedBrowserPresenter = { _, completion in completion(nil) }
        LegadoJSBridge.sharedCaptchaPresenter = { _, completion in completion(nil) }
        let debugger = WebCrawlerDebugger.shared
        debugger.isRecording = true
        debugger.includesParseEvents = true
        debugger.bodyLimit = config.bodyLimit ?? 4 * 1024 * 1024
        defer {
            LegadoJSBridge.sharedBrowserPresenter = browserPresenter
            LegadoJSBridge.sharedCaptchaPresenter = captchaPresenter
            debugger.isRecording = false
            debugger.includesParseEvents = false
            debugger.bodyLimit = WebCrawlerDebugger.defaultBodyLimit
        }

        let checker = BookSourceHealthChecker.shared
        var policy = BookSourceCheckPolicy()
        policy.badAction = .markOnly
        checker.policy = policy

        for (index, source) in selected {
            debugger.clear()
            let ruleSteps = OSAllocatedUnfairLock<[String]>(initialState: [])
            let host = BookSourceSession.session(for: source).host
            await host.setDebugObserver { event in
                let line = event.legadoStyleLog
                ruleSteps.withLock { $0.append(line) }
            }
            checker.prepare(sources: [source])
            await checker.runAll()
            await host.setDebugObserver(nil)
            // The capture points hand their entries to the main actor in a Task each; let the
            // queued ones run before reading. (A diagnostic tool: a short entry list is only
            // less evidence, never a wrong verdict.)
            for _ in 0..<50 { await Task.yield() }

            let item = try #require(checker.items.first)
            let network: [[String: Any]] = debugger.logs.map { entry in
                var row: [String: Any] = [
                    "type": entry.type.rawValue,
                    "message": entry.message,
                    "url": entry.url ?? "",
                ]
                switch entry.detail {
                case .headers(let headers): row["headers"] = headers
                case .body(let body): row["body"] = body
                case .text(let text): row["text"] = text
                case nil: break
                }
                return row
            }
            let report: [String: Any] = [
                "index": index,
                "sourceName": source.bookSourceName,
                "sourceIdentifier": source.bookSourceUrl,
                "passed": item.isFinished && item.overallPass,
                "failureCategory": item.failureCategory.map { String(describing: $0) } ?? "",
                "apiError": SourceAPIErrorLog.shared.last(for: source.bookSourceUrl)?.displayText ?? "",
                "stages": ValidationStage.allCases.map { stage in
                    ["stage": String(describing: stage),
                     "status": String(describing: item.outcome(stage).status),
                     "summary": item.outcome(stage).summary]
                },
                "network": network,
                "rules": ruleSteps.withLock { $0 },
            ]
            let out = URL(fileURLWithPath: config.outDir).appendingPathComponent("\(index).json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: out, options: .atomic)
            print("DIAG \(index) \(item.overallPass ? "PASS" : "FAIL") \(source.bookSourceName) → \(out.path)")
        }
        #expect(!selected.isEmpty)
    }
}
