import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

// MARK: - 1. Full Rule Pipeline Tests

@Suite("ModernRuleEngine Pipeline")
struct RuleEnginePipelineTests {

    // MARK: Helpers

    /// Build a fresh engine wired to a JSCoreEngine with variable storage.
    private func makeEngine(
        source: RuleDataInterface? = nil
    ) -> (engine: ModernRuleEngine, js: JSCoreEngine) {
        let engine = ModernRuleEngine()
        let jsEngine = JSCoreEngine()
        let ruleData = source ?? RuleData()
        engine.source = ruleData

        jsEngine.getData = { key in ruleData.getVariable(key: key) }
        jsEngine.putData = { key, val in ruleData.putVariable(key: key, value: val) }
        jsEngine.getStringHandler = { rule in engine.getString(ruleStr: rule) }
        jsEngine.getStringListHandler = { rule in engine.getStringList(ruleStr: rule) }

        engine.jsEvaluator = { script, result in
            if let r = result {
                return jsEngine.evaluate(script, result: ModernRuleEngine.toString(r))
            }
            return jsEngine.evaluate(script)
        }

        return (engine, jsEngine)
    }

    private let sampleHTML = """
    <html><body>
      <div class="book-list">
        <div class="item">
          <a class="title" href="/book/1">斗羅大陸</a>
          <span class="author">唐家三少</span>
          <img class="cover" src="/img/1.jpg"/>
        </div>
        <div class="item">
          <a class="title" href="/book/2">凡人修仙傳</a>
          <span class="author">忘語</span>
          <img class="cover" src="/img/2.jpg"/>
        </div>
        <div class="item">
          <a class="title" href="/book/3">盜墓筆記</a>
          <span class="author">南派三叔</span>
          <img class="cover" src="/img/3.jpg"/>
        </div>
      </div>
      <div class="content">
        <p>第一段正文</p>
        <p>廣告內容請忽略</p>
        <p>第二段正文</p>
      </div>
      <h1>頁面標題</h1>
    </body></html>
    """

    private let sampleJSON = """
    {
      "code": 200,
      "data": {
        "list": [
          {"name": "斗羅大陸", "author": "唐家三少", "url": "/book/1"},
          {"name": "凡人修仙傳", "author": "忘語", "url": "/book/2"},
          {"name": "盜墓筆記", "author": "南派三叔", "url": "/book/3"}
        ],
        "total": 3
      }
    }
    """

    // MARK: CSS Selector Tests

