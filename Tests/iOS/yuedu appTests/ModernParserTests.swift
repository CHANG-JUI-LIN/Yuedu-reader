import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

// MARK: - 1. RuleAnalyzer Tests

@Suite("RuleAnalyzer", .serialized)
struct RuleAnalyzerTests {

    @Test("splitRule with || operator separates segments")
    func splitByOr() {
        let analyzer = RuleAnalyzer(data: "a||b||c")
        let result = analyzer.splitRule("||")
        #expect(result == ["a", "b", "c"])
        #expect(analyzer.elementsType == "||")
    }

    @Test("splitRule with && operator separates segments")
    func splitByAnd() {
        let analyzer = RuleAnalyzer(data: "x&&y&&z")
        let result = analyzer.splitRule("&&")
        #expect(result == ["x", "y", "z"])
        #expect(analyzer.elementsType == "&&")
    }

    @Test("splitRule with %% operator separates segments")
    func splitByPercent() {
        let analyzer = RuleAnalyzer(data: "p%%q%%r")
        let result = analyzer.splitRule("%%")
        #expect(result == ["p", "q", "r"])
        #expect(analyzer.elementsType == "%%")
    }

    @Test("splitRule with no operator returns entire string")
    func splitNoOperator() {
        let analyzer = RuleAnalyzer(data: "singleRule")
        let result = analyzer.splitRule("||")
        #expect(result == ["singleRule"])
    }

    @Test("splitRule preserves content inside square brackets")
    func splitWithBrackets() {
        let analyzer = RuleAnalyzer(data: "a[b||c]||d")
        let result = analyzer.splitRule("||")
        #expect(result == ["a[b||c]", "d"])
    }

    @Test("splitRule preserves content inside parentheses")
    func splitWithParentheses() {
        let analyzer = RuleAnalyzer(data: "a(b||c)||d")
        let result = analyzer.splitRule("||")
        #expect(result == ["a(b||c)", "d"])
    }

    @Test("splitRule preserves single-quoted strings")
    func splitWithSingleQuotes() {
        let analyzer = RuleAnalyzer(data: "a'b||c'||d", code: true)
        let result = analyzer.splitRule("||")
        #expect(result == ["a'b||c'", "d"])
    }

    @Test("splitRule preserves double-quoted strings")
    func splitWithDoubleQuotes() {
        let analyzer = RuleAnalyzer(data: "a\"b||c\"||d", code: true)
        let result = analyzer.splitRule("||")
        #expect(result == ["a\"b||c\"", "d"])
    }

    @Test("splitRule with multiple operator candidates picks first match")
    func splitMultipleOperators() {
        let analyzer = RuleAnalyzer(data: "a||b&&c")
        let result = analyzer.splitRule("||", "&&")
        #expect(result == ["a", "b&&c"])
        #expect(analyzer.elementsType == "||")
    }

    @Test("splitRule with && before || picks &&")
    func splitMultipleOperatorsAndFirst() {
        let analyzer = RuleAnalyzer(data: "a&&b||c")
        let result = analyzer.splitRule("||", "&&")
        #expect(result == ["a", "b||c"])
        #expect(analyzer.elementsType == "&&")
    }

    @Test("splitRule empty input returns single empty string")
    func splitEmptyInput() {
        let analyzer = RuleAnalyzer(data: "")
        let result = analyzer.splitRule("||")
        #expect(result == [""])
    }

    @Test("trim removes leading @ and whitespace")
    func trimLeadingAt() {
        let analyzer = RuleAnalyzer(data: "@@ css:div")
        analyzer.trim()
        let result = analyzer.splitRule("||")
        #expect(result == ["css:div"])
    }

    @Test("trim handles no leading @ or whitespace")
    func trimNoChange() {
        let analyzer = RuleAnalyzer(data: "hello")
        analyzer.trim()
        let result = analyzer.splitRule("||")
        #expect(result == ["hello"])
    }

    @Test("innerRule replaces {{...}} templates")
    func innerRuleDoubleBrace() {
        let analyzer = RuleAnalyzer(data: "prefix{{expr}}suffix", code: true)
        let result = analyzer.innerRule(inner: "{{", startStep: 2, endStep: 2) { expr in
            return "REPLACED"
        }
        #expect(result == "prefixREPLACEDsuffix")
    }

    @Test("innerRule replaces @get:{key} references")
    func innerRuleGetRef() {
        let analyzer = RuleAnalyzer(data: "url/@get:{token}/path", code: true)
        let result = analyzer.innerRule(startStr: "@get:{", endStr: "}") { key in
            return key == "token" ? "abc123" : nil
        }
        #expect(result == "url/abc123/path")
    }

    @Test("innerRule with no matches returns empty for brace variant")
    func innerRuleNoMatch() {
        let analyzer = RuleAnalyzer(data: "no templates here", code: true)
        let result = analyzer.innerRule(inner: "{{", startStep: 2, endStep: 2) { _ in "X" }
        #expect(result == "")
    }

    @Test("innerRule startStr/endStr with no matches returns original")
    func innerRuleStartEndNoMatch() {
        let analyzer = RuleAnalyzer(data: "nothing to replace", code: true)
        let result = analyzer.innerRule(startStr: "@get:{", endStr: "}") { _ in "Y" }
        #expect(result == "nothing to replace")
    }

    @Test("code mode handles escaped characters in brackets")
    func codeModeEscaped() {
        let analyzer = RuleAnalyzer(data: "a{b\\}c}||d", code: true)
        let result = analyzer.splitRule("||")
        #expect(result.count == 2)
        #expect(result[1] == "d")
    }

    @Test("splitRule with deeply nested brackets")
    func splitDeepNesting() {
        let analyzer = RuleAnalyzer(data: "a[b[c||d]]||e")
        let result = analyzer.splitRule("||")
        #expect(result == ["a[b[c||d]]", "e"])
    }

    @Test("reSetPos allows re-scanning from beginning")
    func reSetPosWorks() {
        let analyzer = RuleAnalyzer(data: "a||b")
        let first = analyzer.splitRule("||")
        #expect(first == ["a", "b"])
        analyzer.reSetPos()
        let second = analyzer.splitRule("&&")
        #expect(second == ["a||b"])
    }
}

@Suite("ModernParserBridge Chapter Compatibility", .serialized)
struct ModernParserBridgeChapterCompatibilityTests {
    @Test("chapter JS receives the original response as src")
    func chapterJSReceivesOriginalResponseAsSrc() throws {
        var source = BookSource()
        source.bookSourceUrl = "xiaomi-src-\(UUID().uuidString)"
        source.ruleContent.content = """
        $..contentList[*]
        <js>
        if(result.match(/^http.+$/)){
            src = java.base64Decode(String(java.ajax(result)).match(/\\('([^']+)'\\)/)[1]);
        }
        src
        </js>
        $..p[*]||$..contentList[*]
        """

        let payload = try ModernParserBridge(source: source).parseChapterResult(
            html: #"{"status":0,"data":{"contentList":["paragraph one","paragraph two"]}}"#,
            baseURL: "https://reader.browser.miui.com/api/v2/chapter/content?chapterId=1",
            source: source
        )

        #expect(payload.content == "paragraph one\nparagraph two")
    }
}

// MARK: - 2. SourceRule Tests

@Suite("SourceRule", .serialized)
struct SourceRuleTests {

    @Test("@CSS: prefix sets default mode")
    func cssPrefixMode() {
        let rule = SourceRule(ruleStr: "@CSS:div.title@text")
        #expect(rule.mode == .default)
        #expect(rule.rule.hasPrefix("div.title"))
    }

    @Test("@XPath: prefix sets xpath mode")
    func xpathPrefixMode() {
        let rule = SourceRule(ruleStr: "@XPath://div[@id='content']")
        #expect(rule.mode == .xpath)
        #expect(rule.rule.contains("div"))
    }

    @Test("@Json: prefix sets json mode")
    func jsonPrefixMode() {
        let rule = SourceRule(ruleStr: "@Json:$.data.list")
        #expect(rule.mode == .json)
        #expect(rule.rule == "$.data.list")
    }

    @Test("@js: prefix sets js mode")
    func jsPrefixMode() {
        let rule = SourceRule(ruleStr: "@js:result + 'suffix'")
        #expect(rule.mode == .js)
        #expect(rule.rule.contains("result"))
    }

    @Test("<js>...</js> sets js mode and strips tags")
    func jsTagMode() {
        let rule = SourceRule(ruleStr: "<js>var x = 1;</js>")
        #expect(rule.mode == .js)
        #expect(rule.rule == "var x = 1;")
    }

    @Test("$. prefix auto-detects json mode")
    func jsonAutoDetectDollarDot() {
        let rule = SourceRule(ruleStr: "$.store.book")
        #expect(rule.mode == .json)
        #expect(rule.rule == "$.store.book")
    }

    @Test("$[ prefix auto-detects json mode")
    func jsonAutoDetectDollarBracket() {
        let rule = SourceRule(ruleStr: "$[0].title")
        #expect(rule.mode == .json)
    }

    @Test("// prefix auto-detects xpath mode")
    func xpathAutoDetectSlash() {
        let rule = SourceRule(ruleStr: "//div[@class='item']")
        #expect(rule.mode == .xpath)
    }

    @Test("@@ prefix sets default mode")
    func doubleAtPrefix() {
        let rule = SourceRule(ruleStr: "@@div.title@text")
        #expect(rule.mode == .default)
        #expect(rule.rule == "div.title@text")
    }

    @Test("@put:{key:value} is extracted into putMap")
    func putDirectiveExtracted() {
        let rule = SourceRule(ruleStr: "@css:div.title@text@put:{\"myKey\":\"myVal\"}")
        #expect(rule.putMap["myKey"] == "myVal")
        #expect(!rule.rule.contains("@put:"))
    }

    @Test("@get:{key} is parsed as template parameter")
    func getTemplateParameter() {
        let rule = SourceRule(ruleStr: "@get:{token}")
        #expect(rule.mode == .regex)
        #expect(rule.paramSize > 0)
    }

    @Test("{{expression}} is parsed as template parameter")
    func doubleBraceTemplate() {
        let rule = SourceRule(ruleStr: "prefix{{page}}suffix")
        #expect(rule.paramSize > 0)
    }

    @Test("$N regex group references are parsed")
    func dollarNGroupRef() {
        let rule = SourceRule(ruleStr: "prefix$1middle$2end")
        #expect(rule.mode == .regex)
        #expect(rule.paramSize > 0)
    }

    @Test("makeUpRule splits ## into regex replacement")
    func makeUpRuleSplitsRegex() {
        let rule = SourceRule(ruleStr: "div.title@text##pattern##replacement")
        rule.makeUpRule(
            result: nil,
            getData: { _ in "" },
            evalJS: { _ in nil },
            analyzeRule: { _ in nil }
        )
        #expect(rule.replaceRegex == "pattern")
        #expect(rule.replacement == "replacement")
        #expect(rule.replaceFirst == false)
    }

