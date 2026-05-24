import Foundation
import Testing
@testable import yuedu_app

// MARK: - Helpers

/// Normalise whitespace for comparison so minor differences don't cause failures.
private func normalise(_ s: String) -> String {
    s.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Build a minimal BookSource with custom rules for testing.
private func makeSource(
    url: String = "https://example.com",
    name: String = "測試書源",
    searchBookList: String = "",
    searchName: String = "",
    searchAuthor: String = "",
    searchBookUrl: String = "",
    searchCoverUrl: String = "",
    searchIntro: String = "",
    tocChapterList: String = "",
    tocChapterName: String = "",
    tocChapterUrl: String = "",
    tocNextTocUrl: String = "",
    contentRule: String = "",
    contentTitle: String = "",
    contentNextUrl: String = ""
) -> BookSource {
    var source = BookSource()
    source.bookSourceUrl = url
    source.bookSourceName = name
    source.ruleSearch.bookList = searchBookList
    source.ruleSearch.name = searchName
    source.ruleSearch.author = searchAuthor
    source.ruleSearch.bookUrl = searchBookUrl
    source.ruleSearch.coverUrl = searchCoverUrl
    source.ruleSearch.intro = searchIntro
    source.ruleToc.chapterList = tocChapterList
    source.ruleToc.chapterName = tocChapterName
    source.ruleToc.chapterUrl = tocChapterUrl
    source.ruleToc.nextTocUrl = tocNextTocUrl
    source.ruleContent.content = contentRule
    source.ruleContent.title = contentTitle
    source.ruleContent.nextContentUrl = contentNextUrl
    return source
}

// MARK: - 2. Cross-Parser Compatibility Tests

@Suite("Cross-Parser Compatibility", .serialized)
struct CrossParserCompatibilityTests {

    // MARK: CSS

    @Test("Simple CSS selector produces same result")
    func cssSelector() throws {
        let html = """
        <html><body>
            <div class='book'><span class='title'>斗破蒼穹</span></div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:span.title@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern.contains("斗破蒼穹"))
    }

    @Test("CSS @href attribute extraction")
    func cssHrefAttribute() throws {
        let html = """
        <html><body>
            <a class='link' href='/detail/42'>詳情</a>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:a.link@href"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
    }

    // MARK: XPath

    @Test("XPath query produces same result")
    func xpathQuery() throws {
        let html = """
        <html><body>
            <div id='info'><p>作者：唐家三少</p></div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@xpath://div[@id='info']/p[1]"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern.contains("唐家三少"))
    }

    // MARK: JSONPath

    @Test("JSONPath query produces same result")
    func jsonPathQuery() throws {
        let json = """
        {"data":{"title":"完美世界","author":"辰東"}}
        """
        let baseURL = "https://api.example.com"
        let rule = "$.data.title"

        let legacy = RuleEngine.routeExtractValue(content: json, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: json, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern == "完美世界")
    }

    @Test("JSONPath nested array access")
    func jsonPathArray() throws {
        let json = """
        {"books":[{"name":"A"},{"name":"B"},{"name":"C"}]}
        """
        let baseURL = "https://api.example.com"
        let rule = "$.books[1].name"

        let legacy = RuleEngine.routeExtractValue(content: json, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: json, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern == "B")
    }

    // MARK: Regex

    @Test("Regex extraction produces same result")
    func regexExtraction() throws {
        let html = "<div class='info'>【連載中】仙逆</div>"
        let baseURL = "https://example.com"
        let rule = "@css:div.info@text##【.*?】##"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern == "仙逆")
    }

    // MARK: Jsoup Default

    @Test("Jsoup class.name@text syntax")
    func jsoupDefaultSyntax() throws {
        let html = """
        <html><body>
            <div class='bookname'><h1>凡人修仙傳</h1></div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "class.bookname@tag.h1@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern.contains("凡人修仙傳"))
    }

    // MARK: Operators

    @Test("Multiple rules with || operator")
    func orOperator() throws {
        let html = """
        <html><body>
            <span class='alt-title'>備用標題</span>
        </body></html>
        """
        let baseURL = "https://example.com"
        // First rule won't match; second should
        let rule = "@css:span.primary-title@text||@css:span.alt-title@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern.contains("備用標題"))
    }

    @Test("Multiple rules with && operator")
    func andOperator() throws {
        let html = """
        <html><body>
            <span class='first'>甲</span>
            <span class='second'>乙</span>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:span.first@text&&@css:span.second@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
        #expect(modern.contains("甲"))
        #expect(modern.contains("乙"))
    }

    // MARK: List extraction

    @Test("CSS list extraction compatible")
    func cssListExtraction() throws {
        let html = """
        <html><body>
            <ul><li><a href='/a'>甲</a></li><li><a href='/b'>乙</a></li></ul>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:li a@text"

        let legacy = RuleEngine.extractValueList(fromHTML: html, rule: rule, baseURL: baseURL)
        let modern = try ModernRuleEngine().extractList(from: html, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern.count == 2)
    }
}

@Suite("Browser Import Plain Text Regression", .serialized)
struct BrowserImportPlainTextRegressionTests {
    @Test("web novel toc titles strip escaped break tags")
    func webNovelTOCTitlesStripEscapedBreakTags() throws {
        let html = """
        <html><body>
          <div id="list">
            <a href="/chapter-1">第1章&lt;br&gt;初遇</a>
            <a href="/chapter-2">第2章&lt;br /&gt;暗潮</a>
            <a href="/chapter-3">第3章<br>归来</a>
          </div>
        </body></html>
        """

        let chapters = WebNovelParser.parseTOC(html: html, pageURL: "https://example.com/book/")

        #expect(chapters.map(\.title) == ["第1章 初遇", "第2章 暗潮", "第3章 归来"])
        #expect(chapters.allSatisfy { !$0.title.localizedCaseInsensitiveContains("<br") })
    }

    @Test("toc extracted chapter content is plain text paragraphs")
    func tocExtractedChapterContentIsPlainTextParagraphs() async {
        let html = """
        <html><body>
          <div class="chapter-content">
            <h1>第1章 1：伦敦孤儿</h1>
            <p>2025-12-10 作者：林曦遇鹿</p>
            <p>第1章 1：伦敦孤儿</p>
            <p>“要是你坚持去那什么霍格沃茨上学的话，那就自己出学杂费吧！孤儿院不可能给你掏一颗子儿！”</p>
            <p>“我知道了，安娜护工。”</p>
            <p>希恩看着安娜护工走进公共休息室，轻轻关上了门。</p>
            <p>走廊里的灯光摇晃了一下，他把那封皱巴巴的录取通知重新塞进口袋，确认羊皮纸上的字迹没有被汗水弄花。</p>
          </div>
        </body></html>
        """

        let extracted = await ChapterFetcher.shared.extractWebContentSinglePage(
            html: html,
            pageURL: "https://example.com/chapter-1"
        )
        let cleaned = ChapterFetcher.shared.cleanChapterContent(extracted)
        let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
            fromPlainText: cleaned,
            excludingLeadingTitle: "第1章 1：伦敦孤儿"
        )

        #expect(!extracted.localizedCaseInsensitiveContains("<p"))
        #expect(!cleaned.localizedCaseInsensitiveContains("<p"))
        #expect(paragraphs.count >= 3)
        #expect(!paragraphs.contains("第1章 1：伦敦孤儿"))
        #expect(paragraphs.contains("“要是你坚持去那什么霍格沃茨上学的话，那就自己出学杂费吧！孤儿院不可能给你掏一颗子儿！”"))
        #expect(paragraphs.contains("“我知道了，安娜护工。”"))
        #expect(paragraphs.contains("希恩看着安娜护工走进公共休息室，轻轻关上了门。"))
        #expect(paragraphs.contains("走廊里的灯光摇晃了一下，他把那封皱巴巴的录取通知重新塞进口袋，确认羊皮纸上的字迹没有被汗水弄花。"))
    }

    @Test("toc body fallback preserves br paragraph breaks")
    func tocBodyFallbackPreservesBRParagraphBreaks() async {
        let html = """
        <html><body>
        <h1>第1章 我和荒古圣体踢足球</h1>
        “上古之人，春秋皆度百岁，而动作不衰。”<br><br>
        看着《黄帝内经》上记载的这句话，秦胜微微一笑。<br><br>
        已知叶天帝看《黄帝内经》，我也看，所以可得：我=叶天帝。<br><br>
        “不，我现在比叶凡要强，毕竟我已经快修完轮海秘境了。”<br><br>
        我已经超了叶天帝！<br><br>
        内视己身，在秦胜脐下，也即人体黄金分割线的位置，苦海已开。<br><br>
        不过他的苦海是漆黑色，死气沉沉。<br><br>
        金色的苦海，浪花滔天、澎湃无比的景象，那是圣体专属。<br><br>
        特效？那不是凡体能奢望的东西。<br><br>
        苦海中心位置，一口生命神泉汩汩而涌，神力如潮，霞光满天。<br><br>
        这是命泉。看向上方，一道璀璨的彩虹高挂，以此岸为起点。
        </body></html>
        """

        let extracted = await ChapterFetcher.shared.extractWebContentSinglePage(
            html: html,
            pageURL: "https://example.com/chapter-1"
        )
        let cleaned = ChapterFetcher.shared.cleanChapterContent(extracted)
        let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
            fromPlainText: cleaned,
            excludingLeadingTitle: "第1章 我和荒古圣体踢足球"
        )

        #expect(!ReaderHTMLUtilities.isLikelyCollapsedChapterText(cleaned))
        #expect(paragraphs.count >= 6)
        #expect(paragraphs.first == "“上古之人，春秋皆度百岁，而动作不衰。”")
        #expect(!paragraphs.contains("第1章 我和荒古圣体踢足球"))
        #expect(paragraphs.contains("看着《黄帝内经》上记载的这句话，秦胜微微一笑。"))
        #expect(paragraphs.contains("我已经超了叶天帝！"))
        #expect(paragraphs.contains("特效？那不是凡体能奢望的东西。"))
        #expect(paragraphs.contains("这是命泉。看向上方，一道璀璨的彩虹高挂，以此岸为起点。"))
    }

    @Test("browser imported collapsed toc cache is rejected")
    func browserImportedCollapsedTOCCacheIsRejected() {
        let paragraphed = """
        “上古之人，春秋皆度百岁，而动作不衰。”
        看着《黄帝内经》上记载的这句话，秦胜微微一笑。
        已知叶天帝看《黄帝内经》，我也看，所以可得：我=叶天帝。
        “不，我现在比叶凡要强，毕竟我已经快修完轮海秘境了。”
        我已经超了叶天帝！
        内视己身，在秦胜脐下，也即人体黄金分割线的位置，苦海已开。
        不过他的苦海是漆黑色，死气沉沉。
        金色的苦海，浪花滔天、澎湃无比的景象，那是圣体专属，如秦胜这样的凡体，苦海基本都是乌漆嘛黑的。
        特效？那不是凡体能奢望的东西。
        苦海中心位置，一口生命神泉汩汩而涌，神力如潮，霞光满天。
        """
        let collapsed = paragraphed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        #expect(ReaderHTMLUtilities.isLikelyCollapsedChapterText(collapsed))
        #expect(!ReaderHTMLUtilities.isLikelyCollapsedChapterText(paragraphed))
        #expect(ChapterFetchManager.isCollapsedBrowserImportedChapterContent(collapsed))
        #expect(!ChapterFetchManager.isCollapsedBrowserImportedChapterContent(paragraphed))
    }

    @Test("single chapter html import keeps txt paragraph shape")
    func singleChapterHTMLImportKeepsTXTParagraphShape() {
        let html = """
        <h1>第1章 1：伦敦孤儿</h1>
        <p>2025-12-10 作者：林曦遇鹿</p>
        <p>第1章 1：伦敦孤儿</p>
        <p>“要是你坚持去那什么霍格沃茨上学的话，那就自己出学杂费吧！孤儿院不可能给你掏一颗子儿！”</p>
        <p>“我知道了，安娜护工。”</p>
        <p>希恩看着安娜护工走进公共休息室，轻轻关上了门。</p>
        <p>走廊里的灯光摇晃了一下，他把那封皱巴巴的录取通知重新塞进口袋，确认羊皮纸上的字迹没有被汗水弄花。</p>
        """

        let paragraphs = TXTChapterParser.paragraphsForChapterContent(html)

        #expect(paragraphs.count == 7)
        #expect(paragraphs.first == "第1章 1：伦敦孤儿")
        #expect(!paragraphs.joined(separator: "\n").contains("<"))
    }
}

