import Foundation
import Testing
@testable import yuedu_app

struct ModernRuleEngineTests {
    @Test
    func cssExtractorMatchesLegacyOutput() throws {
        let html = """
        <html><body>
            <div class='item'><a class='title' href='/book/1'>斗羅大陸</a></div>
        </body></html>
        """
        let baseURL = "https://example.com/catalog"
        let rule = "@css:a.title@href"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)
        // Legado's AnalyzeByJSoup returns the attribute as written; a URL read makes it absolute.
        let url = ModernRuleEngine().setContent(html, baseUrl: baseURL).getString(ruleStr: rule, isUrl: true)

        #expect(modern == "/book/1")
        #expect(url == legacy)
        #expect(url == "https://example.com/book/1")
    }

    @Test
    func xpathPathMatchesLegacyOutput() throws {
        let html = """
        <html><body>
            <div id='content'>
                <p>第一段</p>
                <p>第二段</p>
            </div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@xpath://div[@id='content']/p[1]"

        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        // Legado's `AnalyzeByXPath.getString` joins JsoupXpath's `JXNode.asString()`, which for
        // an element is jsoup's `Element.toString()` — the outerHtml, not the text (JsoupXpath
        // 2.5.3). The legacy `RuleEngine` XPath returned the text; `XPathExtractor` takes every
        // `@xpath:`/`//` rule first, so that path no longer answers XPath rules.
        #expect(modern == "<p>第一段</p>")
    }

    @Test
    func xpathListMatchesLegacyOutput() throws {
        let html = """
        <html><body>
            <ul>
                <li><a href='/ch/1'>章節1</a></li>
                <li><a href='/ch/2'>章節2</a></li>
            </ul>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@xpath://li/a/@href"

        let legacy = RuleEngine.extractValueList(fromHTML: html, rule: rule, baseURL: baseURL)
        let modern = try ModernRuleEngine().extractList(from: html, rule: rule, baseURL: baseURL)
        // Legado's AnalyzeByXPath returns the attribute as written; a URL read makes it absolute.
        let urls = ModernRuleEngine().setContent(html, baseUrl: baseURL).getStringList(ruleStr: rule, isUrl: true)

        #expect(modern == ["/ch/1", "/ch/2"])
        #expect(urls == legacy)
        #expect(urls.first == "https://example.com/ch/1")
    }

    @Test
    func jsonPathMatchesLegacyOutput() throws {
        let json = """
        {
          "data": {
            "list": [
              {"title": "Book A"},
              {"title": "Book B"}
            ]
          }
        }
        """
        let baseURL = "https://api.example.com"
        let rule = "$.data.list[0].title"

        let legacy = RuleEngine.routeExtractValue(content: json, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: json, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern == "Book A")
    }

    @Test
    func regexChainMatchesLegacyOutput() throws {
        let html = "<div class='title'>【校對版】斗羅大陸</div>"
        let baseURL = "https://example.com"
        let rule = "@css:div.title@text##【.*?】##"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern == "斗羅大陸")
    }

    /// Legado's `AnalyzeByJSoup.getString` is null when nothing matched, and
    /// `AnalyzeRule.getString` skips every later step of a null (`result ?: continue`); only an
    /// `isUrl` read (`getString0`) hands the next step "". 英语阅读 (YCK1330/1331) reads a chapter
    /// link with `a@href@js:if(result!=null){…}else{result=baseUrl}` on a row with no link.
    @Test("a JSoup step that matches nothing skips the steps after it, except in an isUrl read")
    func unmatchedJsoupStepSkipsLaterSteps() {
        let base = "https://site.test/toc?id=1"
        let engine = ModernRuleEngine()
        engine.setContent(#"<div><h1 class="t">标题</h1></div>"#, baseUrl: base)
        var scripts = 0
        engine.jsEvaluator = { _, result in
            scripts += 1
            return "/chapter" + ((result as? String) ?? "")
        }

        #expect(engine.getString(ruleStr: "a@href@js:result") == "")
        #expect(engine.getString(ruleStr: "class.none@text##^##前缀") == "")
        #expect(engine.getString(ruleStr: "class.t@text##^##前缀") == "前缀标题")
        #expect(engine.getChapterURL(ruleStr: "a@href@js:result") == base)
        #expect(engine.getOptionalURL(ruleStr: "img@src@js:result") == "")
        #expect(scripts == 0)
        #expect(engine.getString(ruleStr: "a@href@js:result", isUrl: true) == "https://site.test/chapter")
        #expect(scripts == 1)

        // Several links: a text read joins them, a chapter link takes the first.
        engine.setContent(#"<div><a href="/c/1">1</a><a href="/c/2">2</a></div>"#, baseUrl: base)
        #expect(engine.getString(ruleStr: "a@href") == "/c/1\n/c/2")
        #expect(engine.getChapterURL(ruleStr: "a@href") == "https://site.test/c/1")
        #expect(engine.getChapterURL(ruleStr: "") == base)
    }

    @Test
    func jsBlockNewlineJSONPathListExtraction() {
        let engine = ModernRuleEngine()
        engine.setContent("payload")
        engine.jsEvaluator = { _, _ in
            #"{"data":[{"book_name":"斗罗大陆"},{"book_name":"斗罗大陆II"}]}"#
        }

        let elements = engine.getElements(ruleStr: """
        <js>
        request('/search');
        </js>
        $.data
        """)

        #expect(elements.count == 2)
        // Elements are the parsed JSON objects (Legado's JsonPath getList returns the
        // objects too), so check them the way a book-list parse reads them: each one
        // becomes the content for its field rules. Their `description` is not a contract —
        // Foundation prints a dictionary's CJK as `\U6597…`.
        guard elements.count == 2 else { return }
        for (element, name) in zip(elements, ["斗罗大陆", "斗罗大陆II"]) {
            engine.setContent(element)
            #expect(engine.getString(ruleStr: "$.book_name") == name)
            #expect(engine.getString(ruleStr: "book_name") == name)
        }
    }

    /// A JSONPath element is a parsed `JSONSerialization` object. When a rule needs it as
    /// text — a `##` replace or a regex — it reads as Legado's content does: the
    /// `LinkedHashMap` jayway (json-smart's default provider) read, whose `toString()` is
    /// `{key=value, …}` in document order. Never Foundation's plist description, which
    /// escapes CJK as `\U6597…` and writes `key = value;`.
    @Test
    func jsonObjectElementReplaceSeesMapText() throws {
        let engine = ModernRuleEngine()
        engine.setContent(#"{"data":[{"book_name":"斗罗大陆","url":"https://a/b"}]}"#)
        let elements = engine.getElements(ruleStr: "$.data")
        try #require(elements.count == 1)

        engine.setContent(elements[0])
        #expect(engine.getString(ruleStr: "##^##") == "{book_name=斗罗大陆, url=https://a/b}")
    }

    @Test
    func jsonObjectElementRegexMatchesMapText() throws {
        let engine = ModernRuleEngine()
        engine.setContent(#"{"data":[{"book_name":"斗罗大陆","url":"https://a/b"}]}"#)
        let elements = engine.getElements(ruleStr: "$.data")
        try #require(elements.count == 1)

        engine.setContent(elements[0])
        let matches = engine.getElements(ruleStr: #":book_name=([^,}]+)"#)

        try #require(matches.count == 1)
        let groups = try #require(matches[0] as? [String?])
        #expect(groups.count == 2)
        #expect(groups.last ?? nil == "斗罗大陆")
    }

    /// Legado's `RuleAnalyzer.splitRule`: the operator that occurs first splits the rule, and the
    /// JSONPath reader reads each piece by calling itself. 哔哩哔哩's search list
    /// `A&&B&&C||D` is A, B and "C, or else D" — reading `||` first returned only D's groups.
    @Test
    func jsonListSplitsByTheFirstOperatorAndAgainPerPiece() throws {
        let engine = ModernRuleEngine()
        engine.setContent(#"""
        {"data":{"result":[{"type":"video","data":[{"title":"v1"},{"title":"v2"}]},{"type":"user","data":[]}]}}
        """#)
        let elements = engine.getElements(
            ruleStr: "$.data.result[*].data[*]&&$.data.result.live_user[*]&&$.data.result.live_room[*]||$.data.result[*]")
        let titles = elements.compactMap { ($0 as? [String: Any])?["title"] as? String }
        #expect(titles == ["v1", "v2"])
        // C is empty, so its piece reads D: Legado's list ends with the two groups.
        #expect(elements.count == 4)

        let (type, parts) = RuleSyntaxParser.splitRuleByOperators("a&&b&&c||d")
        #expect(type == "&&")
        #expect(parts == ["a", "b", "c||d"])
        #expect(RuleSyntaxParser.splitRuleByOperators("[a||b]&&c").parts == ["[a||b]", "c"])
        #expect(RuleSyntaxParser.splitRuleByOperators("$.a||").parts == ["$.a"])
        #expect(RuleSyntaxParser.splitRuleByOperators("$.a").type.isEmpty)
    }

    /// Legado's `%%`: item i of each list for every index of the first list read. The JSONPath
    /// reader leaves an empty piece out; jsoup keeps it, so an empty first piece merges nothing.
    @Test
    func percentMergeFollowsTheFirstListRead() throws {
        let engine = ModernRuleEngine()
        engine.setContent(#"{"a":[1,2,3],"b":["x"]}"#)
        let merged = engine.getStringList(ruleStr: "$.a[*]%%$.none[*]%%$.b[*]")
        #expect(merged == ["1", "x", "2", "3"])
        #expect(RuleSyntaxParser.interleaveByFirst([["x"], [1, 2, 3].map(String.init)]) == ["x", "1"])

        let html = #"<ul><li class="a">1</li><li class="a">2</li><li class="b">x</li></ul>"#
        engine.setContent(html, baseUrl: "https://site.test/")
        #expect(engine.getElements(ruleStr: "class.none%%class.a").isEmpty)
        #expect(engine.getElements(ruleStr: "class.a%%class.none%%class.b").count == 3)
    }

}