    @Test("makeUpRule ### sets replaceFirst flag")
    func makeUpRuleReplaceFirst() {
        let rule = SourceRule(ruleStr: "rule##pat##rep###")
        rule.makeUpRule(
            result: nil,
            getData: { _ in "" },
            evalJS: { _ in nil },
            analyzeRule: { _ in nil }
        )
        #expect(rule.replaceRegex == "pat")
        #expect(rule.replacement == "rep")
        #expect(rule.replaceFirst == true)
    }

    @Test("makeUpRule resolves @get:{key} templates")
    func makeUpRuleResolvesGet() {
        let rule = SourceRule(ruleStr: "url/@get:{host}/path")
        rule.makeUpRule(
            result: nil,
            getData: { key in key == "host" ? "example.com" : "" },
            evalJS: { _ in nil },
            analyzeRule: { _ in nil }
        )
        #expect(rule.rule == "url/example.com/path")
    }

    @Test("isJSON parameter forces json mode")
    func isJSONForces() {
        let rule = SourceRule(ruleStr: "data.list", mainMode: .default, isJSON: true)
        #expect(rule.mode == .json)
    }
}

// MARK: - 3. RegexExtractor Tests

@Suite("RegexExtractor", .serialized)
struct RegexExtractorTests {

    private let extractor = RegexExtractor()

    @Test("canHandle returns true for ## prefix")
    func canHandlePrefix() {
        #expect(extractor.canHandle(rule: "##\\d+"))
        #expect(!extractor.canHandle(rule: "some rule"))
    }

    @Test("extractValue returns first capture group")
    func extractValueCaptureGroup() throws {
        let result = try extractor.extractValue(
            from: "Hello World 2024",
            rule: "##(\\d+)",
            baseURL: ""
        )
        #expect(result == "2024")
    }

    @Test("extractValue returns full match when no capture groups")
    func extractValueFullMatch() throws {
        let result = try extractor.extractValue(
            from: "abc123def",
            rule: "##\\d+",
            baseURL: ""
        )
        #expect(result == "123")
    }

    @Test("extractValue returns empty when no match")
    func extractValueNoMatch() throws {
        let result = try extractor.extractValue(
            from: "hello world",
            rule: "##\\d+",
            baseURL: ""
        )
        #expect(result == "")
    }

    @Test("extractList returns all capture groups")
    func extractListCaptureGroups() throws {
        let result = try extractor.extractList(
            from: "a1b2c3",
            rule: "##([a-z])(\\d)",
            baseURL: ""
        )
        #expect(result == ["a", "1", "b", "2", "c", "3"])
    }

    @Test("extractList returns all full matches when no groups")
    func extractListFullMatches() throws {
        let result = try extractor.extractList(
            from: "12-34-56",
            rule: "##\\d+",
            baseURL: ""
        )
        #expect(result == ["12", "34", "56"])
    }

    @Test("extractValue with empty pattern returns content")
    func extractValueEmptyPattern() throws {
        let result = try extractor.extractValue(from: "text", rule: "##", baseURL: "")
        #expect(result == "text")
    }

    @Test("RegexReplacer replaces all matches")
    func replacerReplaceAll() {
        let result = RegexReplacer.replaceRegex(
            result: "abc123def456",
            pattern: "\\d+",
            replacement: "NUM",
            replaceFirst: false
        )
        #expect(result == "abcNUMdefNUM")
    }

    @Test("RegexReplacer replaces first match only")
    func replacerReplaceFirst() {
        let result = RegexReplacer.replaceRegex(
            result: "abc123def456",
            pattern: "\\d+",
            replacement: "NUM",
            replaceFirst: true
        )
        #expect(result == "abcNUMdef456")
    }

    @Test("RegexReplacer supports group references $1 $2")
    func replacerGroupRefs() {
        let result = RegexReplacer.replaceRegex(
            result: "2024-01-15",
            pattern: "(\\d{4})-(\\d{2})-(\\d{2})",
            replacement: "$2/$3/$1",
            replaceFirst: false
        )
        #expect(result == "01/15/2024")
    }

    @Test("RegexReplacer with empty pattern returns original")
    func replacerEmptyPattern() {
        let result = RegexReplacer.replaceRegex(
            result: "hello",
            pattern: "",
            replacement: "x",
            replaceFirst: false
        )
        #expect(result == "hello")
    }

    @Test("RegexReplacer with invalid pattern returns original")
    func replacerInvalidPattern() {
        let result = RegexReplacer.replaceRegex(
            result: "hello",
            pattern: "[invalid",
            replacement: "x",
            replaceFirst: false
        )
        #expect(result == "hello")
    }
}

// MARK: - 4. JSONPath / JsonExtractor Tests

@Suite("JSONPathEvaluator", .serialized)
struct JSONPathEvaluatorTests {

    private let storeJSON: [String: Any] = [
        "store": [
            "book": [
                ["title": "A", "author": "Alice", "price": 8.95],
                ["title": "B", "author": "Bob", "price": 12.99],
                ["title": "C", "author": "Carol", "price": 5.50],
                ["title": "D", "author": "Dave", "price": 22.00]
            ] as [[String: Any]],
            "name": "MyStore"
        ] as [String: Any]
    ]

    @Test("dot notation: $.store.name")
    func dotNotation() {
        let results = JSONPathEvaluator.query("$.store.name", on: storeJSON)
        #expect(results.count == 1)
        #expect(results[0] as? String == "MyStore")
    }

    @Test("bracket notation: $['store']['name']")
    func bracketNotation() {
        let results = JSONPathEvaluator.query("$['store']['name']", on: storeJSON)
        #expect(results.count == 1)
        #expect(results[0] as? String == "MyStore")
    }

    @Test("array index: $.store.book[0].title")
    func arrayIndex() {
        let results = JSONPathEvaluator.query("$.store.book[0].title", on: storeJSON)
        #expect(results.count == 1)
        #expect(results[0] as? String == "A")
    }

    @Test("negative array index: $.store.book[-1].title")
    func negativeIndex() {
        let results = JSONPathEvaluator.query("$.store.book[-1].title", on: storeJSON)
        #expect(results.count == 1)
        #expect(results[0] as? String == "D")
    }

    @Test("wildcard: $.store.book[*].title")
    func wildcardArray() {
        let results = JSONPathEvaluator.query("$.store.book[*].title", on: storeJSON)
        let titles = results.compactMap { $0 as? String }
        #expect(titles == ["A", "B", "C", "D"])
    }

    @Test("deep scan: $..author")
    func deepScan() {
        let results = JSONPathEvaluator.query("$..author", on: storeJSON)
        let authors = results.compactMap { $0 as? String }
        #expect(authors.count == 4)
        #expect(authors.contains("Alice"))
        #expect(authors.contains("Dave"))
    }

    @Test("array slicing: $.store.book[0:2]")
    func arraySlice() {
        let results = JSONPathEvaluator.query("$.store.book[0:2]", on: storeJSON)
        #expect(results.count == 2)
    }

    @Test("array slicing with step: $.store.book[0:4:2]")
    func arraySliceWithStep() {
        let results = JSONPathEvaluator.query("$.store.book[0:4:2]", on: storeJSON)
        #expect(results.count == 2)
        if let first = results[0] as? [String: Any] {
            #expect(first["title"] as? String == "A")
        }
    }

    @Test("filter: $.store.book[?(@.price < 10)]")
    func filterLessThan() {
        let results = JSONPathEvaluator.query("$.store.book[?(@.price < 10)]", on: storeJSON)
        #expect(results.count == 2) // A (8.95) and C (5.50)
    }

    @Test("filter: $.store.book[?(@.author == 'Bob')]")
    func filterEquality() {
        let results = JSONPathEvaluator.query("$.store.book[?(@.author == 'Bob')]", on: storeJSON)
        #expect(results.count == 1)
        if let book = results[0] as? [String: Any] {
            #expect(book["title"] as? String == "B")
        }
    }

    @Test("length function: $.store.book.length()")
    func lengthFunction() {
        let results = JSONPathEvaluator.query("$.store.book.length()", on: storeJSON)
        #expect(results.count == 1)
        #expect(results[0] as? Int == 4)
    }

    @Test("multi-index: $.store.book[0,2]")
    func multiIndex() {
        let results = JSONPathEvaluator.query("$.store.book[0,2]", on: storeJSON)
        #expect(results.count == 2)
    }

    @Test("nested path: $.store.book[0].title")
    func nestedPath() {
        let results = JSONPathEvaluator.query("$.store.book[0].title", on: storeJSON)
        #expect(results.first as? String == "A")
    }

    @Test("wildcard on object: $.store.*")
    func wildcardObject() {
        let results = JSONPathEvaluator.query("$.store.*", on: storeJSON)
        #expect(results.count == 2) // book array + name string
    }

    @Test("empty path returns nothing")
    func emptyPath() {
        let results = JSONPathEvaluator.query("", on: storeJSON)
        #expect(results.isEmpty)
    }

    @Test("invalid path returns nothing")
    func invalidPath() {
        let results = JSONPathEvaluator.query("not_a_path", on: storeJSON)
        #expect(results.isEmpty)
    }

    @Test("stringify converts various types to string")
    func stringifyHelper() {
        #expect(JSONPathEvaluator.stringify("hello") == "hello")
        #expect(JSONPathEvaluator.stringify(nil) == "")
        #expect(JSONPathEvaluator.stringify(NSNull()) == "")
    }
}

@Suite("JsonExtractor", .serialized)
struct JsonExtractorTests {

    private let extractor = JsonExtractor()

    private let sampleJSON = """
    {"data":{"list":[{"title":"Book A","author":"Alice"},{"title":"Book B","author":"Bob"}],"count":2}}
    """

    @Test("canHandle recognizes @json: prefix")
    func canHandleJsonPrefix() {
        #expect(extractor.canHandle(rule: "@json:$.data"))
        #expect(extractor.canHandle(rule: "$.data.list"))
        #expect(extractor.canHandle(rule: "$[0].title"))
        #expect(!extractor.canHandle(rule: "div.class@text"))
    }

    @Test("extractValue returns single value")
    func extractSingleValue() throws {
        let result = try extractor.extractValue(from: sampleJSON, rule: "$.data.list[0].title", baseURL: "")
        #expect(result == "Book A")
    }

    @Test("extractValue returns count")
    func extractCount() throws {
        let result = try extractor.extractValue(from: sampleJSON, rule: "$.data.count", baseURL: "")
        #expect(result == "2")
    }

    @Test("extractList returns flat strings")
    func extractListFlat() throws {
        let result = try extractor.extractList(from: sampleJSON, rule: "$.data.list[*].title", baseURL: "")
        #expect(result == ["Book A", "Book B"])
    }

    @Test("extractValue from @json: prefixed rule")
    func extractWithJsonPrefix() throws {
        let result = try extractor.extractValue(from: sampleJSON, rule: "@json:$.data.list[1].author", baseURL: "")
        #expect(result == "Bob")
    }