    @Test("CSS selector chain → text extraction")
    func cssTextExtraction() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "a.title@text")
        #expect(result == "斗羅大陸")
    }

    @Test("CSS selector → attribute extraction")
    func cssAttributeExtraction() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "a.title@href", isUrl: true)
        #expect(result == "https://example.com/book/1")
    }

    @Test("CSS selector → list extraction")
    func cssListExtraction() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getStringList(ruleStr: "div.item>a.title@text")
        #expect(result.count == 3)
        #expect(result[0] == "斗羅大陸")
        #expect(result[2] == "盜墓筆記")
    }

    @Test("CSS getElements returns list items")
    func cssGetElements() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let elements = engine.getElements(ruleStr: "div.item")
        #expect(elements.count == 3)
    }

    @Test("@CSS: explicit prefix works")
    func explicitCSSPrefix() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "@CSS:h1@text")
        #expect(result == "頁面標題")
    }

    // MARK: XPath Tests

    @Test("XPath → attribute extraction")
    func xpathAttributeExtraction() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "//a[@class='title']/@href", isUrl: true)
        #expect(result == "https://example.com/book/1")
    }

    @Test("XPath → text extraction")
    func xpathTextExtraction() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "//span[@class='author']/text()")
        #expect(result.contains("唐家三少"))
    }

    @Test("@XPath: explicit prefix")
    func explicitXPathPrefix() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "@XPath://h1/text()")
        #expect(result == "頁面標題")
    }

    // MARK: JSONPath Tests

    @Test("JSONPath on JSON content → single value")
    func jsonPathSingleValue() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleJSON, baseUrl: "https://api.example.com")
        let result = engine.getString(ruleStr: "$.data.list[0].name")
        #expect(result == "斗羅大陸")
    }

    @Test("JSONPath → list extraction")
    func jsonPathList() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleJSON, baseUrl: "https://api.example.com")
        let result = engine.getStringList(ruleStr: "$.data.list[*].name")
        #expect(result.count == 3)
        #expect(result.contains("凡人修仙傳"))
    }

    @Test("@Json: explicit prefix")
    func explicitJsonPrefix() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleJSON, baseUrl: "https://api.example.com")
        let result = engine.getString(ruleStr: "@Json:$.data.total")
        #expect(result == "3")
    }

    // MARK: Operator Tests (Legacy API)

    @Test("|| operator — first match wins")
    func orOperatorFirstMatchWins() throws {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = try engine.extractValue(
            from: sampleHTML, rule: "div.nonexistent@text||h1@text", baseURL: "https://example.com"
        )
        #expect(result == "頁面標題")
    }

    @Test("&& operator — concatenate results")
    func andOperatorConcatenates() throws {
        let (engine, _) = makeEngine()
        let result = try engine.extractValue(
            from: sampleJSON,
            rule: "$.data.list[0].name&&$.data.list[0].author",
            baseURL: ""
        )
        #expect(result.contains("斗羅大陸"))
        #expect(result.contains("唐家三少"))
    }

    @Test("|| operator for list — first non-empty list wins")
    func orOperatorForList() throws {
        let (engine, _) = makeEngine()
        let result = try engine.extractList(
            from: sampleJSON,
            rule: "$.data.missing[*].name||$.data.list[*].name",
            baseURL: ""
        )
        #expect(result.count == 3)
    }

    @Test("&& operator for list — merges lists")
    func andOperatorForList() throws {
        let (engine, _) = makeEngine()
        let result = try engine.extractList(
            from: sampleJSON,
            rule: "$.data.list[*].name&&$.data.list[*].author",
            baseURL: ""
        )
        #expect(result.count == 6)
    }

    // MARK: Regex Post-Processing

    @Test("## regex removes matching text")
    func regexRemoval() throws {
        let (engine, _) = makeEngine()
        let html = "<div class='title'>【校對版】斗羅大陸</div>"
        let result = try engine.extractValue(
            from: html, rule: "div.title@text##【.*?】##", baseURL: ""
        )
        #expect(result == "斗羅大陸")
    }

    @Test("## regex with replacement")
    func regexReplacement() throws {
        let (engine, _) = makeEngine()
        let html = "<span>price: 100元</span>"
        let result = try engine.extractValue(
            from: html, rule: "span@text##(\\d+)元##$1 CNY", baseURL: ""
        )
        #expect(result == "price: 100 CNY")
    }

    // MARK: JS Evaluation

    @Test("@js: evaluates with result variable")
    func jsEvalWithResult() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "h1@text@js:result + ' [已驗證]'")
        #expect(result == "頁面標題 [已驗證]")
    }

    @Test("<js> block evaluates inline")
    func jsBlockInline() {
        let (engine, _) = makeEngine()
        engine.setContent("hello", baseUrl: "")
        let result = engine.getString(ruleStr: "<js>result.toUpperCase()</js>")
        #expect(result == "HELLO")
    }

    @Test("JS mode with @js: prefix in SourceRule detection")
    func jsModeDetection() {
        let rule = SourceRule(ruleStr: "@js:1 + 2")
        #expect(rule.mode == .js)
        #expect(rule.rule == "1 + 2")
    }

    // MARK: Variable System

    @Test("put/get variable round trip via engine")
    func enginePutGetVariable() {
        let (engine, _) = makeEngine()
        engine.put(key: "testVar", value: "hello123")
        let result = engine.get(key: "testVar")
        #expect(result == "hello123")
    }

    @Test("Variable chain: source fallback")
    func variableChainFallback() {
        let src = RuleData()
        src.putVariable(key: "shared", value: "fromSource")
        let book = RuleData()

        let engine = ModernRuleEngine()
        engine.source = src
        engine.book = book

        // book doesn't have 'shared', should fall back to source
        let result = engine.get(key: "shared")
        #expect(result == "fromSource")
    }

    @Test("Variable chain: closer scope wins")
    func variableChainPriority() {
        let src = RuleData()
        src.putVariable(key: "key", value: "fromSource")
        let book = RuleData()
        book.putVariable(key: "key", value: "fromBook")

        let engine = ModernRuleEngine()
        engine.source = src
        engine.book = book

        let result = engine.get(key: "key")
        #expect(result == "fromBook")
    }

    // MARK: URL Resolution

    @Test("Relative URL resolves against baseUrl")
    func relativeUrlResolution() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "https://example.com/search")
        let result = engine.getString(ruleStr: "a.title@href", isUrl: true)
        #expect(result == "https://example.com/book/1")
    }

    @Test("Absolute URL passes through unchanged")
    func absoluteUrlPassthrough() {
        let (engine, _) = makeEngine()
        let html = "<a href='https://other.com/book'>Link</a>"
        engine.setContent(html, baseUrl: "https://example.com")
        let result = engine.getString(ruleStr: "a@href", isUrl: true)
        #expect(result == "https://other.com/book")
    }

    // MARK: Edge Cases

    @Test("Empty rule returns empty string")
    func emptyRuleReturnsEmpty() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "")
        let result = engine.getString(ruleStr: "")
        #expect(result == "")
    }

    @Test("Nil content returns empty string")
    func nilContentReturnsEmpty() {
        let (engine, _) = makeEngine()
        let result = engine.getString(ruleStr: "div@text")
        #expect(result == "")
    }

    @Test("Empty rule list returns empty array")
    func emptyRuleReturnsEmptyArray() {
        let (engine, _) = makeEngine()
        engine.setContent(sampleHTML, baseUrl: "")
        let result = engine.getStringList(ruleStr: "")
        #expect(result.isEmpty)
    }
}