// MARK: - 3. BookSource Model Tests

@Suite("BookSource Model Compatibility", .serialized)
struct BookSourceModelTests {

    @Test("BookSource properties accessible after creation")
    func bookSourceProperties() {
        let source = makeSource(
            url: "https://test.com",
            name: "回歸書源",
            searchBookList: "div.result",
            searchName: "a.title@text"
        )

        #expect(source.bookSourceUrl == "https://test.com")
        #expect(source.bookSourceName == "回歸書源")
        #expect(source.ruleSearch.bookList == "div.result")
        #expect(source.ruleSearch.name == "a.title@text")
    }

    @Test("BookSourceRuleData wraps correctly")
    func ruleDataWrapping() {
        let source = makeSource(url: "https://wrap.com", name: "包裝測試")
        let ruleData = BookSourceRuleData(source: source)

        #expect(ruleData.source.bookSourceUrl == "https://wrap.com")
        #expect(ruleData.source.bookSourceName == "包裝測試")
    }

    @Test("Variable storage round-trip via RuleDataInterface")
    func variableRoundTrip() {
        let source = makeSource()
        let ruleData = BookSourceRuleData(source: source)

        ruleData.putVariable(key: "testKey", value: "testValue")
        let retrieved = ruleData.getVariable(key: "testKey")
        #expect(retrieved == "testValue")
    }