    @Test("extractValue from @json bare field")
    func extractWithJsonBareField() throws {
        let result = try extractor.extractValue(from: #"{"BookName":"斗罗大陆","AuthorName":"唐家三少"}"#, rule: "@json:BookName", baseURL: "")
        #expect(result == "斗罗大陆")
    }

    @Test("JSON content treats bare field rule as current object property")
    func jsonContentBareFieldRule() {
        let engine = ModernRuleEngine()
        engine.setContent(#"{"BookName":"斗罗大陆","AuthorName":"唐家三少"}"#)

        #expect(engine.getString(ruleStr: "BookName") == "斗罗大陆")
        #expect(engine.getString(ruleStr: "AuthorName") == "唐家三少")
    }

    @Test("extractValue from empty/null JSON returns empty")
    func extractFromEmptyJSON() throws {
        let result = try extractor.extractValue(from: "", rule: "$.data", baseURL: "")
        #expect(result == "")
    }

    @Test("extractList from non-matching path returns empty")
    func extractListNoMatch() throws {
        let result = try extractor.extractList(from: sampleJSON, rule: "$.nonexistent", baseURL: "")
        #expect(result.isEmpty)
    }
}

// MARK: - 5. Cache Tests

@Suite("LRUCache", .serialized)
struct LRUCacheTests {

    @Test("basic put and get")
    func basicPutGet() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        #expect(cache.get("a") == 1)
        #expect(cache.get("b") == 2)
        #expect(cache.get("c") == nil)
    }

    @Test("eviction at capacity")
    func evictionAtCapacity() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.put("c", value: 3) // evicts "a"
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == 2)
        #expect(cache.get("c") == 3)
    }

    @Test("LRU ordering: accessing moves to end")
    func lruOrdering() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        _ = cache.get("a") // access "a", moves it to end
        cache.put("c", value: 3) // evicts "b" (now LRU)
        #expect(cache.get("a") == 1)
        #expect(cache.get("b") == nil)
        #expect(cache.get("c") == 3)
    }

    @Test("update existing key does not increase count")
    func updateExisting() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("a", value: 10)
        #expect(cache.get("a") == 10)
        #expect(cache.count == 1)
    }

    @Test("getOrPut creates and caches on miss")
    func getOrPut() {
        let cache = LRUCache<String, Int>(capacity: 5)
        let val = cache.getOrPut("x") { 42 }
        #expect(val == 42)
        #expect(cache.get("x") == 42)
    }

    @Test("getOrPut returns cached on hit")
    func getOrPutHit() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.put("x", value: 10)
        let val = cache.getOrPut("x") { 999 }
        #expect(val == 10) // factory not called
    }

    @Test("remove specific key")
    func removeKey() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.remove("a")
        #expect(cache.get("a") == nil)
        #expect(cache.count == 1)
    }

    @Test("clear removes all entries")
    func clearAll() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.clear()
        #expect(cache.count == 0)
        #expect(cache.get("a") == nil)
    }

    @Test("thread safety: concurrent reads and writes")
    func threadSafety() {
        let cache = LRUCache<Int, Int>(capacity: 100)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test", attributes: .concurrent)

        for i in 0..<100 {
            group.enter()
            queue.async {
                cache.put(i, value: i * 2)
                _ = cache.get(i)
                group.leave()
            }
        }

        group.wait()
        #expect(cache.count <= 100)
    }

    @Test("unlimited capacity (0) never evicts")
    func unlimitedCapacity() {
        let cache = LRUCache<Int, Int>(capacity: 0)
        for i in 0..<50 {
            cache.put(i, value: i)
        }
        #expect(cache.count == 50)
        #expect(cache.get(0) == 0)
        #expect(cache.get(49) == 49)
    }
}

@Suite("RegexCache", .serialized)
struct RegexCacheTests {

    @Test("compile and retrieve valid pattern")
    func compileAndRetrieve() {
        let cache = RegexCache(capacity: 10)
        let regex = cache.regex(for: "\\d+")
        #expect(regex != nil)
        let same = cache.regex(for: "\\d+")
        #expect(same != nil)
    }

    @Test("different options produce different cache entries")
    func optionsHandling() {
        let cache = RegexCache(capacity: 10)
        let cs = cache.regex(for: "hello")
        let ci = cache.regex(for: "hello", options: .caseInsensitive)
        #expect(cs != nil)
        #expect(ci != nil)
        // Both should work but are separate cache entries
    }

    @Test("invalid pattern returns nil")
    func invalidPattern() {
        let cache = RegexCache(capacity: 10)
        let regex = cache.regex(for: "[invalid")
        #expect(regex == nil)
    }

    @Test("replaceMatches works correctly")
    func replaceMatches() {
        let cache = RegexCache(capacity: 10)
        let result = cache.replaceMatches(in: "a1b2c3", pattern: "\\d", replacement: "X")
        #expect(result == "aXbXcX")
    }

    @Test("firstMatch returns correct result")
    func firstMatchResult() {
        let cache = RegexCache(capacity: 10)
        let match = cache.firstMatch(in: "abc123def", pattern: "\\d+")
        #expect(match != nil)
        let nsStr = "abc123def" as NSString
        #expect(nsStr.substring(with: match!.range) == "123")
    }
}

@Suite("SelectorCache", .serialized)
struct SelectorCacheTests {

    @Test("basic put and get")
    func basicPutGet() {
        let cache = SelectorCache(capacity: 10)
        let step = SelectorCache.JsoupStep(selector: "div.title", indices: nil, accessor: "@text")
        let parsed = SelectorCache.ParsedJsoupRule(steps: [step])

        cache.putParsed("div.title@text", parsed: parsed)
        let retrieved = cache.getParsed("div.title@text")
        #expect(retrieved == parsed)
    }

    @Test("getOrParse invokes parser on miss")
    func getOrParse() {
        let cache = SelectorCache(capacity: 10)
        var parserCalled = false
        let result = cache.getOrParse("test-rule") { _ in
            parserCalled = true
            return SelectorCache.ParsedJsoupRule(steps: [])
        }
        #expect(parserCalled)
        #expect(result.steps.isEmpty)
    }

    @Test("getOrParse returns cached on hit")
    func getOrParseCached() {
        let cache = SelectorCache(capacity: 10)
        let step = SelectorCache.JsoupStep(selector: "p", indices: nil, accessor: nil)
        let parsed = SelectorCache.ParsedJsoupRule(steps: [step])
        cache.putParsed("p", parsed: parsed)

        var parserCalled = false
        let result = cache.getOrParse("p") { _ in
            parserCalled = true
            return SelectorCache.ParsedJsoupRule(steps: [])
        }
        #expect(!parserCalled)
        #expect(result.steps.count == 1)
    }
}

// MARK: - 6. RuleData Tests

@Suite("RuleData", .serialized)
struct RuleDataTests {

    @Test("putVariable and getVariable for small values")
    func putGetSmallValue() {
        let data = RuleData()
        data.putVariable(key: "name", value: "Alice")
        #expect(data.getVariable(key: "name") == "Alice")
    }

    @Test("getVariable returns empty string for missing key")
    func getMissingKey() {
        let data = RuleData()
        #expect(data.getVariable(key: "missing") == "")
    }

    @Test("putVariable with nil removes key")
    func putNilRemoves() {
        let data = RuleData()
        data.putVariable(key: "temp", value: "val")
        #expect(data.getVariable(key: "temp") == "val")
        data.putVariable(key: "temp", value: nil)
        #expect(data.getVariable(key: "temp") == "")
    }

    @Test("putVariable overwrites existing value")
    func overwriteValue() {
        let data = RuleData()
        data.putVariable(key: "k", value: "v1")
        data.putVariable(key: "k", value: "v2")
        #expect(data.getVariable(key: "k") == "v2")
    }

    @Test("big variable (>=10K chars) stored via putBigVariable")
    func bigVariableThreshold() {
        let data = RuleData()
        let bigValue = String(repeating: "x", count: 10_000)
        data.putVariable(key: "big", value: bigValue)
        // RuleData's putBigVariable falls back to variableMap
        #expect(data.getVariable(key: "big") == bigValue)
    }

    @Test("JSON serialization roundtrip")
    func jsonRoundtrip() {
        let data = RuleData()
        data.putVariable(key: "a", value: "1")
        data.putVariable(key: "b", value: "2")

        let json = data.getVariableJSON()
        #expect(json != nil)

        let data2 = RuleData()
        data2.loadVariables(from: json)
        #expect(data2.getVariable(key: "a") == "1")
        #expect(data2.getVariable(key: "b") == "2")
    }

    @Test("loadVariables from nil does nothing")
    func loadNilVariables() {
        let data = RuleData()
        data.putVariable(key: "x", value: "y")
        data.loadVariables(from: nil)
        // variableMap is replaced if load succeeds, but nil load should be no-op
        #expect(data.getVariable(key: "x") == "y")
    }

    @Test("loadVariables from invalid JSON does nothing")
    func loadInvalidJSON() {
        let data = RuleData()
        data.putVariable(key: "x", value: "y")
        data.loadVariables(from: "not json")
        #expect(data.getVariable(key: "x") == "y")
    }

    @Test("multiple variables coexist")
    func multipleVariables() {
        let data = RuleData()
        data.putVariable(key: "a", value: "1")
        data.putVariable(key: "b", value: "2")
        data.putVariable(key: "c", value: "3")
        #expect(data.getVariable(key: "a") == "1")
        #expect(data.getVariable(key: "b") == "2")
        #expect(data.getVariable(key: "c") == "3")
    }
}

// MARK: - BookSource Runtime Routing

@Suite("BookSource runtime routing", .serialized)
struct BookSourceRuntimeRoutingTests {

    @Test("jsLib-backed template variables use Legado runtime")
    func jsLibBackedTemplateVariablesUseRuntime() {
        var source = BookSource()
        source.jsLib = """
        const CONFIG = { api: { baseUrl: 'https://api.example.com' } };
        const qt = 'https://qt.example.com';
        function zdym() { return 'https://domain.example.com'; }
        """

        #expect(source.shouldUseLegadoRuntimeFetch(for: "{{CONFIG.api.baseUrl}}/search.php?keyword={{key}}&page={{page}}"))
        #expect(source.shouldUseLegadoRuntimeFetch(for: "{{qt}}/search?keyword={{key}}&page={{page}}"))
        #expect(source.shouldUseLegadoRuntimeFetch(for: "{{this.zdym()}}/shuqi/search.php?wd={{key}}&page={{page}}"))
    }

    @Test("jsLib-backed arithmetic template uses Legado runtime")
    func jsLibBackedArithmeticTemplateUsesRuntime() {
        var source = BookSource()
        source.jsLib = "function noop() { return ''; }"

        #expect(source.shouldUseLegadoRuntimeFetch(for: "/api/search?query={{key}}&page={{(page-1)*10}}&tab_type=3"))
    }

    @Test("simple key and page templates keep fast search path")
    func simpleKeyAndPageTemplatesKeepFastPath() {
        var source = BookSource()
        source.jsLib = "function noop() { return ''; }"

        #expect(!source.shouldUseLegadoRuntimeFetch(for: "https://example.com/search?q={{key}}&page={{page}}"))
    }

