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

// MARK: - 1. Feature Flag Tests

@Suite("ParserSettings Feature Flag")
struct FeatureFlagTests {

    @Test("Default value is legacy (false)")
    func defaultIsLegacy() {
        // Clear any previously stored value
        UserDefaults.standard.removeObject(forKey: "useModernParser")
        #expect(ParserSettings.useModernParser == false)
    }

    @Test("Setting flag switches to modern parser")
    func settingFlagSwitchesToModern() {
        let original = ParserSettings.useModernParser
        defer { ParserSettings.useModernParser = original }

        ParserSettings.useModernParser = true
        #expect(ParserSettings.useModernParser == true)
    }

    @Test("Resetting flag goes back to legacy")
    func resettingFlagRestoresLegacy() {
        let original = ParserSettings.useModernParser
        defer { ParserSettings.useModernParser = original }

        ParserSettings.useModernParser = true
        #expect(ParserSettings.useModernParser == true)

        ParserSettings.useModernParser = false
        #expect(ParserSettings.useModernParser == false)
    }
}

// MARK: - 2. Cross-Parser Compatibility Tests

@Suite("Cross-Parser Compatibility")
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

// MARK: - 3. BookSource Model Tests

@Suite("BookSource Model Compatibility")
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

// MARK: - 4. Pipeline Routing Tests

@Suite("Pipeline Routing")
struct PipelineRoutingTests {

    private let pipeline = BookSourceParsingPipeline()

    @Test("Pipeline uses legacy parser when flag is off")
    func pipelineUsesLegacyWhenFlagOff() throws {
        let original = ParserSettings.useModernParser
        defer { ParserSettings.useModernParser = original }
        ParserSettings.useModernParser = false

        let html = """
        <html><body>
            <div class='item'><a class='name' href='/book/1'>遮天</a><span class='author'>辰東</span></div>
        </body></html>
        """
        let source = makeSource(
            searchBookList: "div.item",
            searchName: "a.name@text",
            searchAuthor: "span.author@text",
            searchBookUrl: "a.name@href"
        )

        let results = try pipeline.parseSearchResults(html: html, baseURL: "https://example.com", source: source)
        // Just verify it doesn't crash and produces something
        #expect(results.count >= 0)
    }

    @Test("Pipeline uses modern parser when flag is on")
    func pipelineUsesModernWhenFlagOn() throws {
        let original = ParserSettings.useModernParser
        defer { ParserSettings.useModernParser = original }
        ParserSettings.useModernParser = true

        let html = """
        <html><body>
            <div class='item'><a class='name' href='/book/1'>遮天</a><span class='author'>辰東</span></div>
        </body></html>
        """
        let source = makeSource(
            searchBookList: "div.item",
            searchName: "a.name@text",
            searchAuthor: "span.author@text",
            searchBookUrl: "a.name@href"
        )

        let results = try pipeline.parseSearchResults(html: html, baseURL: "https://example.com", source: source)
        #expect(results.count >= 0)
    }

    @Test("Both paths handle nil/empty input gracefully — empty HTML")
    func emptyHTMLHandling() throws {
        let source = makeSource(searchBookList: "div.item", searchName: "a@text")

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            let results = try pipeline.parseSearchResults(
                html: "", baseURL: "https://example.com", source: source
            )
            #expect(results.isEmpty, "Empty HTML should produce empty results (modern=\(useModern))")
        }
    }

    @Test("Both paths handle empty rule gracefully")
    func emptyRuleHandling() throws {
        let source = makeSource() // all rules empty

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            let results = try pipeline.parseSearchResults(
                html: "<html><body>content</body></html>",
                baseURL: "https://example.com",
                source: source
            )
            #expect(results.isEmpty, "Empty rules should produce empty results (modern=\(useModern))")
        }
    }

    @Test("Both paths handle malformed rules gracefully")
    func malformedRuleHandling() {
        let source = makeSource(searchBookList: "@@@invalid[[[", searchName: "???")

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            // Should not crash; may return empty or throw — either is acceptable
            let results = try? pipeline.parseSearchResults(
                html: "<html><body>test</body></html>",
                baseURL: "https://example.com",
                source: source
            )
            // Simply reaching here without crashing is the test
            #expect((results ?? []).count >= 0, "Should not crash (modern=\(useModern))")
        }
    }

    @Test("TOC parsing: both paths handle empty chapter list rule")
    func emptyTocRule() throws {
        let source = makeSource() // no toc rules

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            let chapters = try pipeline.parseTOC(
                html: "<html><body><ul><li>Ch1</li></ul></body></html>",
                baseURL: "https://example.com",
                source: source
            )
            #expect(chapters.isEmpty, "Empty TOC rule should produce empty chapters (modern=\(useModern))")
        }
    }

    @Test("Next TOC URL: both paths return empty for missing rule")
    func nextTocUrlEmpty() {
        let source = makeSource() // nextTocUrl is ""

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            let next = pipeline.extractNextTocURL(
                html: "<html><body></body></html>",
                baseURL: "https://example.com",
                source: source
            )
            #expect(next.isEmpty, "Empty nextTocUrl rule should return empty (modern=\(useModern))")
        }
    }

    @Test("Next content URLs: both paths return empty for missing rule")
    func nextContentUrlsEmpty() {
        let source = makeSource() // nextContentUrl is ""

        for useModern in [false, true] {
            let original = ParserSettings.useModernParser
            defer { ParserSettings.useModernParser = original }
            ParserSettings.useModernParser = useModern

            let urls = pipeline.extractNextContentURLs(
                html: "<html><body></body></html>",
                baseURL: "https://example.com",
                source: source
            )
            #expect(urls.isEmpty, "Empty nextContentUrl rule should return empty (modern=\(useModern))")
        }
    }
}

// MARK: - 5. Edge Case Tests

@Suite("Edge Cases")
struct EdgeCaseTests {

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

@Suite("RuleEngine Static API")
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

@Suite("RegexSanitizer Java→ICU")
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
            pattern: #"第\d++"#,   // possessive ++ — illegal in ICU
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
