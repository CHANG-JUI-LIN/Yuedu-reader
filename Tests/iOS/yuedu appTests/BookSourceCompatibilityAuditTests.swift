import Foundation
import Combine
import os
import Testing

@testable import yuedu_app

/// One-shot compatibility audit against a real legado source pack.
///
/// Purpose: the static survey (rule fields, rule operators, URL options, `java.*` surface) says we
/// cover ~98.6% of what real sources use, yet packs that pass legado's own 校验书源 still feel
/// half-broken here. Only running our own pipeline over real sources says which stage actually
/// fails and why, so this drives `BookSourceHealthChecker` — the same five-stage probe the app's
/// 校验书源 uses (search → discovery → detail → toc → content) — and tallies the outcomes.
///
/// Off by default: it makes live requests to third-party sites and takes minutes. It runs only
/// when a config file exists at `/tmp/yuedu-source-audit.json`:
///
///     {"pack": "/absolute/path/to/pack.json", "limit": 120}
///
/// (A file switch rather than an environment variable because `xcodebuild test FOO=BAR` sets a
/// build setting, and `TEST_RUNNER_`-prefixed variables only reach a UI-test runner — neither
/// reaches a unit test hosted in the app.) It asserts nothing about pass rate — the report printed
/// at the end is the deliverable.
@Suite("Book source compatibility audit")
struct BookSourceCompatibilityAuditTests {

    private struct AuditConfig: Decodable {
        let pack: String
        let limit: Int?
        /// Optional substrings; when present only sources whose name matches one are audited.
        /// Used to re-run a single failing source with its logs, without a 120-source sweep.
        let names: [String]?
        /// Optional positions in the deduplicated list — a report's `index` — to re-audit a
        /// subset of a whole-pack run. Each row keeps its index in the new report.
        let indices: [Int]?
        /// Nil preserves the historical text-only audit; [] audits every media type.
        let sourceTypes: [Int]?
        /// An atomic checkpoint, including unfinished stages if the host exits early.
        let reportPath: String?
        /// A follow-up audit may explicitly cancel UI requests, recording the prerequisite
        /// rather than leaving a background test waiting indefinitely for user input.
        let cancelInteractiveRequests: Bool?
        /// True runs the probe at its full width: `BookSourceCheckPacing` narrows a run to keep
        /// a phone under MetricKit's CPU limit, which on the simulator only makes a whole-pack
        /// audit take an hour longer. The width itself is the app's (網路設定 → 並發數).
        let unpaced: Bool?
    }

    private static let configPath = "/tmp/yuedu-source-audit.json"