// MARK: - 2. AnalyzeUrl Integration Tests

@Suite("AnalyzeUrl Pipeline")
struct AnalyzeUrlIntegrationTests {

    @Test("Simple GET URL parses correctly")
    func simpleGetUrl() {
        let analyze = AnalyzeUrl(ruleUrl: "https://api.example.com/search?q=test")
        #expect(analyze.url.contains("api.example.com"))
        #expect(analyze.method == "GET")
        #expect(analyze.body == nil)
    }

    @Test("POST with JSON options")
    func postWithOptions() {
        let ruleUrl = """
        https://api.example.com/search,{"method":"POST","body":"keyword=test","headers":{"X-Token":"abc123"}}
        """
        let analyze = AnalyzeUrl(ruleUrl: ruleUrl)
        #expect(analyze.method == "POST")
        #expect(analyze.headers["X-Token"] == "abc123")

        let request = analyze.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "X-Token") == "abc123")
    }

    @Test("URL with {{key}} template replacement")
    func urlKeyTemplate() {
        let analyze = AnalyzeUrl(
            ruleUrl: "https://api.example.com/search?q={{key}}",
            key: "斗羅大陸"
        )
        #expect(analyze.url.contains("斗羅大陸") || analyze.url.contains("%"))
    }

    @Test("URL with {{page}} template replacement")
    func urlPageTemplate() {
        let analyze = AnalyzeUrl(
            ruleUrl: "https://example.com/list?page={{page}}",
            page: 3
        )
        #expect(analyze.url.contains("3"))
    }

    @Test("URL with {{pageIndex}} template (0-based)")
    func urlPageIndexTemplate() {
        let analyze = AnalyzeUrl(
            ruleUrl: "https://example.com/list?idx={{pageIndex}}",
            page: 3
        )
        // pageIndex = page - 1 = 2
        #expect(analyze.url.contains("2"))
    }

    @Test("Page rules <p0,p1,p2> select by page index")
    func pageRuleSelection() {
        let a1 = AnalyzeUrl(ruleUrl: "https://example.com/<list,page2,page3>", page: 1)
        #expect(a1.url.contains("list"))

        let a2 = AnalyzeUrl(ruleUrl: "https://example.com/<list,page2,page3>", page: 2)
        #expect(a2.url.contains("page2"))

        let a3 = AnalyzeUrl(ruleUrl: "https://example.com/<list,page2,page3>", page: 3)
        #expect(a3.url.contains("page3"))
    }

    @Test("Relative URL resolution against baseUrl")
    func relativeUrlResolution() {
        let analyze = AnalyzeUrl(
            ruleUrl: "/search?q=test",
            baseUrl: "https://example.com/books"
        )
        #expect(analyze.url.hasPrefix("https://example.com"))
    }

    @Test("Protocol-relative URL gets https prefix")
    func protocolRelativeUrl() {
        let analyze = AnalyzeUrl(ruleUrl: "//cdn.example.com/img.jpg")
        #expect(analyze.url == "https://cdn.example.com/img.jpg")
    }

    @Test("toURLRequest builds valid request for GET")
    func toUrlRequestGet() {
        let analyze = AnalyzeUrl(ruleUrl: "https://api.example.com/books?page=1")
        let request = analyze.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.host?.contains("example.com") == true)
    }

    @Test("toURLRequest builds valid request for POST")
    func toUrlRequestPost() {
        let ruleUrl = """
        https://api.example.com/search,{"method":"POST","body":"q=test"}
        """
        let analyze = AnalyzeUrl(ruleUrl: ruleUrl)
        let request = analyze.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "POST")
        #expect(request?.httpBody != nil)
    }

    @Test("JSON options parse useWebView and webJs")
    func webViewOptions() {
        let ruleUrl = """
        https://example.com/page,{"useWebView":true,"webJs":"document.title","webViewDelayTime":3000}
        """
        let analyze = AnalyzeUrl(ruleUrl: ruleUrl)
        #expect(analyze.useWebView == true)
        #expect(analyze.webJs == "document.title")
        #expect(analyze.webViewDelayTime == 3000)
    }

    @Test("@get:{key} resolved from source RuleData")
    func getVariableFromSource() {
        let source = RuleData()
        source.putVariable(key: "domain", value: "example.com")
        let analyze = AnalyzeUrl(
            ruleUrl: "https://@get:{domain}/search",
            source: source
        )
        #expect(analyze.url.contains("example.com"))
    }

    @Test("Data URI detection")
    func dataUriDetection() {
        let dataUrl = "data:text/html;base64,PGgxPkhlbGxvPC9oMT4="
        let analyze = AnalyzeUrl(ruleUrl: dataUrl)
        #expect(analyze.isDataUri == true)
        let decoded = analyze.decodeDataUri()
        #expect(decoded != nil)
        #expect(decoded?.mimeType == "text/html")
    }

    @Test("Retry and charset parse from options")
    func retryAndCharset() {
        let ruleUrl = """
        https://example.com/book,{"charset":"gbk","retry":3}
        """
        let analyze = AnalyzeUrl(ruleUrl: ruleUrl)
        #expect(analyze.charset == "gbk")
        #expect(analyze.retry == 3)
    }
}

