import Foundation
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
    }

    private static let configPath = "/tmp/yuedu-source-audit.json"

    private static var config: AuditConfig? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(AuditConfig.self, from: data)
    }

    @Test(.enabled(if: BookSourceCompatibilityAuditTests.config != nil), .timeLimit(.minutes(60)))
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

        // Deduplicate by URL and keep text sources only: audio/comic/file types fail for reasons
        // that say nothing about rule-engine compatibility.
        var seen = Set<String>()
        let sources = all.filter { source in
            guard source.bookSourceType == 0 else { return false }
            guard !source.bookSourceUrl.isEmpty else { return false }
            if let names = config.names, !names.isEmpty {
                guard names.contains(where: { source.bookSourceName.contains($0) }) else {
                    return false
                }
            }
            return seen.insert(source.bookSourceUrl).inserted
        }.prefix(limit).map { $0 }

        print("AUDIT pack=\(path) decoded=\(all.count) audited=\(sources.count)")

        let checker = BookSourceHealthChecker.shared
        var policy = BookSourceCheckPolicy()
        policy.badAction = .markOnly          // never touch the user's source list
        checker.policy = policy
        checker.prepare(sources: sources)
        await checker.runAll()

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
