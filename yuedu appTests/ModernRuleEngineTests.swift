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

        #expect(modern == legacy)
        #expect(modern == "https://example.com/book/1")
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

        let legacy = RuleEngine.routeExtractValue(content: html, baseURL: baseURL, rule: rule)
        let modern = try ModernRuleEngine().extractValue(from: html, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern.contains("第一段"))
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
        let rule = "@xpath://li/a@href"

        let legacy = RuleEngine.extractValueList(fromHTML: html, rule: rule, baseURL: baseURL)
        let modern = try ModernRuleEngine().extractList(from: html, rule: rule, baseURL: baseURL)

        #expect(modern == legacy)
        #expect(modern.count == 2)
        #expect(modern[0] == "https://example.com/ch/1")
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

    @Test
    func facadeCanSwitchToModernEngineForValueExtraction() {
        let html = "<p class='title'>標題</p>"
        let baseURL = "https://example.com"
        let rule = "@css:p.title@text"
        let originalMode = DefaultWebNovelParserService.extractionMode
        defer {
            DefaultWebNovelParserService.extractionMode = originalMode
        }

        DefaultWebNovelParserService.extractionMode = .native
        let nativeResult = DefaultWebNovelParserService.shared.extractValue(
            fromHTML: html,
            rule: rule,
            baseURL: baseURL
        )

        DefaultWebNovelParserService.extractionMode = .modern
        let modernResult = DefaultWebNovelParserService.shared.extractValue(
            fromHTML: html,
            rule: rule,
            baseURL: baseURL
        )

        #expect(modernResult == nativeResult)
        #expect(modernResult == "標題")
    }

    @Test
    func facadeCanSwitchToModernEngineForListExtraction() throws {
        let html = """
        <html><body>
          <div class='book'>A</div>
          <div class='book'>B</div>
        </body></html>
        """
        let baseURL = "https://example.com"
        let rule = "@css:div.book@text"
        let source = BookSource(
            bookSourceUrl: baseURL,
            bookSourceName: "測試書源"
        )

        let originalMode = DefaultWebNovelParserService.extractionMode
        defer { DefaultWebNovelParserService.extractionMode = originalMode }

        DefaultWebNovelParserService.extractionMode = .native
        let native = try DefaultWebNovelParserService.shared.extractStringList(
            html: html,
            baseURL: baseURL,
            rule: rule,
            source: source,
            runtimeVariables: nil,
            isURL: false
        )

        DefaultWebNovelParserService.extractionMode = .modern
        let modern = try DefaultWebNovelParserService.shared.extractStringList(
            html: html,
            baseURL: baseURL,
            rule: rule,
            source: source,
            runtimeVariables: nil,
            isURL: false
        )

        #expect(modern == native)
        #expect(modern == ["A", "B"])
    }

    @Test
    func facadeModernListExtractionHonorsIsURL() throws {
        let html = """
        <html><body>
          <a class='chapter' href='/ch/1'>章節1</a>
          <a class='chapter' href='/ch/2'>章節2</a>
        </body></html>
        """
        let baseURL = "https://example.com/book"
        let rule = "@css:a.chapter@href"
        let source = BookSource(bookSourceUrl: baseURL, bookSourceName: "測試書源")

        let originalMode = DefaultWebNovelParserService.extractionMode
        defer { DefaultWebNovelParserService.extractionMode = originalMode }

        DefaultWebNovelParserService.extractionMode = .modern
        let modern = try DefaultWebNovelParserService.shared.extractStringList(
            html: html,
            baseURL: baseURL,
            rule: rule,
            source: source,
            runtimeVariables: nil,
            isURL: true
        )

        #expect(modern == ["https://example.com/ch/1", "https://example.com/ch/2"])
    }
}