// MARK: - 3. JSCoreEngine Integration Tests

@Suite("JSCoreEngine Pipeline")
struct JSCoreEngineIntegrationTests {

    @Test("JS evaluation with result variable")
    func jsResultVariable() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("result + ' world'", result: "hello")
        #expect(result == "hello world")
    }

    @Test("JS evaluation with nil result sets NSNull")
    func jsNilResult() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("typeof result", result: nil)
        #expect(result == "object") // NSNull is an object in JS
    }

    @Test("java.base64Encode/Decode round trip")
    func base64RoundTrip() {
        let engine = JSCoreEngine()
        let encoded = engine.evaluate("java.base64Encode('Hello, 世界')")
        #expect(encoded != nil)
        let decoded = engine.evaluate("java.base64Decode('\(encoded!)')")
        #expect(decoded == "Hello, 世界")
    }

    @Test("java.put/get round trip")
    func javaPutGetRoundTrip() {
        var storage: [String: String] = [:]
        let engine = JSCoreEngine()
        engine.putData = { key, val in storage[key] = val }
        engine.getData = { key in storage[key] }

        engine.evaluate("java.put('myKey', 'myValue')")
        let result = engine.evaluate("java.get('myKey')")
        #expect(result == "myValue")
        #expect(storage["myKey"] == "myValue")
    }

    @Test("JS error sets lastError")
    func jsErrorHandling() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("undefinedFunction()")
        #expect(result == nil)
        #expect(engine.lastError != nil)
    }

    @Test("JS returns nil for undefined result")
    func jsUndefinedResult() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("undefined")
        #expect(result == nil)
        #expect(engine.lastError == nil)
    }

    @Test("JS string operations work")
    func jsStringOperations() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("""
            var s = '  Hello World  ';
            s.trim().replace('World', 'JS')
        """)
        #expect(result == "Hello JS")
    }

    @Test("JS evaluate with bindings")
    func jsBindings() {
        let engine = JSCoreEngine()
        let result = engine.evaluate(
            "name + ' - ' + String(page)",
            bindings: ["name": "BookTitle", "page": 5]
        )
        #expect(result == "BookTitle - 5")
    }

    @Test("JS array result serialized to JSON")
    func jsArrayResult() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("[1, 2, 3]")
        #expect(result != nil)
        #expect(result!.contains("1"))
        #expect(result!.contains("3"))
    }

    @Test("java.md5Encode produces 32-char hex")
    func md5Encode() {
        let engine = JSCoreEngine()
        let result = engine.evaluate("java.md5Encode('test')")
        #expect(result != nil)
        #expect(result!.count == 32)
    }

    @Test("JS reset clears state")
    func jsReset() {
        let engine = JSCoreEngine()
        engine.evaluate("var myVar = 42")
        let before = engine.evaluate("myVar")
        #expect(before == "42")

        engine.reset()
        let after = engine.evaluate("typeof myVar")
        #expect(after == "undefined")
    }

    @Test("java.getString wired to engine handler")
    func javaGetStringHandler() {
        let engine = JSCoreEngine()
        engine.getStringHandler = { rule in
            if rule == "test-rule" { return "extracted-value" }
            return nil
        }
        let result = engine.evaluate("java.getString('test-rule')")
        #expect(result == "extracted-value")
    }
}