    @Test("Variable removal returns empty string")
    func variableRemoval() {
        let source = makeSource()
        let ruleData = BookSourceRuleData(source: source)

        ruleData.putVariable(key: "temp", value: "data")
        ruleData.putVariable(key: "temp", value: nil)
        let retrieved = ruleData.getVariable(key: "temp")
        #expect(retrieved == "")
    }

    @Test("Multiple variables coexist")
    func multipleVariables() {
        let source = makeSource()
        let ruleData = BookSourceRuleData(source: source)

        ruleData.putVariable(key: "a", value: "alpha")
        ruleData.putVariable(key: "b", value: "beta")
        #expect(ruleData.getVariable(key: "a") == "alpha")
        #expect(ruleData.getVariable(key: "b") == "beta")
    }
}

// MARK: - 5. Edge Case Tests

@Suite("Regression Edge Cases", .serialized)
struct RegressionEdgeCaseTests {

    @Test("Empty content returns empty for both parsers")
    func emptyContent() throws {
        let baseURL = "https://example.com"
        let rule = "@css:div.title@text"

        let legacy = RuleEngine.routeExtractValue(content: "", baseURL: baseURL, rule: rule)
        // Modern may throw or return empty — both are acceptable
        let modern = (try? ModernRuleEngine().extractValue(from: "", rule: rule, baseURL: baseURL)) ?? ""

        #expect(legacy.isEmpty)
        #expect(modern.isEmpty)
    }

