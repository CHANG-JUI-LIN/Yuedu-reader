import Foundation
import Testing
@testable import yuedu_app

// MARK: - Legado Alignment Tests
//
// Diff-driven test suite: each fixture contains
//   - offline HTML (or JSON) captured from the real website
//   - the exact rule string from the book source JSON
//   - the expected output as produced by Android Legado
//
// Workflow:
//   1. Run Legado on Android with the same book source.
//   2. Enable verbose debug in Legado → copy the "result" value.
//   3. Paste the HTML + rule + expected output into a new fixture below.
//   4. Run `xcodebuild test -scheme "yuedu appTests" -only-testing:LegadoAlignmentTests`.
//   5. Fix divergences in ModernRuleEngine until all assertions pass.
//
// Collected pipeline events are printed as legadoStyleLog lines so you
// can paste them directly into scripts/compare_logs.py.
//
// IMPORTANT: Keep fixtures OFFLINE (no live network) so tests are
// deterministic and CI-safe.

// ── Fixture helper ────────────────────────────────────────────────────────────

private struct Fixture: Sendable {
    let name: String
    let contentType: FixtureContentType
    let content: String
    let rule: String
    let expected: String          // expected output (from Android Legado)
    let expectedList: [String]?   // set when rule returns a list

    enum FixtureContentType { case html, json }

    init(_ name: String, html: String, rule: String, expected: String) {
        self.name = name; self.contentType = .html
        self.content = html; self.rule = rule
        self.expected = expected; self.expectedList = nil
    }

    init(_ name: String, json: String, rule: String, expected: String) {
        self.name = name; self.contentType = .json
        self.content = json; self.rule = rule
        self.expected = expected; self.expectedList = nil
    }

    init(_ name: String, html: String, rule: String, expectedList: [String]) {
        self.name = name; self.contentType = .html
        self.content = html; self.rule = rule
        self.expected = ""; self.expectedList = expectedList
    }

    init(_ name: String, json: String, rule: String, expectedList: [String]) {
        self.name = name; self.contentType = .json
        self.content = json; self.rule = rule
        self.expected = ""; self.expectedList = expectedList
    }
}

/// Run a fixture through ModernRuleEngine, collect debug events, and return
/// (result, legadoStyleLog lines).
private func run(_ fixture: Fixture) -> (result: String, listResult: [String], log: [String]) {
    var events: [RuleDebugEvent] = []
    let engine = ModernRuleEngine()
    engine.debugObserver = { events.append($0) }

    switch fixture.contentType {
    case .html:
        engine.setContent(fixture.content)
    case .json:
        if let data = fixture.content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            engine.setContent(json)
        } else {
            engine.setContent(fixture.content)
        }
    }

    let str    = engine.getString(ruleStr: fixture.rule)
    let list   = fixture.expectedList != nil
                 ? engine.getStringList(ruleStr: fixture.rule)
                 : []
    let logLines = events.map { $0.legadoStyleLog }
    return (str, list, logLines)
}

// ── Fixtures ──────────────────────────────────────────────────────────────────
//
// ★ Add real fixtures below as you collect them from Android Legado.
//   Each fixture is self-contained: paste HTML + rule + Legado output.
//
// The placeholders below demonstrate the structure and provide basic
// sanity checks until real fixtures are added.