// MARK: - 4. Multi-Extractor Routing Tests

@Suite("Extractor Routing")
struct ExtractorRoutingTests {

    private let html = """
    <html><body>
      <div class="title">Hello World</div>
      <a href="/page">Link</a>
    </body></html>
    """

    private let json = """
    {"title": "Hello", "items": [1, 2, 3]}
    """

    @Test("Auto-detect CSS mode (default for HTML)")
    func autoDetectCSS() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: html, rule: "div.title@text", baseURL: ""
        )
        #expect(result == "Hello World")
    }

    @Test("Auto-detect XPath mode (starts with //)")
    func autoDetectXPath() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: html, rule: "//div[@class='title']/text()", baseURL: ""
        )
        #expect(result.contains("Hello World"))
    }

    @Test("Auto-detect JSON mode (starts with $.)")
    func autoDetectJSON() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: json, rule: "$.title", baseURL: ""
        )
        #expect(result == "Hello")
    }

    @Test("@CSS: prefix routes to CSS extractor")
    func cssPrefix() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: html, rule: "@css:div.title@text", baseURL: ""
        )
        #expect(result == "Hello World")
    }

    @Test("@XPath: prefix routes to XPath extractor")
    func xpathPrefix() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: html, rule: "@xpath://a/@href", baseURL: ""
        )
        #expect(result == "/page")
    }

    @Test("@Json: prefix routes to JSON extractor")
    func jsonPrefix() throws {
        let engine = ModernRuleEngine()
        let result = try engine.extractValue(
            from: json, rule: "@json:$.title", baseURL: ""
        )
        #expect(result == "Hello")
    }

    @Test("SourceRule detects JS mode from @js: prefix")
    func jsPrefixDetection() {
        let rule = SourceRule(ruleStr: "@js:result.length")
        #expect(rule.mode == .js)
    }

    @Test("SourceRule detects JSON mode from $. prefix")
    func jsonPrefixDetection() {
        let rule = SourceRule(ruleStr: "$.data.name")
        #expect(rule.mode == .json)
    }

    @Test("SourceRule detects XPath mode from // prefix")
    func xpathPrefixDetection() {
        let rule = SourceRule(ruleStr: "//div/text()")
        #expect(rule.mode == .xpath)
    }

    @Test("SourceRule detects default mode for CSS")
    func cssDefaultMode() {
        let rule = SourceRule(ruleStr: "div.title@text")
        #expect(rule.mode == .default || rule.mode == .regex)
    }
}

// MARK: - 5. SourceRule Parsing Tests

@Suite("SourceRule Parsing")
struct SourceRuleParsingTests {

    @Test("Detects @get:{key} template")
    func getTemplate() {
        let rule = SourceRule(ruleStr: "div@text@get:{myKey}")
        #expect(rule.paramSize > 0)
    }