    private static var config: AuditConfig? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(AuditConfig.self, from: data)
    }

    // 180 minutes: a whole pack of ~800 sources runs at CPU-paced width (`BookSourceCheckPacing`)
    // and took 85+ minutes on the simulator (YCK 1330, 2026-11-07).
    @Test(.enabled(if: BookSourceCompatibilityAuditTests.config != nil), .timeLimit(.minutes(180)))
    @MainActor
    func auditRealSourcePack() async throws {
        let config = try #require(Self.config)
        let path = config.pack
        let limit = config.limit ?? 150
        let data = try #require(
            FileManager.default.contents(atPath: path),
            "source pack not readable at \(path)"
        )
        let all = try JSONDecoder().decode([BookSource].self, from: data)

        // Keep the original text-only default, but allow an explicit whole-pack audit.
        var seen = Set<String>()
        let listed = all.filter { source in
            let types = config.sourceTypes ?? [0]
            guard types.isEmpty || types.contains(source.bookSourceType) else { return false }
            guard !source.bookSourceUrl.isEmpty else { return false }
            if let names = config.names, !names.isEmpty {
                guard names.contains(where: { source.bookSourceName.contains($0) }) else {
                    return false
                }
            }
            return seen.insert(source.bookSourceUrl).inserted
        }
        let wanted = config.indices.map(Set.init)
        let picked = listed.enumerated().filter { wanted?.contains($0.offset) ?? true }.prefix(limit)
        let sources = picked.map(\.element)
        let listIndices = picked.map(\.offset)

        print("AUDIT pack=\(path) decoded=\(all.count) audited=\(sources.count)")

        let checker = config.unpaced == true
            ? BookSourceHealthChecker(cpuClock: BookSourceCheckCPUClock {
                BookSourceCheckPacing.Sample(wall: SourcePerfTrace.now, cpu: 0)
            })
            : BookSourceHealthChecker.shared
        let interactionRequests = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])
        let browserPresenter = LegadoJSBridge.sharedBrowserPresenter
        let captchaPresenter = LegadoJSBridge.sharedCaptchaPresenter
        if config.cancelInteractiveRequests == true {
            LegadoJSBridge.sharedBrowserPresenter = { request, completion in
                interactionRequests.withLock {
                    $0.append(["kind": "browser", "url": request.url, "title": request.title])
                }
                completion(nil)
            }
            LegadoJSBridge.sharedCaptchaPresenter = { request, completion in
                interactionRequests.withLock {
                    $0.append(["kind": "captcha", "sourceName": request.sourceName,
                               "sourceURL": request.sourceURL])
                }
                completion(nil)
            }
        }
        defer {
            if config.cancelInteractiveRequests == true {
                LegadoJSBridge.sharedBrowserPresenter = browserPresenter
                LegadoJSBridge.sharedCaptchaPresenter = captchaPresenter
            }
        }
        var policy = BookSourceCheckPolicy()
        policy.badAction = .markOnly          // never touch the user's source list
        checker.policy = policy
        checker.prepare(sources: sources)
        let startedAt = Date()
        var reportedIDs = Set<UUID>()
        var checkpointError: String?
        func checkpoint() {
            for item in checker.items where item.isFinished && reportedIDs.insert(item.source.id).inserted {
                print("AUDIT_PROGRESS \(reportedIDs.count)/\(sources.count) \(item.overallPass ? "PASS" : "FAIL") \(item.source.bookSourceName)")
            }
            guard let reportPath = config.reportPath else { return }
            do {
                let rows: [[String: Any]] = checker.items.enumerated().map { index, item in
                    [
                        "index": listIndices.indices.contains(index) ? listIndices[index] : index,
                        "sourceName": item.source.bookSourceName,
                        "sourceIdentifier": item.source.bookSourceUrl,
                        "sourceType": item.source.bookSourceType,
                        "finished": item.isFinished,
                        "passed": item.isFinished && item.overallPass,
                        "responseMs": item.responseTime,
                        "failureCategory": item.failureCategory.map { String(describing: $0) } ?? "",
                        "apiError": SourceAPIErrorLog.shared.last(for: item.source.bookSourceUrl)?.displayText ?? "",
                        "searchBookName": item.searchBook?.name ?? "",
                        "discoveryBookName": item.discoveryBook?.name ?? "",
                        "stages": ValidationStage.allCases.map { stage in
                            ["stage": String(describing: stage),
                             "status": String(describing: item.outcome(stage).status),
                             "summary": item.outcome(stage).summary]
                        },
                    ]
                }
                let report: [String: Any] = [
                    "pack": path,
                    "startedAt": ISO8601DateFormatter().string(from: startedAt),
                    "updatedAt": ISO8601DateFormatter().string(from: Date()),
                    "decodedCount": all.count,
                    "expectedCount": sources.count,
                    "completedCount": checker.finishedCount,
                    "passedCount": checker.passedCount,
                    "timeoutSeconds": policy.timeoutSeconds,
                    "keyword": policy.keyword,
                    "cancelInteractiveRequests": config.cancelInteractiveRequests == true,
                    "interactionRequests": interactionRequests.withLock { $0 },
                    "results": rows,
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            } catch {
                checkpointError = String(describing: error)
            }
        }
        checkpoint()
        let observation = checker.didPublish.sink { checkpoint() }
        await checker.runAll()
        observation.cancel()
        checkpoint()
        #expect(!sources.isEmpty)
        #expect(checker.finishedCount == sources.count)
        let allFinished = checker.items.allSatisfy { $0.isFinished }
        #expect(allFinished)
        #expect(checkpointError == nil, "Checkpoint failed: \(checkpointError ?? "")")

        // ── Report ────────────────────────────────────────────────────────────────
        var byCategory: [String: Int] = [:]
        var firstFailingStage: [String: Int] = [:]
        var passed = 0
        var contentOnly = 0
        var examples: [String: [String]] = [:]

        for item in checker.items {
            let name = item.source.bookSourceName
            switch item.health {
            case .passed:
                passed += 1
            case .contentError:
                contentOnly += 1
            default:
                break
            }
            if let category = item.failureCategory {
                let key = "\(category)"
                byCategory[key, default: 0] += 1
                if examples[key, default: []].count < 6 {
                    examples[key, default: []].append(name)
                }
            }
            if item.health != .passed,
               let stage = ValidationStage.allCases.first(where: { item.outcome($0).status == .fail }) {
                firstFailingStage["\(stage)", default: 0] += 1
            }
        }

        print("AUDIT ===== RESULT =====")
        print("AUDIT total=\(checker.items.count) passed=\(passed) contentOnly=\(contentOnly)")
        print("AUDIT --- first failing stage ---")
        for (stage, count) in firstFailingStage.sorted(by: { $0.value > $1.value }) {
            print("AUDIT stage \(stage): \(count)")
        }
        print("AUDIT --- failure category ---")
        for (category, count) in byCategory.sorted(by: { $0.value > $1.value }) {
            print("AUDIT cat \(category): \(count)  e.g. \(examples[category, default: []].joined(separator: ", "))")
        }
        print("AUDIT --- per-source detail ---")
        for item in checker.items {
            let stages = ValidationStage.allCases.map { stage -> String in
                switch item.outcome(stage).status {
                case .pass: return "o"
                case .fail: return "X"
                case .skipped: return "-"
                case .running, .pending: return "?"
                }
            }.joined()
            let summary = ValidationStage.allCases
                .compactMap { stage -> String? in
                    let outcome = item.outcome(stage)
                    guard outcome.status == .fail, !outcome.summary.isEmpty else { return nil }
                    return "\(stage):\(outcome.summary.prefix(90))"
                }
                .joined(separator: " | ")
            print("AUDIT row \(stages) \(item.responseTime)ms \(item.source.bookSourceName.prefix(20)) \(item.source.bookSourceUrl.prefix(38)) \(summary)")
        }
    }
}