    @Test("Empty rule returns empty for both parsers")
    func emptyRule() throws {
        let html = "<p>Hello</p>"
        let baseURL = "https://example.com"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: "")
        let modern = (try? ModernRuleEngine().extractValue(from: html, rule: "", baseURL: baseURL)) ?? ""

        #expect(legacy.isEmpty)
        #expect(modern.isEmpty)
    }

    @Test("Very long content does not crash either parser")
    func longContent() throws {
        let repeated = String(repeating: "<p>段落</p>", count: 5000)
        let html = "<html><body>\(repeated)</body></html>"
        let baseURL = "https://example.com"
        let rule = "@css:p@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = (try? ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)) ?? ""

        #expect(!legacy.isEmpty)
        #expect(!modern.isEmpty)
    }

    @Test("Rule with only whitespace treated as empty")
    func whitespaceOnlyRule() throws {
        let html = "<p>text</p>"
        let baseURL = "https://example.com"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: "   ")
        let modern = (try? ModernRuleEngine().extractValue(from: html, rule: "   ", baseURL: baseURL)) ?? ""

        #expect(legacy.isEmpty)
        #expect(modern.isEmpty)
    }

    @Test("Special characters in HTML don't break extraction")
    func specialCharacters() throws {
        let html = """
        <html><body>
            <div class='title'>書名 &amp; 作者 &lt;特殊&gt;</div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:div.title@text"

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(normalise(modern) == normalise(legacy))
    }
}

// MARK: - 6. RuleEngine Static API Compatibility

@Suite("RuleEngine Static API", .serialized)
struct RuleEngineAPITests {

    @Test("splitRuleByOperators handles || correctly")
    func splitByOrOperator() {
        let (op, parts) = RuleEngine.splitRuleByOperators("rule1||rule2||rule3")
        #expect(op == "||")
        #expect(parts.count == 3)
    }

    @Test("splitRuleByOperators handles && correctly")
    func splitByAndOperator() {
        let (op, parts) = RuleEngine.splitRuleByOperators("a&&b")
        #expect(op == "&&")
        #expect(parts.count == 2)
    }

    @Test("splitRuleByOperators handles %% correctly")
    func splitByPercentOperator() {
        let (op, parts) = RuleEngine.splitRuleByOperators("x%%y%%z")
        #expect(op == "%%")
        #expect(parts.count == 3)
    }

    @Test("splitRuleByOperators returns single part for no operators")
    func noOperator() {
        let (op, parts) = RuleEngine.splitRuleByOperators("div.title@text")
        #expect(op == "")
        #expect(parts.count == 1)
        #expect(parts[0] == "div.title@text")
    }

    @Test("bracketAwareSplit does not split inside brackets")
    func bracketAware() {
        let result = RuleEngine.bracketAwareSplit(
            "a[b||c]||d", separator: "||"
        )
        #expect(result.count == 2)
        #expect(result[0] == "a[b||c]")
        #expect(result[1] == "d")
    }

    @Test("isJsoupDefaultRule detects class.name pattern")
    func jsoupDetection() {
        #expect(RuleEngine.isJsoupDefaultRule("class.bookname@tag.h1@text") == true)
        #expect(RuleEngine.isJsoupDefaultRule("@css:div.title@text") == false)
    }
}

// MARK: - 7. RegexSanitizer — Java → ICU Pattern Conversion

@Suite("RegexSanitizer Java→ICU", .serialized)
struct RegexSanitizerTests {

    // MARK: Possessive quantifiers

    @Test("strips possessive ++ quantifier")
    func possessiveGreedyPlus() {
        let sanitized = RegexSanitizer.sanitize(#"\d++"#)
        #expect(sanitized == #"\d+"#)
        #expect(RegexSanitizer.canCompile(#"\d++"#))
    }

    @Test("strips possessive *+ quantifier")
    func possessiveGreedyStar() {
        let sanitized = RegexSanitizer.sanitize(#"\w*+"#)
        #expect(sanitized == #"\w*"#)
        #expect(RegexSanitizer.canCompile(#"\w*+"#))
    }

    @Test("strips possessive ?+ quantifier")
    func possessiveGreedyQuestion() {
        let sanitized = RegexSanitizer.sanitize(#"\s?+"#)
        #expect(sanitized == #"\s?"#)
        #expect(RegexSanitizer.canCompile(#"\s?+"#))
    }

    // MARK: Atomic groups

    @Test("converts atomic group to non-capturing group")
    func atomicGroup() {
        let sanitized = RegexSanitizer.sanitize("(?>abc)")
        #expect(sanitized == "(?:abc)")
        #expect(RegexSanitizer.canCompile("(?>abc)"))
    }

    // MARK: \R line break

    @Test("expands \\R to line-break alternative")
    func lineBreakR() {
        let sanitized = RegexSanitizer.sanitize(#"\R"#)
        #expect(sanitized.contains("\\r\\n"))
        #expect(RegexSanitizer.canCompile(#"\R"#))
    }

    // MARK: \e escape char

    @Test("converts \\e to \\x1B")
    func escapeChar() {
        let sanitized = RegexSanitizer.sanitize(#"\e"#)
        #expect(sanitized == #"\x1B"#)
        #expect(RegexSanitizer.canCompile(#"\e"#))
    }

    // MARK: Java Unicode categories

    @Test("converts \\p{javaLetterOrDigit} to \\w")
    func javaLetterOrDigit() {
        let sanitized = RegexSanitizer.sanitize(#"\p{javaLetterOrDigit}+"#)
        #expect(sanitized.contains("\\w"))
        #expect(RegexSanitizer.canCompile(#"\p{javaLetterOrDigit}+"#))
    }

    // MARK: Passthrough (no Java syntax)

    @Test("leaves ordinary pattern unchanged")
    func ordinaryPattern() {
        let plain = #"(\d{4})-(\d{2})-(\d{2})"#
        #expect(RegexSanitizer.sanitize(plain) == plain)
    }

    @Test("plain pattern still compiles")
    func ordinaryPatternCompiles() {
        #expect(RegexSanitizer.canCompile(#"[a-z]+"#))
    }

    // MARK: End-to-end replacement through RegexReplacer

    @Test("replaceRegex survives possessive quantifier from Java book source")
    func replaceRegexWithPossessive() {
        // Pattern a book source might write on Android using possessive quantifier
        let input = "第001章 故事開始"
        let result = RegexReplacer.replaceRegex(
            result: input,
            pattern: #"第\d++章"#,   // possessive ++ — illegal in ICU
            replacement: "",
            replaceFirst: false
        )
        #expect(result == " 故事開始")
    }

    @Test("replaceRegex returns original on catastrophic backtracking pattern within timeout")
    func catastrophicBacktrackingSafeguard() {
        // Classic catastrophic backtracking pattern — nested quantifiers on large input
        let input = String(repeating: "a", count: 30) + "!"
        let result = RegexReplacer.replaceRegex(
            result: input,
            pattern: "(a+)+b",   // catastrophic on non-matching input
            replacement: "X",
            replaceFirst: false,
            timeout: 0.5
        )
        // Expect original returned within timeout (not a hang)
        #expect(result == input)
    }
}