    @Test("Strips @put:{} directive and populates putMap")
    func putDirective() {
        let rule = SourceRule(ruleStr: "div@text@put:{\"title\":\"$.name\"}")
        #expect(rule.putMap["title"] == "$.name")
        #expect(!rule.rule.contains("@put"))
    }

    @Test("## splits regex pattern from rule")
    func regexSplit() {
        let rule = SourceRule(ruleStr: "div.content@text##廣告.*##")
        // Before makeUpRule, the ## part is still in rule.rule
        // After makeUpRule it gets split
        rule.makeUpRule(
            result: nil,
            getData: { _ in "" },
            evalJS: { _ in nil },
            analyzeRule: { _ in nil }
        )
        #expect(rule.replaceRegex == "廣告.*")
    }

    @Test("### sets replaceFirst flag")
    func replaceFirstFlag() {
        let rule = SourceRule(ruleStr: "div@text##pattern##replacement###")
        rule.makeUpRule(
            result: nil,
            getData: { _ in "" },
            evalJS: { _ in nil },
            analyzeRule: { _ in nil }
        )
        #expect(rule.replaceRegex == "pattern")
        #expect(rule.replacement == "replacement")
        #expect(rule.replaceFirst == true)
    }

    @Test("<js>...</js> detected as JS mode")
    func jsBlockMode() {
        let rule = SourceRule(ruleStr: "<js>result + 'x'</js>")
        #expect(rule.mode == .js)
        #expect(rule.rule == "result + 'x'")
    }
}

// MARK: - 6. Real-World Book Source Simulation

@Suite("Book Source Simulation")
struct BookSourceSimulationTests {

    /// Simulated search result HTML like a typical novel site
    private let searchResultHTML = """
    <html><body>
    <div id="search-results">
      <div class="result-item">
        <a class="book-name" href="/book/101">斗破蒼穹</a>
        <span class="book-author">天蠶土豆</span>
        <img class="book-cover" src="/covers/101.jpg"/>
        <p class="book-intro">一個少年從廢柴到天才的逆襲之路…</p>
      </div>
      <div class="result-item">
        <a class="book-name" href="/book/102">武動乾坤</a>
        <span class="book-author">天蠶土豆</span>
        <img class="book-cover" src="/covers/102.jpg"/>
        <p class="book-intro">大千世界，位面交匯…</p>
      </div>
    </div>
    </body></html>
    """

    /// Simulated TOC HTML
    private let tocHTML = """
    <html><body>
    <div id="chapter-list">
      <a class="chapter" href="/book/101/ch1">第一章 廢柴少年</a>
      <a class="chapter" href="/book/101/ch2">第二章 鬥氣大陸</a>
      <a class="chapter" href="/book/101/ch3">第三章 拍賣會</a>
    </div>
    </body></html>
    """

    /// Simulated chapter content
    private let chapterHTML = """
    <html><body>
    <div id="content">
      <p>蕭炎看著手中的殘卷，臉上浮現一絲苦笑。</p>
      <p class="ad">本章節由XX網提供</p>
      <p>「三十年河東，三十年河西，莫欺少年窮！」</p>
      <p class="ad">請支持正版閱讀</p>
      <p>少年抬起頭，目光堅定地望向遠方。</p>
    </div>
    </body></html>
    """

    /// Simulated JSON API search response
    private let searchJSON = """
    {
      "code": 0,
      "data": {
        "books": [
          {
            "name": "斗破蒼穹",
            "author": "天蠶土豆",
            "cover": "https://img.example.com/101.jpg",
            "url": "/api/book/101",
            "intro": "一個少年的逆襲"
          },
          {
            "name": "武動乾坤",
            "author": "天蠶土豆",
            "cover": "https://img.example.com/102.jpg",
            "url": "/api/book/102",
            "intro": "大千世界"
          }
        ]
      }
    }
    """

    @Test("Search: extract book list elements from HTML")
    func searchBookListElements() {
        let engine = ModernRuleEngine()
        engine.setContent(searchResultHTML, baseUrl: "https://example.com")
        let elements = engine.getElements(ruleStr: "div.result-item")
        #expect(elements.count == 2)
    }