private let fixtures: [Fixture] = [

    // ── 1. CSS selector — book title ─────────────────────────────────────────
    Fixture(
        "CSS: extract book title",
        html: """
        <html><body>
          <div class="book-detail">
            <h1 class="title">三體</h1>
            <span class="author">劉慈欣</span>
          </div>
        </body></html>
        """,
        rule: "h1.title",
        expected: "三體"
    ),

    // ── 2. CSS selector with @text suffix ────────────────────────────────────
    Fixture(
        "CSS: @text suffix",
        html: """
        <html><body>
          <div class="info">
            <span class="author">作者：劉慈欣</span>
          </div>
        </body></html>
        """,
        rule: "span.author@text##作者：##",
        expected: "劉慈欣"
    ),

    // ── 3. XPath — book title ────────────────────────────────────────────────
    Fixture(
        "XPath: extract title",
        html: """
        <html><body>
          <div id="info"><h1>基地</h1></div>
        </body></html>
        """,
        rule: "//div[@id='info']/h1/text()",
        expected: "基地"
    ),

    // ── 4. JSONPath — title from search result ────────────────────────────────
    Fixture(
        "JSONPath: book title",
        json: """
        {"code":200,"data":{"name":"銀河英雄傳說","author":"田中芳樹"}}
        """,
        rule: "$.data.name",
        expected: "銀河英雄傳說"
    ),

    // ── 5. JSONPath — list of search results ─────────────────────────────────
    Fixture(
        "JSONPath: search list (book names)",
        json: """
        {"data":{"list":[{"name":"三體"},{"name":"黑暗森林"},{"name":"死神永生"}]}}
        """,
        rule: "$.data.list[*].name",
        expectedList: ["三體", "黑暗森林", "死神永生"]
    ),

    // ── 6. CSS list — chapter titles ─────────────────────────────────────────
    Fixture(
        "CSS: chapter list",
        html: """
        <html><body>
          <ul id="chapter-list">
            <li><a href="/ch1">第一章</a></li>
            <li><a href="/ch2">第二章</a></li>
            <li><a href="/ch3">第三章</a></li>
          </ul>
        </body></html>
        """,
        rule: "#chapter-list li a@text",
        expectedList: ["第一章", "第二章", "第三章"]
    ),

    // ── 7. Regex replacement — strip publisher noise ──────────────────────────
    Fixture(
        "Regex: strip square-bracket ads",
        html: """
        <html><body><p class="content">精彩內容[本站首發]繼續閱讀</p></body></html>
        """,
        rule: "p.content##\\[.*?\\]##",
        expected: "精彩內容繼續閱讀"
    ),

    // ── 8. @@ operator — multi-level CSS ─────────────────────────────────────
    Fixture(
        "CSS: @@ multi-level",
        html: """
        <html><body>
          <div class="list">
            <div class="item"><span class="name">神鵰俠侶</span></div>
            <div class="item"><span class="name">天龍八部</span></div>
          </div>
        </body></html>
        """,
        rule: "div.list@@div.item@@span.name@text",
        expectedList: ["神鵰俠侶", "天龍八部"]
    ),

    // ── 9. || fallback rule ───────────────────────────────────────────────────
    Fixture(
        "|| fallback: second rule fires",
        html: """
        <html><body>
          <div class="backup-title">倚天屠龍記</div>
        </body></html>
        """,
        rule: "div.main-title||div.backup-title",
        expected: "倚天屠龍記"
    ),

    // ── 10. Placeholder for real book source fixture ──────────────────────────
    // TODO: Replace with HTML from a real Legado book source + verified output.
    //
    // Fixture(
    //   "起點: search result name",
    //   html: "<paste_legado_debug_html_here>",
    //   rule: "<paste_exact_bookList_rule_from_json>",
    //   expected: "<paste_Legado_result_output>"
    // ),
]

// ── Test Suite ────────────────────────────────────────────────────────────────

@Suite("Legado Alignment — Single-Value Rules")
struct LegadoAlignmentStringTests {

    @Test("All single-value fixtures match Android Legado output",
          arguments: fixtures.filter { $0.expectedList == nil })
    fileprivate func fixture(f: Fixture) throws {
        let (result, _, log) = run(f)

        // Print pipeline log for side-by-side comparison with Android logcat
        print("\n── \(f.name) ──")
        log.forEach { print($0) }
        print("── Expected: \(f.expected)")
        print("── Got:      \(result)")

        #expect(
            result.trimmingCharacters(in: .whitespacesAndNewlines)
            == f.expected.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(f.name): iOS result '\(result)' ≠ Android result '\(f.expected)'"
        )
    }
}

@Suite("Legado Alignment — List Rules")
struct LegadoAlignmentListTests {

    @Test("All list-value fixtures match Android Legado output",
          arguments: fixtures.filter { $0.expectedList != nil })
    fileprivate func fixture(f: Fixture) throws {
        let (_, listResult, log) = run(f)
        guard let expected = f.expectedList else { return }

        print("\n── \(f.name) ──")
        log.forEach { print($0) }
        print("── Expected: \(expected)")
        print("── Got:      \(listResult)")

        #expect(
            listResult == expected,
            "\(f.name): iOS list \(listResult) ≠ Android list \(expected)"
        )
    }
}

// ── Pipeline Log Export Test ──────────────────────────────────────────────────
//
// This test is intentionally non-asserting. It runs ALL fixtures and
// writes a combined pipeline log to a temp file, ready for comparison:
//
//   scripts/compare_logs.py --ios /tmp/yuedu_all_fixtures.txt \
//                           --android /tmp/legado_raw.txt \
//                           --out report.html

@Suite("Legado Alignment — Log Export")
struct LegadoAlignmentExportTests {

    @Test("Export combined pipeline log for all fixtures")
    func exportAllFixtures() {
        var allLines: [String] = []
        for f in fixtures {
            allLines.append("=== \(f.name) ===")
            let (_, _, log) = run(f)
            allLines += log
        }
        let text = allLines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuedu_all_fixtures.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        print("\n📄  iOS pipeline log exported to:\n    \(url.path)")
        print("    Run: python3 scripts/compare_logs.py --ios \(url.path) --android <legado_raw.txt>")
    }
}
