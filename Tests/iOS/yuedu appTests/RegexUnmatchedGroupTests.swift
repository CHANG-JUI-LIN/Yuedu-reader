import Testing
@testable import yuedu_app

/// An AllInOne regex (a `:` list rule) hands each match's groups to `$N`. A group that its
/// alternation branch left unmatched is "" in Legado — `AnalyzeByRegex.getElements` adds
/// `resM.group(i) ?: ""` (AnalyzeByRegex.kt:47), where Java itself answers null (oracle:
/// `scripts/legado-compat/oracle/cases/regex-unmatched-group.json`). `makeUpRule` then writes
/// that "" and, for a list, nothing at all for a `$N` past its last group: only a result that
/// is no list keeps the literal (AnalyzeRule.kt:721–729).
///
/// 起点中文 (YCK1331 #370) lists 卷 and 章 with one alternation. Its 卷 rows kept the literal
/// `$1` as their URL (`https://www.qidian.com/book/$1`), so they did not read as volumes and
/// the source check read one as the first chapter.
@Suite("AllInOne regex unmatched groups")
struct RegexUnmatchedGroupTests {
    private static let html = #"<h3>第一卷</h3><li><a href="/c/1">第1章</a></li>"#
    private static let list = #":<li><a href="(.*?)">(.*?)</a></li>|<h3>(.*?)</h3>"#

    private let js = JSCoreEngine()

    private func rows() -> (ModernRuleEngine, [Any]) {
        let engine = ModernRuleEngine()
        let js = self.js
        engine.jsEvaluator = { script, result in js.evaluateRuleStep(script, result: result) }
        engine.setContent(Self.html, baseUrl: "https://q.test/book/1")
        return (engine, engine.getElements(ruleStr: Self.list))
    }

    /// Oracle "an alternation branch that did not match leaves its groups null": the 卷 row is
    /// `<h3>第一卷</h3>,null,null,第一卷`, the 章 row `<li>…</li>,/c/1,第1章,null`.
    @Test func unmatchedGroupsAreEmptyStrings() throws {
        let (_, elements) = rows()
        #expect(elements.count == 2)
        let volume = try #require(elements.first as? [String?])
        let chapter = try #require(elements.last as? [String?])
        #expect(volume == ["<h3>第一卷</h3>", "", "", "第一卷"])
        #expect(chapter == [#"<li><a href="/c/1">第1章</a></li>"#, "/c/1", "第1章", ""])
    }

    @Test func groupReferencesWriteNothingForAnUnmatchedGroup() throws {
        let (engine, elements) = rows()
        engine.setContent(elements[0], baseUrl: "https://q.test/book/1")
        #expect(engine.getString(ruleStr: "$1") == "")
        #expect(engine.getString(ruleStr: "$2$3") == "第一卷")
        // 起点中文's isVolume rule: an empty `$1` is a volume.
        #expect(engine.getString(ruleStr: #"$1@js:result == "" ? "true" : "false""#) == "true")

        engine.setContent(elements[1], baseUrl: "https://q.test/book/1")
        #expect(engine.getString(ruleStr: "$1", isUrl: true) == "https://q.test/c/1")
        #expect(engine.getString(ruleStr: "$2$3") == "第1章")
        #expect(engine.getString(ruleStr: #"$1@js:result == "" ? "true" : "false""#) == "false")
        #expect(js.lastError == nil)
    }

    @Test func aGroupPastTheLastWritesNothing() {
        let (engine, elements) = rows()
        engine.setContent(elements[1], baseUrl: "https://q.test/book/1")
        #expect(engine.getString(ruleStr: "$2$9") == "第1章")
    }
}