    @Test("Search: extract book names from each element")
    func searchBookNames() {
        let engine = ModernRuleEngine()
        engine.setContent(searchResultHTML, baseUrl: "https://example.com")
        let names = engine.getStringList(ruleStr: "div.result-item>a.book-name@text")
        #expect(names.count == 2)
        #expect(names[0] == "斗破蒼穹")
        #expect(names[1] == "武動乾坤")
    }

    @Test("Search: extract book URLs with base resolution")
    func searchBookUrls() {
        let engine = ModernRuleEngine()
        engine.setContent(searchResultHTML, baseUrl: "https://example.com")
        let urls = engine.getStringList(
            ruleStr: "div.result-item>a.book-name@href", isUrl: true
        )
        #expect(urls.count == 2)
        #expect(urls[0] == "https://example.com/book/101")
        #expect(urls[1] == "https://example.com/book/102")
    }

    @Test("Search: extract authors")
    func searchAuthors() {
        let engine = ModernRuleEngine()
        engine.setContent(searchResultHTML, baseUrl: "https://example.com")
        let authors = engine.getStringList(ruleStr: "span.book-author@text")
        #expect(authors.count == 2)
        #expect(authors[0] == "天蠶土豆")
    }

    @Test("TOC: extract chapter list")
    func tocChapterList() {
        let engine = ModernRuleEngine()
        engine.setContent(tocHTML, baseUrl: "https://example.com")
        let chapters = engine.getStringList(ruleStr: "a.chapter@text")
        #expect(chapters.count == 3)
        #expect(chapters[0] == "第一章 廢柴少年")
    }

    @Test("TOC: extract chapter URLs")
    func tocChapterUrls() {
        let engine = ModernRuleEngine()
        engine.setContent(tocHTML, baseUrl: "https://example.com")
        let urls = engine.getStringList(ruleStr: "a.chapter@href", isUrl: true)
        #expect(urls.count == 3)
        #expect(urls[0] == "https://example.com/book/101/ch1")
    }

    @Test("Content: extract paragraphs filtering ads with regex")
    func contentWithAdFiltering() throws {
        let engine = ModernRuleEngine()
        // Use legacy API to extract and filter ad content
        let result = try engine.extractValue(
            from: chapterHTML,
            rule: "#content@text##本章節由.*?提供|請支持正版閱讀##",
            baseURL: "https://example.com"
        )
        #expect(!result.contains("本章節由"))
        #expect(!result.contains("請支持正版閱讀"))
        #expect(result.contains("蕭炎"))
    }

    @Test("JSON API: extract book names via JSONPath")
    func jsonApiBookNames() {
        let engine = ModernRuleEngine()
        engine.setContent(searchJSON, baseUrl: "https://api.example.com")
        let names = engine.getStringList(ruleStr: "$.data.books[*].name")
        #expect(names == ["斗破蒼穹", "武動乾坤"])
    }

    @Test("JSON API: extract single book info")
    func jsonApiSingleBook() {
        let engine = ModernRuleEngine()
        engine.setContent(searchJSON, baseUrl: "https://api.example.com")
        let name = engine.getString(ruleStr: "$.data.books[0].name")
        let author = engine.getString(ruleStr: "$.data.books[0].author")
        let cover = engine.getString(ruleStr: "$.data.books[0].cover")
        #expect(name == "斗破蒼穹")
        #expect(author == "天蠶土豆")
        #expect(cover == "https://img.example.com/101.jpg")
    }

    @Test("Full pipeline: AnalyzeUrl → engine extraction (simulated)")
    func fullPipelineSimulation() {
        // 1. Parse search URL
        let analyzeUrl = AnalyzeUrl(
            ruleUrl: "https://example.com/search?q={{key}}&page={{page}}",
            key: "斗破蒼穹",
            page: 1,
            baseUrl: "https://example.com"
        )
        let request = analyzeUrl.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "GET")

        // 2. Simulate receiving HTML response → set as content
        let engine = ModernRuleEngine()
        engine.setContent(searchResultHTML, baseUrl: "https://example.com")

        // 3. Extract book list
        let elements = engine.getElements(ruleStr: "div.result-item")
        #expect(elements.count == 2)

        // 4. Extract fields from first element
        let firstElement = elements[0]
        let nameEngine = ModernRuleEngine()
        nameEngine.setContent(firstElement, baseUrl: "https://example.com")
        let name = nameEngine.getString(ruleStr: "a.book-name@text")
        let bookUrl = nameEngine.getString(ruleStr: "a.book-name@href", isUrl: true)

