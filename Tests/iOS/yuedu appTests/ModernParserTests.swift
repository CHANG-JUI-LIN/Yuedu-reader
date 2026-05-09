import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

// MARK: - 1. RuleAnalyzer Tests

@Suite("RuleAnalyzer")
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

// MARK: - 2. SourceRule Tests

@Suite("SourceRule")
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

@Suite("RegexExtractor")
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

@Suite("JSONPathEvaluator")
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

@Suite("JsonExtractor")
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

@Suite("LRUCache")
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

@Suite("RegexCache")
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

@Suite("SelectorCache")
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

@Suite("RuleData")
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

// MARK: - 7. AnalyzeUrl Tests

@Suite("AnalyzeUrl")
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
}

@Suite("CustomUrl")
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

@Suite("JSCoreEngine")
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
}

// MARK: - 9. JSSandbox Tests

@Suite("JSSandbox")
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

@Suite("LoginState")
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

@Suite("LoginError")
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

@Suite("LegadoJSBridge")
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

// MARK: - 12. Integration: RuleAnalyzer + SourceRule

@Suite("RuleAnalyzer + SourceRule Integration")
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

// MARK: - 13. Edge Cases & Stress Tests

@Suite("Edge Cases")
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