    @Test("search result regex replacement resolves jsLib templates in the replacement")
    func searchResultRegexReplacementResolvesJSLibTemplates() throws {
        var source = BookSource()
        source.bookSourceName = "Qidian replacement template"
        source.bookSourceUrl = "https://m.qidian.com"
        source.jsLib = "const ho = 'https://m.qidian.com';"
        source.ruleSearch.bookList = "@css:div.y-list__content>div.y-list__item"
        source.ruleSearch.name = "tag.h2@text"
        source.ruleSearch.author = "@css:p[class^=_searchBookAuthor]@text"
        source.ruleSearch.bookUrl =
            "##href=\"//m.qidian.com/chapter/(\\d+)/0/\"##{{ho}}/book/$1/###"

        let html = """
        <div class="y-list__content">
          <div class="y-list__item">
            <a href="//m.qidian.com/chapter/1115277/0/"><h2>斗罗大陆</h2></a>
            <p class="_searchBookAuthor_1">唐家三少</p>
          </div>
        </div>
        """

        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html,
            baseURL: "https://m.qidian.com/soushu/斗罗大陆.html?pageNum=1",
            source: source
        )

        #expect(books.count == 1)
        let actualURL = books.first?.bookUrl ?? "(nil)"
        #expect(
            actualURL == "https://m.qidian.com/book/1115277/",
            "actual search book URL: \(actualURL)"
        )
    }
}

// MARK: - 7. AnalyzeUrl Tests

@Suite("AnalyzeUrl", .serialized)
struct AnalyzeUrlTests {

    @Test("simple absolute URL")
    func simpleUrl() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/api/list")
        #expect(au.url == "https://example.com/api/list")
        #expect(au.method == "GET")
    }

    @Test("URL with POST method via JSON options")
    func postOptions() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/api,{\"method\":\"POST\",\"body\":\"q=test\"}")
        #expect(au.method == "POST")
        #expect(au.body == "q=test")
    }

    @Test("{{key}} template replacement")
    func keyTemplateReplacement() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/search?q={{key}}", key: "hello")
        #expect(au.url.contains("hello"))
    }

    @Test("{{page}} template replacement")
    func pageTemplateReplacement() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/list?page={{page}}", page: 3)
        #expect(au.url.contains("3"))
    }

    @Test("{{pageIndex}} template replacement (0-based)")
    func pageIndexTemplate() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/list?p={{pageIndex}}", page: 3)
        #expect(au.url.contains("2"))
    }

    @Test("@get:{key} with RuleData")
    func getVariableReplacement() {
        let data = RuleData()
        data.putVariable(key: "token", value: "abc123")
        let au = AnalyzeUrl(
            ruleUrl: "https://example.com/api?t=@get:{token}",
            source: data
        )
        #expect(au.url.contains("abc123"))
    }

    @Test("buildRequest JS fallback evaluates URL argument")
    func buildRequestFallbackEvaluatesURLArgument() throws {
        let au = AnalyzeUrl(
            ruleUrl: #"@js: buildRequest(`${backend}/69/search?key={{key}}&page={{page}}`)"#,
            key: "斗罗大陆",
            page: 2,
            jsEvaluator: { jsCode, _ in
                let trimmed = jsCode.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("buildRequest") { return nil }
                if trimmed.hasPrefix("`") {
                    return "https://no.skybook.qzz.io/69/search?key={{key}}&page={{page}}"
                }
                return nil
            }
        )

        let request = try #require(au.toURLRequest())
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("https://no.skybook.qzz.io/69/search"))
        #expect(url.contains("page=2"))
        #expect(url.contains("%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86"))
    }

    @Test("relative URL resolution against base")
    func relativeUrlResolution() {
        let au = AnalyzeUrl(
            ruleUrl: "/api/list",
            baseUrl: "https://example.com/page"
        )
        #expect(au.url.contains("https://example.com"))
    }

    @Test("protocol-relative URL gets https:")
    func protocolRelativeUrl() {
        let au = AnalyzeUrl(ruleUrl: "//cdn.example.com/file.js")
        #expect(au.url == "https://cdn.example.com/file.js")
    }

    @Test("headers from JSON options")
    func headersFromOptions() {
        let au = AnalyzeUrl(
            ruleUrl: "https://example.com,{\"headers\":{\"Authorization\":\"Bearer tok\"}}"
        )
        #expect(au.headers["Authorization"] == "Bearer tok")
    }

    @Test("toURLRequest produces GET request")
    func toURLRequestGet() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/page?q=test")
        let request = au.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString.contains("q=test") == true)
    }

    @Test("toURLRequest produces POST request with body")
    func toURLRequestPost() {
        let au = AnalyzeUrl(
            ruleUrl: "https://example.com/api,{\"method\":\"POST\",\"body\":\"data=value\"}"
        )
        let request = au.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "POST")
        #expect(request?.httpBody != nil)
    }

    @Test("toURLRequest preserves JSON POST body")
    func toURLRequestPostJSONBody() throws {
        let au = AnalyzeUrl(
            ruleUrl: #"https://example.com/api,{"method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"register_email\":\"a@example.com\",\"password\":\"secret\"}"}"#
        )
        let request = try #require(au.toURLRequest())
        let body = String(data: try #require(request.httpBody), encoding: .utf8)

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body == #"{"register_email":"a@example.com","password":"secret"}"#)
        #expect(body?.contains("%7B") == false)
    }

    @Test("page rules array selects correct page")
    func pageRulesArray() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/<first,second,third>", page: 2)
        #expect(au.url.contains("second"))
    }

    @Test("page rules out of bounds uses last")
    func pageRulesOutOfBounds() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com/<a,b>", page: 5)
        #expect(au.url.contains("b"))
    }

    @Test("charset from options")
    func charsetOption() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com,{\"charset\":\"gbk\"}")
        #expect(au.charset == "gbk")
    }

    @Test("empty URL produces nil URLRequest")
    func emptyUrl() {
        let au = AnalyzeUrl(ruleUrl: "")
        // Empty URL: url is "", toURLRequest depends on URL validity
        let request = au.toURLRequest()
        #expect(request == nil)
    }

    @Test("data URI detection")
    func dataUriDetection() {
        let au = AnalyzeUrl(ruleUrl: "data:text/plain;base64,SGVsbG8=")
        #expect(au.isDataUri)
        if let decoded = au.decodeDataUri() {
            #expect(decoded.mimeType == "text/plain")
            #expect(String(data: decoded.data, encoding: .utf8) == "Hello")
        }
    }

    @Test("useWebView option")
    func useWebViewOption() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com,{\"useWebView\":true}")
        #expect(au.useWebView == true)
    }

    @Test("retry option")
    func retryOption() {
        let au = AnalyzeUrl(ruleUrl: "https://example.com,{\"retry\":3}")
        #expect(au.retry == 3)
    }

    @Test("<js> URL can produce typed data URI body as hex")
    func jsUrlDataUriFetchReturnsHexBody() async throws {
        var source = BookSource()
        source.bookSourceUrl = "legado-test-\(UUID().uuidString)"
        source.jsLib = "function noop() { return ''; }"
        let bridge = ModernParserBridge(source: source)
        let ruleUrl = """
        <js>
        let payload = java.base64Encode(JSON.stringify({ key: key, page: page }));
        `data:;base64,${payload},{"type":"gysearch"}`;
        </js>
        """

        let (body, finalUrl) = try await bridge.fetch(ruleUrl: ruleUrl, key: "needle", page: 3)
        let decoded = LegadoJSBridge().hexDecodeToString(body)

        #expect(finalUrl.hasPrefix("data:;base64,"))
        #expect(decoded.contains("\"key\":\"needle\""))
        #expect(decoded.contains("\"page\":3"))
    }

    @Test("source.setVariable stores nested JSON without flattening")
    func sourceSetVariablePreservesNestedJSON() async throws {
        var source = BookSource()
        source.bookSourceUrl = "legado-variable-test-\(UUID().uuidString)"
        source.jsLib = "function noop() { return ''; }"
        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl)
        let bridge = ModernParserBridge(source: source)
        let ruleUrl = """
        <js>
        source.setVariable(JSON.stringify({ more: { mode: "novel" }, list: ["a", "b"] }));
        let payload = java.base64Encode(source.getVariable());
        `data:;base64,${payload},{"type":"state"}`;
        </js>
        """

        let (body, _) = try await bridge.fetch(ruleUrl: ruleUrl)
        let decoded = LegadoJSBridge().hexDecodeToString(body)

        #expect(decoded.contains("\"more\""))
        #expect(decoded.contains("\"mode\":\"novel\""))
        #expect(decoded.contains("\"list\""))
        #expect(BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: source.bookSourceUrl) == decoded)
    }

    @Test("cached cloud config hydrates source variables before explore JS reads filters")
    func cachedCloudConfigHydratesExploreFilters() async throws {
        let cloudPayload = #"{"version":"20260518","hosts":["https://v1.gyks.cf"],"小说":["番茄","七猫"]}"#
        let encodedCloudPayload = Data(cloudPayload.utf8).base64EncodedString()
        var source = BookSource()
        source.bookSourceUrl = "legado-cloud-config-test-\(UUID().uuidString)"
        source.bookSourceName = "Cloud Config Test"
        source.jsLib = """
        let defaultConfig = { 线路: 'https://v1.gyks.cf', 发现页来源: '番茄', 发现页类型: '小说' };
        function _getParsedVariable() {
            let v = source.getVariable();
            try { return JSON.parse(v); } catch(e) { return defaultConfig; }
        }
        function getVariable(k) {
            let parsed = _getParsedVariable();
            if (!k) { return parsed; }
            return parsed[k] == undefined ? '' : parsed[k];
        }
        function setVariable(k, v) {
            let parsed = getVariable();
            parsed[k] = v;
            source.setVariable(JSON.stringify(parsed));
        }
        function getCloudSettings(force) {
            let cachedVersion = cache.get('gyksconfig');
            if (cachedVersion && parseInt(cachedVersion) >= 20260518) {
                return;
            }
            let js = JSON.parse(java.ajax('data:application/json;base64,\(encodedCloudPayload)'));
            cache.put('gyksconfig', js.version);
            setVariable('云端配置', js);
        }
        function cloudPlatforms() {
            getCloudSettings(true);
            var config = getVariable('云端配置');
            return JSON.stringify([{
                title: '平台',
                type: 'select',
                chars: config['小说'] || [],
                action: "show(infoMap['平台'],'发现页来源')",
                default: '番茄'
            }]);
        }
        """
        source.exploreUrl = "<js>cloudPlatforms()</js>"

        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl)
        LegadoCacheBridge(sourceId: source.bookSourceUrl).put("gyksconfig", "20260518")
        defer {
            BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl)
            LegadoCacheBridge(sourceId: source.bookSourceUrl).delete("gyksconfig")
        }

        let items = await ModernParserBridge(source: source).getExploreItems()
        let platform = try #require(items.first)

        #expect(platform.chars == ["番茄", "七猫"])
        let stored = try #require(BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: source.bookSourceUrl))
        #expect(stored.contains("\"云端配置\""))
        #expect(stored.contains("\"hosts\""))
    }

    @Test("Legado runtime bridge runs search detail toc and content data URI pipeline")
    func legadoRuntimePipelineDataURIFlow() async throws {
        var source = BookSource()
        source.bookSourceUrl = "legado-pipeline-test-\(UUID().uuidString)"
        source.bookSourceName = "Pipeline Test"
        source.jsLib = """
        function request(url, method, body) {
            if (url.indexOf('/search') === 0) {
                return JSON.stringify({ data: [{
                    book_id: 'b1', source: 'demo', tab: 'novel',
                    book_name: 'Pipeline Book', author: 'Author',
                    thumb_url: 'https://img.test/cover.jpg', abstract: 'Intro',
                    toc_url: ''
                }]});
            }
            if (url.indexOf('/detail') === 0) {
                return JSON.stringify({ data: {
                    book_id: 'b1', source: 'demo', tab: 'novel',
                    book_name: 'Pipeline Book', author: 'Author',
                    thumb_url: 'https://img.test/cover.jpg', abstract: 'Intro',
                    toc_url: ''
                }});
            }
            if (url.indexOf('/catalog') === 0) {
                return JSON.stringify({ data: [
                    { title: 'Chapter 1', item_id: 'c1', source: 'demo', tab: 'novel' }
                ]});
            }
            if (url.indexOf('/content') === 0) {
                return JSON.stringify({ content: 'Chapter body from runtime' });
            }
            return '{}';
        }
        """
        source.searchUrl = """
        <js>
        let payload = java.base64Encode(JSON.stringify({ key: key, page: page }));
        `data:;base64,${payload},{"type":"search"}`;
        </js>
        """
        source.exploreUrl = """
        <js>
        let payload = java.base64Encode(JSON.stringify({ section: 'hot', page: page }));
        JSON.stringify([{ title: 'Hot Books', url: `data:;base64,${payload},{"type":"discover"}` }]);
        </js>
        """
        source.ruleSearch.bookList = """
        <js>
        JSON.parse(java.hexDecodeToString(result));
        request('/search');
        </js>$.data
        """
        source.ruleSearch.name = "$.book_name"
        source.ruleSearch.author = "$.author"
        source.ruleSearch.coverUrl = "$.thumb_url"
        source.ruleSearch.intro = "$.abstract"
        source.ruleSearch.bookUrl = """
        <js>
        let detail = java.base64Encode(JSON.stringify({
            book_id: result.book_id, source: result.source, tab: result.tab, url: result.toc_url || ''
        }));
        `data:;base64,${detail},{"type":"detail"}`;
        </js>
        """
        source.ruleExplore.bookList = """
        <js>
        JSON.parse(java.hexDecodeToString(result));
        request('/search');
        </js>$.data
        """
        source.ruleExplore.name = "$.book_name"
        source.ruleExplore.author = "$.author"
        source.ruleExplore.coverUrl = "$.thumb_url"
        source.ruleExplore.intro = "$.abstract"
        source.ruleExplore.bookUrl = source.ruleSearch.bookUrl
        source.ruleBookInfo.initScript = """
        <js>
        JSON.parse(java.hexDecodeToString(result));
        request('/detail');
        </js>$.data
        """
        source.ruleBookInfo.name = "$.book_name"
        source.ruleBookInfo.author = "$.author"
        source.ruleBookInfo.coverUrl = "$.thumb_url"
        source.ruleBookInfo.intro = "$.abstract"
        source.ruleBookInfo.tocUrl = """
        <js>
        let toc = java.base64Encode(JSON.stringify({
            book_id: result.book_id, source: result.source, tab: result.tab, url: result.toc_url || ''
        }));
        `data:;base64,${toc},{"type":"toc"}`;
        </js>
        """
        source.ruleToc.chapterList = """
        <js>
        const res = JSON.parse(java.hexDecodeToString(result));
        java.put('book_id', res.book_id);
        request('/catalog');
        </js>$.data
        """
        source.ruleToc.chapterName = "$.title"
        source.ruleToc.chapterUrl = """
        <js>
        let content = java.base64Encode(JSON.stringify({
            book_id: java.get('book_id'), item_id: result.item_id,
            title: result.title, source: result.source, tab: result.tab
        }));
        `data:;base64,${content},{"type":"content"}`;
        </js>
        """
        source.ruleContent.content = """
        <js>
        JSON.parse(java.hexDecodeToString(result));
        request('/content');
        </js>$.content
        """
        source.ruleContent.title = "@js:result.title || ''"

        let bridge = ModernParserBridge(source: source)
        let books = try await bridge.searchBooks(keyword: "Pipeline")
        #expect(books.count == 1)
        #expect(books[0].bookUrl.hasPrefix("data:;base64,"))

        let info = try await bridge.getBookInfo(url: books[0].bookUrl)
        #expect(info.name == "Pipeline Book")
        #expect(info.tocUrl.hasPrefix("data:;base64,"))

        let chapters = try await bridge.getChapterList(url: info.tocUrl)
        #expect(chapters.map(\.title) == ["Chapter 1"])
        #expect(chapters[0].url.hasPrefix("data:;base64,"))

        let content = try await bridge.getContent(url: chapters[0].url)
        #expect(content == "Chapter body from runtime")

        let fetcher = BookSourceFetcher.shared
        let discoverItems = await fetcher.discoverItems(page: 2, in: source)
        #expect(discoverItems.compactMap(\.title) == ["Hot Books"])
        let discoveredBooks = try await fetcher.discoverBooks(from: discoverItems[0], in: source)
        #expect(discoveredBooks.map(\.name) == ["Pipeline Book"])

        let fetchedBooks = try await fetcher.search(query: "Pipeline", in: source)
        #expect(fetchedBooks.count == 1)
        let infoPackage = try await fetcher.fetchBookInfoPackage(
            url: fetchedBooks[0].bookUrl,
            source: source,
            runtimeVariables: fetchedBooks[0].runtimeVariables
        )
        #expect(infoPackage.name == "Pipeline Book")
        let tocPackage = try await fetcher.fetchTOCPackage(
            tocUrl: infoPackage.tocUrl,
            source: source,
            runtimeVariables: infoPackage.runtimeVariables
        )
        #expect(tocPackage.chapters.map(\.title) == ["Chapter 1"])
        let bookId = UUID()
        let chapterPackage = try await fetcher.fetchChapterPackage(
            ref: tocPackage.chapters[0],
            bookId: bookId,
            source: source
        )
        defer {
            fetcher.clearAllChapterCache(bookId: bookId)
        }
        #expect(chapterPackage.content == "Chapter body from runtime")
    }
}