        #expect(name == "斗破蒼穹")
        #expect(bookUrl == "https://example.com/book/101")
    }

    @Test("Full pipeline with JS post-processing")
    func pipelineWithJsPostProcessing() {
        let engine = ModernRuleEngine()
        let jsEngine = JSCoreEngine()
        engine.jsEvaluator = { script, result in
            if let r = result {
                return jsEngine.evaluate(script, result: ModernRuleEngine.toString(r))
            }
            return jsEngine.evaluate(script)
        }

        engine.setContent(searchResultHTML, baseUrl: "https://example.com")
        // Extract name and transform with JS
        let result = engine.getString(
            ruleStr: "a.book-name@text@js:result.replace('斗破蒼穹', '鬥破蒼穹')"
        )
        #expect(result == "鬥破蒼穹")
    }

    @Test("Search URL with AnalyzeUrl template and options")
    func searchUrlTemplateWithOptions() {
        let ruleUrl = """
        https://api.example.com/search?q={{key}}&page={{page}},{"method":"POST","headers":{"Content-Type":"application/json"}}
        """
        let analyze = AnalyzeUrl(ruleUrl: ruleUrl, key: "test", page: 2)
        #expect(analyze.method == "POST")
        #expect(analyze.headers["Content-Type"] == "application/json")
        let request = analyze.toURLRequest()
        #expect(request != nil)
    }
}

// MARK: - 7. Cross-Component Wiring Tests

@Suite("Cross-Component Wiring")
struct CrossComponentWiringTests {

    @Test("JS java.put → engine.get round trip")
    func jsPutEngineGet() {
        let ruleData = RuleData()
        let engine = ModernRuleEngine()
        engine.source = ruleData

        let jsEngine = JSCoreEngine()
        jsEngine.putData = { key, val in ruleData.putVariable(key: key, value: val) }
        jsEngine.getData = { key in ruleData.getVariable(key: key) }

        // Store via JS
        jsEngine.evaluate("java.put('testKey', 'testValue')")

        // Retrieve via engine
        let result = engine.get(key: "testKey")
        #expect(result == "testValue")
    }

    @Test("JS java.getString delegates to engine extraction")
    func jsGetStringDelegation() {
        let html = "<span class='info'>重要資訊</span>"
        let engine = ModernRuleEngine()
        engine.setContent(html, baseUrl: "")

        let jsEngine = JSCoreEngine()
        jsEngine.getStringHandler = { rule in
            engine.getString(ruleStr: rule)
        }

        let result = jsEngine.evaluate("java.getString('span.info@text')")
        #expect(result == "重要資訊")
    }

    @Test("BookSourceRuleData stores and retrieves variables")
    func bookSourceRuleDataVariables() {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "Test")
        let ruleData = BookSourceRuleData(source: source)

        ruleData.putVariable(key: "token", value: "abc123")
        let result = ruleData.getVariable(key: "token")
        #expect(result == "abc123")
    }

    @Test("RuleData serialization round trip")
    func ruleDataSerialization() {
        let data = RuleData()
        data.putVariable(key: "a", value: "1")
        data.putVariable(key: "b", value: "2")

        let json = data.getVariableJSON()
        #expect(json != nil)

        let restored = RuleData()
        restored.loadVariables(from: json)
        #expect(restored.getVariable(key: "a") == "1")
        #expect(restored.getVariable(key: "b") == "2")
    }

    @Test("Engine splitSourceRule handles mixed JS and CSS")
    func splitSourceRuleMixed() {
        let engine = ModernRuleEngine()
        let rules = engine.splitSourceRule("div.title@text@js:result + ' end'")
        #expect(rules.count == 2)
        #expect(rules[0].mode == .default || rules[0].mode == .regex)
        #expect(rules[1].mode == .js)
    }

    @Test("Engine splitSourceRule handles <js> blocks")
    func splitSourceRuleJsBlock() {
        let engine = ModernRuleEngine()
        let rules = engine.splitSourceRule("h1@text<js>result.trim()</js>")
        #expect(rules.count == 2)
        #expect(rules[1].mode == .js)
        #expect(rules[1].rule == "result.trim()")
    }
}