@Suite("BookSource local fixture", .serialized)
struct BookSourceLocalFixtureTests {

    @Test("local Legado source fixture decodes when path is provided")
    func localLegadoSourceFixtureDecodes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["YueduLocalBookSourceFixturePath"]
                ?? env["TEST_RUNNER_YueduLocalBookSourceFixturePath"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        let source = try #require(
            sources.first { $0.bookSourceName.contains("光遇") || $0.bookSourceUrl.contains("光遇") }
        )

        #expect(!source.jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<js>"))
        #expect(source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<js>"))
        #expect(source.ruleBookInfo.initScript.contains("java.hexDecodeToString"))
        #expect(source.ruleToc.chapterUrl.contains("data:;base64"))
        #expect(source.ruleContent.content.contains("chapter.index"))
        #expect(!source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("local GuangYu fixture hydrates cloud discover platform filters")
    func localGuangYuFixtureHydratesCloudDiscoverFilters() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["YueduLocalBookSourceFixturePath"]
                ?? env["TEST_RUNNER_YueduLocalBookSourceFixturePath"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        let source = try #require(
            sources.first { $0.bookSourceName.contains("光遇") || $0.bookSourceUrl.contains("光遇") }
        )
        let runtimeStore = BookSourceRuntimeStateStore.shared
        let cache = LegadoCacheBridge(sourceId: source.bookSourceUrl)
        runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl)
        cache.put("gyksconfig", "20260518")
        defer {
            runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl)
            cache.delete("gyksconfig")
        }

        let items = await ModernParserBridge(source: source).getExploreItems()
        let platform = try #require(items.first { $0.title == "平台" })
        let platforms = try #require(platform.chars)

        #expect(platforms.count > 6)
        #expect(platforms.contains("69书吧"))
        #expect(platforms.contains("小米"))
    }
}

@Suite("CustomUrl", .serialized)
struct CustomUrlTests {

    @Test("simple URL without options")
    func simpleUrl() {
        let cu = CustomUrl(url: "https://example.com")
        #expect(cu.url == "https://example.com")
        #expect(cu.attributes.isEmpty)
    }

    @Test("serialized URL with JSON options")
    func parseSerialized() {
        let cu = CustomUrl(serialized: "https://example.com,{\"method\":\"POST\"}")
        #expect(cu.url == "https://example.com")
        #expect(cu.attributes["method"] as? String == "POST")
    }

    @Test("serialized URL without options")
    func parseSerializedNoOptions() {
        let cu = CustomUrl(serialized: "https://example.com/path")
        #expect(cu.url == "https://example.com/path")
        #expect(cu.attributes.isEmpty)
    }

    @Test("serialization roundtrip")
    func serializationRoundtrip() {
        var cu = CustomUrl(url: "https://example.com")
        cu.putAttribute(key: "method", value: "POST")
        cu.putAttribute(key: "retry", value: 3)

        let serialized = cu.serialized()
        let cu2 = CustomUrl(serialized: serialized)
        #expect(cu2.url == "https://example.com")
        #expect(cu2.attributes["method"] as? String == "POST")
        #expect(cu2.attributes["retry"] as? Int == 3)
    }

    @Test("getAttribute type casting")
    func getAttributeTyped() {
        var cu = CustomUrl(url: "https://example.com")
        cu.putAttribute(key: "count", value: 42)
        let val: Int? = cu.getAttribute(key: "count")
        #expect(val == 42)
        let missing: String? = cu.getAttribute(key: "nonexistent")
        #expect(missing == nil)
    }

    @Test("serialized with no attributes returns just URL")
    func serializedNoAttributes() {
        let cu = CustomUrl(url: "https://example.com")
        #expect(cu.serialized() == "https://example.com")
    }
}

// MARK: - 8. JSCoreEngine Tests

@Suite("JSCoreEngine", .serialized)
struct JSCoreEngineTests {

    @Test("simple expression evaluation")
    func simpleExpression() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("1 + 2")
        #expect(result == "3")
    }

    @Test("string return")
    func stringReturn() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("'hello world'")
        #expect(result == "hello world")
    }

    @Test("number return")
    func numberReturn() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("3.14")
        #expect(result != nil)
        #expect(result!.contains("3.14"))
    }

    @Test("object return is JSON serialized")
    func objectReturn() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("({a: 1, b: 'hello'})")
        #expect(result != nil)
        // Should be a JSON string
        #expect(result!.contains("\"a\""))
        #expect(result!.contains("\"b\""))
    }

    @Test("result variable binding")
    func resultVariableBinding() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("result.toUpperCase()", result: "hello")
        #expect(result == "HELLO")
    }

    @Test("result variable with nil")
    func resultVariableNil() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("typeof result", result: nil)
        #expect(result == "object") // NSNull maps to object
    }

    @Test("custom bindings")
    func customBindings() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("x + y", bindings: ["x": 10, "y": 20])
        #expect(result == "30")
    }

    @Test("java.put/get bridge")
    func javaPutGetBridge() {
        let engine = JSCoreEngine()
        var storage: [String: String] = [:]
        engine.putData = { key, val in storage[key] = val }
        engine.getData = { key in storage[key] }

        _ = engine.evaluate("java.put('myKey', 'myValue')")
        let result = engine.evaluate("java.get('myKey')")
        #expect(result == "myValue")
        #expect(storage["myKey"] == "myValue")
    }

    @Test("java.base64Encode/Decode bridge")
    func javaBase64Bridge() {
        let engine = JSCoreEngine()
        let encoded = engine.evaluate("java.base64Encode('Hello')")
        #expect(encoded == "SGVsbG8=")
        let decoded = engine.evaluate("java.base64Decode('SGVsbG8=')")
        #expect(decoded == "Hello")
    }

    @Test("error handling for invalid JS")
    func errorHandlingInvalidJS() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("this is not valid javascript }{")
        // Should return nil or capture error
        #expect(engine.lastError != nil || result == nil || result == "undefined")
    }

    @Test("reset clears context")
    func resetClearsContext() {
        let engine = JSCoreEngine()
        _ = engine.evaluate("var testVar = 42")
        engine.reset()
        let result = engine.evaluate("typeof testVar")
        #expect(result == "undefined")
    }

    @Test("cache object is available from JS")
    func cacheObjectFromJS() {
        var source = BookSource()
        source.bookSourceUrl = "cache-js-\(UUID().uuidString)"
        let engine = JSCoreEngine()
        engine.bookSource = source

        _ = engine.evaluate("cache.putMemory('memKey', 'memVal')")
        let result = engine.evaluate("cache.getFromMemory('memKey')")

        #expect(result == "memVal")
    }

    @Test("java.getCookie can return a named cookie")
    func javaGetCookieNamedValue() {
        let host = "https://cookie-\(UUID().uuidString).example.com"
        CookieStore.shared.set(url: host, cookie: "qttoken=abc123")
        CookieStore.shared.set(url: host, cookie: "sessionid=sid456")
        defer {
            CookieStore.shared.remove(url: host)
        }
        let engine = JSCoreEngine()

        let result = engine.evaluate("java.getCookie('\(host)', 'sessionid')")

        #expect(result == "sid456")
    }

    @Test("startBrowserAwait returns captured body")
    func startBrowserAwaitReturnsBody() {
        let engine = JSCoreEngine()
        engine.browserPresentHandler = { _, _, completion in
            completion("<html>done</html>")
        }

        let result = engine.evaluate(
            "java.startBrowserAwait('https://example.com', 'Title').body()"
        )

        #expect(result == "<html>done</html>")
    }

    // MARK: Login-source bridge methods (番茄/起点/企点 special sources)

    @Test("eval() is enabled for Legado sources")
    func evalEnabled() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("eval('1 + 2')") == "3")
        // Explore-builder pattern used by 番茄 discovery rules: eval('sort'+i+'.push(...)')
        let r = engine.evaluate("var sort0 = []; eval('sort' + 0 + '.push(7)'); sort0[0]")
        #expect(r == "7")
    }

    @Test("cookie.getKey returns a named cookie value")
    func cookieGetKey() {
        let host = "https://ck-\(UUID().uuidString).example.com"
        CookieStore.shared.set(url: host, cookie: "sessionid=sid789")
        defer { CookieStore.shared.remove(url: host) }
        let engine = JSCoreEngine()
        #expect(engine.evaluate("cookie.getKey('\(host)', 'sessionid')") == "sid789")
    }

    @Test("cookie.getKey accepts a bare domain tag")
    func cookieGetKeyBareDomain() {
        let domain = "fq-\(UUID().uuidString.prefix(8)).example.com"
        CookieStore.shared.set(url: "https://\(domain)", cookie: "token=t123")
        defer { CookieStore.shared.remove(url: "https://\(domain)") }
        let engine = JSCoreEngine()
        #expect(engine.evaluate("cookie.getKey('\(domain)', 'token')") == "t123")
    }

    @Test("source.getLoginHeader bridges to handler")
    func sourceGetLoginHeader() {
        let engine = JSCoreEngine()
        engine.sourceBridge.getLoginHeaderHandler = { "{\"Cookie\":\"a=b\"}" }
        let result = engine.evaluate("source.getLoginHeader()")
        #expect(result != nil)
        #expect(result!.contains("a=b"))
    }

    @Test("java.importScript returns inline (non-http) text verbatim")
    func javaImportScriptInline() {
        let engine = JSCoreEngine()
        // Non-URL input is returned unchanged (no network), so eval() can consume it.
        let result = engine.evaluate("eval(java.importScript('1 + 4'))")
        #expect(result == "5")
    }
}

// MARK: - 9. JSSandbox Tests

@Suite("JSSandbox", .serialized)
struct JSSandboxTests {

    @Test("configure removes unsafe globals")
    func configureRemovesUnsafe() {
        let ctx = JSContext()!
        JSSandbox.configure(ctx)
        let fetchResult = ctx.evaluateScript("typeof fetch")
        #expect(fetchResult?.toString() == "undefined")
        let xhrResult = ctx.evaluateScript("typeof XMLHttpRequest")
        #expect(xhrResult?.toString() == "undefined")
    }

    @Test("sanitize rejects oversized scripts")
    func sanitizeRejectsLarge() {
        let largeScript = String(repeating: "a", count: 100 * 1024 + 1)
        #expect(JSSandbox.sanitize(largeScript) == false)
    }

    @Test("sanitize accepts normal scripts")
    func sanitizeAcceptsNormal() {
        #expect(JSSandbox.sanitize("var x = 1;") == true)
    }

    @Test("evaluateWithTimeout returns result for fast script")
    func evaluateWithTimeoutFast() {
        let ctx = JSContext()!
        JSSandbox.configure(ctx)
        let result = JSSandbox.evaluateWithTimeout(ctx, script: "1 + 2", timeout: 5)
        #expect(result?.toInt32() == 3)
    }

    @Test("URL whitelist allows matching domain")
    func urlWhitelistAllow() {
        let allowed = JSSandbox.isURLAllowed(
            "https://api.example.com/data",
            allowedDomains: ["example.com"]
        )
        #expect(allowed == true)
    }

    @Test("URL whitelist rejects non-matching domain")
    func urlWhitelistReject() {
        let allowed = JSSandbox.isURLAllowed(
            "https://evil.com/data",
            allowedDomains: ["example.com"]
        )
        #expect(allowed == false)
    }

    @Test("URL whitelist with nil allows all")
    func urlWhitelistNilAllowsAll() {
        let allowed = JSSandbox.isURLAllowed("https://anything.com", allowedDomains: nil)
        #expect(allowed == true)
    }

    @Test("URL whitelist with empty set allows all")
    func urlWhitelistEmptyAllowsAll() {
        let allowed = JSSandbox.isURLAllowed("https://anything.com", allowedDomains: [])
        #expect(allowed == true)
    }

    @Test("URL whitelist rejects invalid URL")
    func urlWhitelistInvalidUrl() {
        let allowed = JSSandbox.isURLAllowed("not a url", allowedDomains: ["example.com"])
        #expect(allowed == false)
    }

    @Test("polyfills install btoa/atob")
    func polyfillsBtoaAtob() {
        let ctx = JSContext()!
        // Install java bridge stub for btoa/atob to use
        let bridge = LegadoJSBridge()
        ctx.setObject(bridge, forKeyedSubscript: "java" as NSString)
        JSSandbox.configure(ctx)

        let encoded = ctx.evaluateScript("btoa('Hello')")
        #expect(encoded?.toString() == "SGVsbG8=")
    }
}

// MARK: - 10. LoginManager & LoginState Tests

@Suite("LoginState", .serialized)
struct LoginStateTests {

    @Test("LoginState equality")
    func loginStateEquality() {
        #expect(LoginState.notRequired == LoginState.notRequired)
        #expect(LoginState.loggedIn == LoginState.loggedIn)
        #expect(LoginState.loggedOut == LoginState.loggedOut)
        #expect(LoginState.failed("x") == LoginState.failed("x"))
        #expect(LoginState.failed("x") != LoginState.failed("y"))
        #expect(LoginState.loggedIn != LoginState.loggedOut)
    }
}

@Suite("LoginError", .serialized)
struct LoginErrorTests {

    @Test("error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [LoginError] = [
            .noLoginUrl,
            .invalidLoginUrl("bad"),
            .loginFunctionMissing,
            .javaScriptError("msg"),
            .httpError(401),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("httpError includes status code")
    func httpErrorCode() {
        let error = LoginError.httpError(403)
        #expect(error.errorDescription!.contains("403"))
    }

    @Test("networkError wraps underlying error")
    func networkErrorWraps() {
        let underlying = NSError(domain: "test", code: -1)
        let error = LoginError.networkError(underlying)
        #expect(error.errorDescription != nil)
    }
}

// MARK: - 11. LegadoJSBridge Tests

@Suite("LegadoJSBridge", .serialized)
struct LegadoJSBridgeTests {

    @Test("base64Encode and base64Decode roundtrip")
    func base64Roundtrip() {
        let bridge = LegadoJSBridge()
        let encoded = bridge.base64Encode("Hello World")
        let decoded = bridge.base64Decode(encoded)
        #expect(decoded == "Hello World")
    }

    @Test("base64Decode with invalid input returns empty")
    func base64DecodeInvalid() {
        let bridge = LegadoJSBridge()
        let result = bridge.base64Decode("!!!invalid!!!")
        // Returns empty on failure
        #expect(result.isEmpty || result == "!!!invalid!!!")
    }

    @Test("md5Encode produces 32-char hex")
    func md5Encode() {
        let bridge = LegadoJSBridge()
        let hash = bridge.md5Encode("hello")
        #expect(hash.count == 32)
        #expect(hash == "5d41402abc4b2a76b9719d911017c592")
    }

    @Test("md5Encode16 produces 16-char hex")
    func md5Encode16() {
        let bridge = LegadoJSBridge()
        let hash = bridge.md5Encode16("hello")
        #expect(hash.count == 16)
    }

    @Test("put and get via delegates")
    func putGetDelegates() {
        let bridge = LegadoJSBridge()
        var storage: [String: String] = [:]
        bridge.putData = { k, v in storage[k] = v }
        bridge.getData = { k in storage[k] }

        bridge.put("key1", "val1")
        #expect(bridge.get("key1") == "val1")
    }

    @Test("get without delegate returns empty")
    func getWithoutDelegate() {
        let bridge = LegadoJSBridge()
        #expect(bridge.get("anything") == "")
    }

    @Test("log returns the message")
    func logReturns() {
        let bridge = LegadoJSBridge()
        let result = bridge.log("test message")
        #expect(result == "test message")
    }
}

// MARK: - 11b. LegadoSourceBridge Tests

@Suite("LegadoSourceBridge", .serialized)
struct LegadoSourceBridgeTests {

    @Test("static properties are exposed correctly")
    func staticProperties() {
        let bridge = LegadoSourceBridge(
            bookSourceUrl: "https://example.com",
            bookSourceName: "Test",
            bookSourceGroup: "Group",
            bookSourceComment: "Comment",
            loginUrl: "login",
            header: "{}",
            loginCheckJs: "check"
        )
        #expect(bridge.bookSourceUrl == "https://example.com")
        #expect(bridge.bookSourceName == "Test")
        #expect(bridge.bookSourceGroup == "Group")
        #expect(bridge.bookSourceComment == "Comment")
        #expect(bridge.loginUrl == "login")
        #expect(bridge.header == "{}")
        #expect(bridge.loginCheckJs == "check")
        #expect(bridge.key == "https://example.com")
    }

    @Test("getVariable/setVariable via handlers")
    func getSetVariable() {
        let bridge = LegadoSourceBridge.from(BookSource())
        var stored: String? = "{\"key\":\"value\"}"
        bridge.getVariableHandler = { stored }
        bridge.setVariableHandler = { stored = $0 }
        #expect(bridge.getVariable() == "{\"key\":\"value\"}")
        bridge.setVariable("{\"key\":\"new\"}")
        #expect(stored == "{\"key\":\"new\"}")
    }

    @Test("getVariable returns empty when no handler set")
    func getVariableNoHandler() {
        let bridge = LegadoSourceBridge.from(BookSource())
        #expect(bridge.getVariable() == "")
    }

    @Test("getLoginInfo returns nil when no handler set")
    func getLoginInfoNoHandler() {
        let bridge = LegadoSourceBridge.from(BookSource())
        #expect(bridge.getLoginInfo() == nil)
    }

    @Test("getLoginInfoMap returns empty when no handler set")
    func getLoginInfoMapNoHandler() {
        let bridge = LegadoSourceBridge.from(BookSource())
        #expect(bridge.getLoginInfoMap().toDictionary()?.isEmpty ?? true)
    }

    @Test("putLoginInfo delegates to handler")
    func putLoginInfo() {
        let bridge = LegadoSourceBridge.from(BookSource())
        var received: String?
        bridge.putLoginInfoHandler = { received = $0 }
        bridge.putLoginInfo("{\"email\":\"test\"}")
        #expect(received == "{\"email\":\"test\"}")
    }

    @Test("putLoginHeader delegates to handler")
    func putLoginHeader() {
        let bridge = LegadoSourceBridge.from(BookSource())
        var received: String?
        bridge.putLoginHeaderHandler = { received = $0 }
        bridge.putLoginHeader("{\"Cookie\":\"abc\"}")
        #expect(received == "{\"Cookie\":\"abc\"}")
    }

    @Test("getHeaderMap returns empty when no handler set")
    func getHeaderMapNoHandler() {
        let bridge = LegadoSourceBridge.from(BookSource())
        #expect(bridge.getHeaderMap().toDictionary()?.isEmpty ?? true)
    }

    @Test("put/get key-value store with handlers")
    func putGetKV() {
        let bridge = LegadoSourceBridge.from(BookSource())
        var stored: String? = "{}"
        bridge.getVariableHandler = { stored }
        bridge.setVariableHandler = { stored = $0 }
        bridge.put("name", "value")
        // get reads from variable handler (stored JSON)
        #expect(bridge.get("name") == "value")
    }

    @Test("get returns empty for unknown key")
    func getUnknownKey() {
        let bridge = LegadoSourceBridge.from(BookSource())
        #expect(bridge.get("unknown") == "")
    }

    @Test("Factory creates bridge from BookSource")
    func factoryFromBookSource() {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com"
        source.bookSourceName = "Test"
        source.bookSourceGroup = "group"
        source.bookSourceComment = "cmt"
        source.loginUrl = "login"
        source.header = "{}"
        source.loginCheckJs = "check"
        let bridge = LegadoSourceBridge.from(source)
        #expect(bridge.bookSourceUrl == "https://example.com")
        #expect(bridge.bookSourceName == "Test")
    }
}

// MARK: - 11c. LegadoCacheBridge Tests

@Suite("LegadoCacheBridge", .serialized)
struct LegadoCacheBridgeTests {

    @Test("put and get persistent")
    func putGetPersistent() {
        let bridge = LegadoCacheBridge(sourceId: "test")
        bridge.put("key1", "value1")
        #expect(bridge.get("key1") == "value1")
        bridge.delete("key1")
    }

    @Test("get returns nil for unknown key")
    func getUnknownKey() {
        let bridge = LegadoCacheBridge(sourceId: "test2")
        #expect(bridge.get("nonexistent") == nil)
    }

    @Test("delete removes key")
    func deleteKey() {
        let bridge = LegadoCacheBridge(sourceId: "test3")
        bridge.put("temp", "val")
        #expect(bridge.get("temp") == "val")
        bridge.delete("temp")
        #expect(bridge.get("temp") == nil)
    }

    @Test("putMemory and getFromMemory")
    func memoryCache() {
        let bridge = LegadoCacheBridge(sourceId: "test4")
        bridge.putMemory("memKey", "memVal")
        #expect(bridge.getFromMemory("memKey") == "memVal")
    }

    @Test("deleteMemory removes from memory")
    func deleteMemory() {
        let bridge = LegadoCacheBridge(sourceId: "test5")
        bridge.putMemory("memDel", "val")
        #expect(bridge.getFromMemory("memDel") == "val")
        bridge.deleteMemory("memDel")
        #expect(bridge.getFromMemory("memDel") == nil)
    }

    @Test("getFromMemory returns nil for unknown key")
    func memoryUnknown() {
        let bridge = LegadoCacheBridge(sourceId: "test6")
        #expect(bridge.getFromMemory("nothing") == nil)
    }

    @Test("different source IDs are isolated")
    func sourceIdIsolation() {
        let bridgeA = LegadoCacheBridge(sourceId: "A")
        let bridgeB = LegadoCacheBridge(sourceId: "B")
        bridgeA.put("shared", "fromA")
        bridgeB.put("shared", "fromB")
        #expect(bridgeA.get("shared") == "fromA")
        #expect(bridgeB.get("shared") == "fromB")
        bridgeA.delete("shared")
        bridgeB.delete("shared")
    }
}

// MARK: - 11d. LegadoStrResponse Tests

@Suite("LegadoStrResponse", .serialized)
struct LegadoStrResponseTests {

    @Test("body returns stored body")
    func bodyReturns() {
        let response = LegadoStrResponse(url: "https://example.com", body: "<html>test</html>")
        #expect(response.url == "https://example.com")
        #expect(response.body() == "<html>test</html>")
    }

    @Test("empty body is fine")
    func emptyBody() {
        let response = LegadoStrResponse(url: "about:blank", body: "")
        #expect(response.url == "about:blank")
        #expect(response.body() == "")
    }
}

// MARK: - 12. Integration: RuleAnalyzer + SourceRule

@Suite("RuleAnalyzer + SourceRule Integration", .serialized)
struct RuleAnalyzerSourceRuleIntegrationTests {

    @Test("split and parse multiple rules with ||")
    func splitAndParseMultiple() {
        let analyzer = RuleAnalyzer(data: "@css:div.title@text||@json:$.title")
        let parts = analyzer.splitRule("||")
        #expect(parts.count == 2)

        let rule1 = SourceRule(ruleStr: parts[0])
        #expect(rule1.mode == .default)

        let rule2 = SourceRule(ruleStr: parts[1])
        #expect(rule2.mode == .json)
    }

    @Test("rule with combined @put and @get")
    func combinedPutGet() {
        let rule = SourceRule(ruleStr: "@css:a@href@put:{\"host\":\"example.com\"}")
        #expect(rule.putMap["host"] == "example.com")
        #expect(rule.mode == .default)
    }

    @Test("rule with ## regex and @get template")
    func regexWithGetTemplate() {
        let rule = SourceRule(ruleStr: "div@text##@get:{pattern}##replacement")
        #expect(rule.paramSize > 0)
    }
}

// MARK: - 13. Explore / Discover Parsing

@Suite("ModernParserBridge Explore", .serialized)
struct ModernParserBridgeExploreTests {

    @Test("plain text exploreUrl is parsed as Legado explore kinds without fetching")
    func plainTextExploreKinds() async {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com/source"
        source.bookSourceName = "Plain Explore"
        source.exploreUrl = """
        分類一::https://example.com/cat/1?page={{page}}
        分組標題
        分類二::https://example.com/cat/2
        """

        let items = await ModernParserBridge(source: source).getExploreItems(page: 2)

        #expect(items.map { $0.title ?? "" } == ["分類一", "分組標題", "分類二"])
        #expect(items.map { $0.url } == [
            "https://example.com/cat/1?page={{page}}",
            nil,
            "https://example.com/cat/2"
        ])
    }

    @Test("JS exploreUrl returning plain text is parsed as Legado explore kinds")
    func jsReturnedPlainTextExploreKinds() async {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com/source"
        source.bookSourceName = "JS Text Explore"
        source.exploreUrl = """
        <js>
        '排行榜::https://example.com/rank\\n完本::https://example.com/done'
        </js>
        """

        let items = await ModernParserBridge(source: source).getExploreItems()

        #expect(items.map { $0.title ?? "" } == ["排行榜", "完本"])
        #expect(items.map { $0.url ?? "" } == [
            "https://example.com/rank",
            "https://example.com/done"
        ])
    }

    @Test("inline JSON exploreUrl is parsed without fetching")
    func inlineJSONExploreKinds() async {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com/source"
        source.bookSourceName = "JSON Explore"
        source.exploreUrl = #"[{"title":"推薦","url":"https://example.com/recommend","style":{"layout_flexBasisPercent":0.45}}]"#

        let items = await ModernParserBridge(source: source).getExploreItems()

        #expect(items.count == 1)
        #expect(items.first?.title == "推薦")
        #expect(items.first?.url == "https://example.com/recommend")
        #expect(items.first?.style?["layout_flexBasisPercent"] == "0.45")
    }

    @Test("templated discover URL remains fetchable and resolves through AnalyzeUrl")
    func templatedDiscoverURLFetchesThroughAnalyzeUrl() async throws {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com/source"
        source.bookSourceName = "Template Discover"
        source.jsLib = """
        function makeDiscoverData() {
            let payload = java.base64Encode(JSON.stringify({
                data: {
                    books: [{
                        name: 'Discover Template Book',
                        author: 'Template Author',
                        url: 'https://example.com/book/1'
                    }]
                }
            }));
            return `data:;base64,${payload},{"type":"discover"}`;
        }
        """
        source.ruleExplore.bookList = """
        <js>
        JSON.parse(java.hexDecodeToString(result));
        </js>$.data.books[*]
        """
        source.ruleExplore.name = "$.name"
        source.ruleExplore.author = "$.author"
        source.ruleExplore.bookUrl = "$.url"

        let raw = ModernParserBridge.DiscoverItem(
            title: "歷史",
            url: "{{makeDiscoverData()}}"
        )

        let card = try #require(await MainActor.run { DiscoverViewModel.mapItem(raw) })
        #expect(!card.isAction)
        #expect(card.isFetchable)

        let books = try await BookSourceFetcher.shared.discoverBooks(from: raw, in: source)
        #expect(books.map(\.name) == ["Discover Template Book"])
        #expect(books.map(\.author) == ["Template Author"])
        #expect(books.map(\.bookUrl) == ["https://example.com/book/1"])
    }

    @Test("browser script discover URL stays an action")
    func browserScriptDiscoverURLStaysAction() async throws {
        let raw = ModernParserBridge.DiscoverItem(
            title: "登入",
            url: "{{java.startBrowser('https://example.com/login','登入')}}"
        )

        let card = try #require(await MainActor.run { DiscoverViewModel.mapItem(raw) })
        #expect(card.isAction)
        #expect(!card.isFetchable)
        #expect(card.actionURL == "https://example.com/login")
    }
}

@Suite("Discover Filters", .serialized)
struct DiscoverFilterTests {

    @MainActor
    @Test("source select items become filters and stay out of showcase cards")
    func sourceSelectItemsBecomeFilters() throws {
        let raw: [ModernParserBridge.DiscoverItem] = [
            .init(
                title: "平台",
                type: "select",
                action: "show(infoMap['平台'],'发现页来源')",
                chars: ["番茄", "七猫", "喜马拉雅"],
                default: "番茄"
            ),
            .init(title: "排行榜", url: "https://example.com/rank")
        ]

        let filters = DiscoverViewModel.extractFilters(from: raw)
        let platform = try #require(filters.first)

        #expect(platform.title == "平台")
        #expect(platform.paramKey == "发现页来源")
        #expect(platform.options == ["番茄", "七猫", "喜马拉雅"])
        #expect(platform.selected == "番茄")
        #expect(raw.compactMap(DiscoverViewModel.mapItem).map(\.title) == ["排行榜"])
    }

    @MainActor
    @Test("selecting platform stores search source under the current mode")
    func selectingPlatformStoresSearchSourceForCurrentMode() throws {
        var source = BookSource()
        source.bookSourceUrl = "discover-filter-test-\(UUID().uuidString)"
        source.bookSourceName = "Aggregator Explore"
        source.enabledExplore = true
        let runtimeStore = BookSourceRuntimeStateStore.shared
        runtimeStore.setSourceVariableJSON(
            #"{"发现页类型":"漫画","更多设置":{"搜索模式":"漫画"}}"#,
            for: source.bookSourceUrl
        )
        defer { runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let model = DiscoverViewModel()
        model.exploreSources = [source]
        model.selectedSourceId = source.id
        model.filters = [
            DiscoverFilter(
                title: "平台",
                paramKey: "发现页来源",
                options: ["番茄", "全面漫画"],
                selected: "番茄"
            )
        ]

        let filter = try #require(model.filters.first)
        model.selectFilter(filter, value: "全面漫画")

        let stored = try #require(runtimeStore.sourceVariableJSON(for: source.bookSourceUrl))
        let dict = try #require(Self.jsonObject(stored))
        let more = try #require(dict["更多设置"] as? [String: Any])

        #expect(dict["发现页来源"] as? String == "全面漫画")
        #expect(more["搜索模式"] as? String == "漫画")
        #expect(more["漫画"] as? String == "全面漫画")
    }

    @MainActor
    @Test("selecting mode keeps the saved source instead of forcing Fanqie")
    func selectingModeUsesSavedSourceForMode() throws {
        var source = BookSource()
        source.bookSourceUrl = "discover-mode-source-test-\(UUID().uuidString)"
        source.bookSourceName = "Aggregator Explore"
        source.enabledExplore = true
        let runtimeStore = BookSourceRuntimeStateStore.shared
        runtimeStore.setSourceVariableJSON(
            #"{"发现页类型":"小说","发现页来源":"番茄","更多设置":{"搜索模式":"小说","漫画":"全面漫画"}}"#,
            for: source.bookSourceUrl
        )
        defer { runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let model = DiscoverViewModel()
        model.exploreSources = [source]
        model.selectedSourceId = source.id
        model.filters = [
            DiscoverFilter(
                title: "类型",
                paramKey: "发现页类型",
                options: ["小说", "漫画"],
                selected: "小说"
            )
        ]

        let filter = try #require(model.filters.first)
        model.selectFilter(filter, value: "漫画")

        let stored = try #require(runtimeStore.sourceVariableJSON(for: source.bookSourceUrl))
        let dict = try #require(Self.jsonObject(stored))
        let more = try #require(dict["更多设置"] as? [String: Any])

        #expect(dict["发现页类型"] as? String == "漫画")
        #expect(dict["发现页来源"] as? String == "全面漫画")
        #expect(more["搜索模式"] as? String == "漫画")
        #expect(more["漫画"] as? String == "全面漫画")
    }

    @MainActor
    @Test("selecting mode defaults discover source to all when no mode source is saved")
    func selectingModeDefaultsSourceToAll() throws {
        var source = BookSource()
        source.bookSourceUrl = "discover-mode-all-test-\(UUID().uuidString)"
        source.bookSourceName = "Aggregator Explore"
        source.enabledExplore = true
        let runtimeStore = BookSourceRuntimeStateStore.shared
        runtimeStore.setSourceVariableJSON(
            #"{"发现页类型":"小说","发现页来源":"番茄","更多设置":{"搜索模式":"小说"}}"#,
            for: source.bookSourceUrl
        )
        defer { runtimeStore.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let model = DiscoverViewModel()
        model.exploreSources = [source]
        model.selectedSourceId = source.id
        model.filters = [
            DiscoverFilter(
                title: "类型",
                paramKey: "发现页类型",
                options: ["小说", "听书"],
                selected: "小说"
            )
        ]

        let filter = try #require(model.filters.first)
        model.selectFilter(filter, value: "听书")

        let stored = try #require(runtimeStore.sourceVariableJSON(for: source.bookSourceUrl))
        let dict = try #require(Self.jsonObject(stored))
        let more = try #require(dict["更多设置"] as? [String: Any])

        #expect(dict["发现页类型"] as? String == "听书")
        #expect(dict["发现页来源"] as? String == "全部")
        #expect(more["搜索模式"] as? String == "听书")
        #expect(more["听书"] as? String == "全部")
    }

    @MainActor
    @Test("reload repairs old hard-coded Fanqie source from saved mode setting")
    func repairsOldHardcodedFanqieSourceFromSavedModeSetting() throws {
        let repaired = DiscoverViewModel.repairHardcodedDiscoverSource(in: [
            "发现页类型": "漫画",
            "发现页来源": "番茄",
            "更多设置": [
                "搜索模式": "漫画",
                "漫画": "全面漫画"
            ]
        ])

        #expect(repaired["发现页来源"] as? String == "全面漫画")
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - 14. Edge Cases & Stress Tests

@Suite("Edge Cases", .serialized)
struct EdgeCaseTests {

    @Test("JSONPath on deeply nested data")
    func deepNesting() {
        let data: [String: Any] = ["a": ["b": ["c": ["d": ["e": "deep"]]]]]
        let results = JSONPathEvaluator.query("$.a.b.c.d.e", on: data)
        #expect(results.first as? String == "deep")
    }

    @Test("JSONPath on empty array")
    func emptyArray() {
        let data: [String: Any] = ["list": [] as [Any]]
        let results = JSONPathEvaluator.query("$.list[0]", on: data)
        #expect(results.isEmpty)
    }

    @Test("JSONPath filter with nested AND")
    func filterNestedAnd() {
        let data: [String: Any] = [
            "items": [
                ["a": 1, "b": 2],
                ["a": 3, "b": 4],
                ["a": 1, "b": 4],
            ] as [[String: Any]]
        ]
        let results = JSONPathEvaluator.query("$.items[?(@.a == 1 && @.b == 2)]", on: data)
        #expect(results.count == 1)
    }

    @Test("JSONPath filter with OR")
    func filterOr() {
        let data: [String: Any] = [
            "items": [
                ["x": 1],
                ["x": 2],
                ["x": 3],
            ] as [[String: Any]]
        ]
        let results = JSONPathEvaluator.query("$.items[?(@.x == 1 || @.x == 3)]", on: data)
        #expect(results.count == 2)
    }

    @Test("SourceRule with empty string")
    func sourceRuleEmpty() {
        let rule = SourceRule(ruleStr: "")
        #expect(rule.rule == "")
    }

    @Test("Legado book bridge exports media type runtime state")
    func legadoBookBridgeExportsMediaTypeRuntimeState() {
        let bridge = LegadoBookBridge(
            durChapterIndex: 2,
            durChapterTitle: "第 3 集",
            order: 1,
            type: 1,
            imageStyle: "FULL",
            name: "聚合聽書",
            author: "主播",
            coverUrl: "https://example.com/cover.jpg",
            abstract: "簡介"
        )

        let state = bridge.runtimeStateVariables()

        #expect(state["book.durChapterIndex"] == "2")
        #expect(state["book.durChapterTitle"] == "第 3 集")
        #expect(state["book.type"] == "1")
        #expect(state["book.imageStyle"] == "FULL")
        #expect(state["book.name"] == "聚合聽書")
        #expect(state["book.author"] == "主播")
    }

    @Test("LRUCache with capacity 1")
    func cacheCapacityOne() {
        let cache = LRUCache<String, Int>(capacity: 1)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == 2)
    }

    @Test("RuleAnalyzer with very long input")
    func longInput() {
        let long = String(repeating: "a", count: 1000) + "||" + String(repeating: "b", count: 1000)
        let analyzer = RuleAnalyzer(data: long)
        let result = analyzer.splitRule("||")
        #expect(result.count == 2)
        #expect(result[0].count == 1000)
        #expect(result[1].count == 1000)
    }

    @Test("CustomUrl with malformed JSON options")
    func customUrlMalformedJson() {
        let cu = CustomUrl(serialized: "https://example.com,{not json}")
        #expect(cu.url == "https://example.com")
        #expect(cu.attributes.isEmpty)
    }

    @Test("RegexReplacer preserves original on no match")
    func replacerNoMatch() {
        let result = RegexReplacer.replaceRegex(
            result: "hello world",
            pattern: "\\d+",
            replacement: "X",
            replaceFirst: false
        )
        #expect(result == "hello world")
    }

    @Test("JSONPath deep scan on flat object")
    func deepScanFlat() {
        let data: [String: Any] = ["key": "value"]
        let results = JSONPathEvaluator.query("$..key", on: data)
        #expect(results.first as? String == "value")
    }

    @Test("JSONPath negative slice")
    func negativeSlice() {
        let data: [String: Any] = ["arr": [1, 2, 3, 4, 5]]
        let results = JSONPathEvaluator.query("$.arr[-2:]", on: data)
        // Last two elements
        #expect(results.count == 2)
    }
}
