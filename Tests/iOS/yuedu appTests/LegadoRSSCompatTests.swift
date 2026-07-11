import Foundation
import Testing
@testable import yuedu_app

@Suite("Legado RSS compatibility", .serialized)
struct LegadoRSSCompatTests {

    // MARK: - sortUrl parsing

    @Test("sortUrl splits on newlines and && with name::url entries")
    func sortURLEntriesSplit() {
        let sortUrl = "书源::https://a.com/shuyuan\n订阅::https://a.com/rss&&异次元::https://a.com/acg"
        let entries = LegadoSortURLParser.entries(from: sortUrl, fallbackURL: "https://a.com")
        #expect(entries.count == 3)
        #expect(entries[0] == RSSSortEntry(name: "书源", url: "https://a.com/shuyuan"))
        #expect(entries[1] == RSSSortEntry(name: "订阅", url: "https://a.com/rss"))
        #expect(entries[2] == RSSSortEntry(name: "异次元", url: "https://a.com/acg"))
    }

    @Test("sortUrl entries without :: are ignored; empty falls back to source URL")
    func sortURLEntriesFallback() {
        let entries = LegadoSortURLParser.entries(from: "not-an-entry\n\n", fallbackURL: "https://fallback.example")
        #expect(entries == [RSSSortEntry(name: "", url: "https://fallback.example")])

        let nilEntries = LegadoSortURLParser.entries(from: nil, fallbackURL: "https://fallback.example")
        #expect(nilEntries == [RSSSortEntry(name: "", url: "https://fallback.example")])
    }

    @Test("sortUrl JS detection and body extraction")
    func sortURLJSDetection() {
        #expect(LegadoSortURLParser.needsJSEvaluation("@js:'a::1'"))
        #expect(LegadoSortURLParser.needsJSEvaluation("<js>result</js>"))
        #expect(!LegadoSortURLParser.needsJSEvaluation("名::https://x.com"))

        #expect(LegadoSortURLParser.jsBody("@js:'a'+'b'") == "'a'+'b'")
        #expect(LegadoSortURLParser.jsBody("<js>1+1</js>") == "1+1")
    }

    // MARK: - Import defaults

    @Test("import defaults singleUrl to false like Legado")
    func importSingleURLDefault() throws {
        let json = """
        [{"sourceName":"测试源","sourceUrl":"https://feed.example/rss.xml"}]
        """.data(using: .utf8)!
        let sources = try LegadoSourceJSONParser.parse(data: json)
        #expect(sources.count == 1)
        #expect(sources[0].singleUrl == false)
        #expect(sources[0].importedFromLegado == true)
    }

    @Test("import keeps explicit singleUrl and new round-trip fields")
    func importNewFields() throws {
        let json = """
        [{
          "sourceName": "源仓库",
          "sourceUrl": "https://yckceo.com/",
          "singleUrl": true,
          "ruleNextPage": "PAGE",
          "sourceComment": "comment",
          "style": ".a{color:red}",
          "injectJs": "console.log(1)",
          "contentWhitelist": "white",
          "contentBlacklist": "black",
          "loginUrl": "https://yckceo.com/login",
          "concurrentRate": "1/1000"
        }]
        """.data(using: .utf8)!
        let sources = try LegadoSourceJSONParser.parse(data: json)
        let source = try #require(sources.first)
        #expect(source.singleUrl == true)
        #expect(source.ruleNextPage == "PAGE")
        #expect(source.sourceComment == "comment")
        #expect(source.style == ".a{color:red}")
        #expect(source.injectJs == "console.log(1)")
        #expect(source.contentWhitelist == "white")
        #expect(source.contentBlacklist == "black")
        #expect(source.loginUrl == "https://yckceo.com/login")
        #expect(source.concurrentRate == "1/1000")
    }

    @Test("export round-trips new Legado fields")
    func exportRoundTrip() throws {
        let json = """
        [{
          "sourceName": "测试",
          "sourceUrl": "https://x.example/",
          "singleUrl": true,
          "ruleNextPage": "PAGE",
          "style": "body{}",
          "sortUrl": "a::https://x.example/a"
        }]
        """.data(using: .utf8)!
        let imported = try LegadoSourceJSONParser.parse(data: json)
        let exported = try LegadoSourceJSONParser.export(sources: imported)
        let reimported = try LegadoSourceJSONParser.parse(data: exported)
        let source = try #require(reimported.first)
        #expect(source.singleUrl == true)
        #expect(source.ruleNextPage == "PAGE")
        #expect(source.style == "body{}")
        #expect(source.sortUrl == "a::https://x.example/a")
    }

    // MARK: - Web-page source detection

    @Test("Legado singleUrl source without rules opens as web page")
    func opensAsWebPageForLegadoSingleURL() throws {
        let json = """
        [{"sourceName":"源仓库","sourceUrl":"https://yckceo.com/","singleUrl":true}]
        """.data(using: .utf8)!
        let source = try #require(try LegadoSourceJSONParser.parse(data: json).first)
        #expect(source.opensAsWebPage)
        #expect(source.webPageURL?.absoluteString == "https://yckceo.com/")
    }

    @Test("hand-added feed with legacy polluted singleUrl keeps feed behavior")
    func handAddedFeedNotWebPage() {
        // Old app versions defaulted singleUrl to true for every source.
        var source = RSSSource(name: "BBC", url: "https://feedx.net/rss/bbc.xml")
        source.singleUrl = true
        #expect(!source.opensAsWebPage)
    }

    @Test("singleUrl source with ruleArticles stays a rule-based list")
    func ruleBasedSourceNotWebPage() throws {
        let json = """
        [{"sourceName":"列表","sourceUrl":"https://x.example/","singleUrl":true,"ruleArticles":"$.data[*]"}]
        """.data(using: .utf8)!
        let source = try #require(try LegadoSourceJSONParser.parse(data: json).first)
        #expect(!source.opensAsWebPage)
        #expect(source.isLegadoRuleBased)
    }

    @Test("source with sortUrl categories is not a web page")
    func sortURLSourceNotWebPage() throws {
        let json = """
        [{"sourceName":"仓库","sourceUrl":"https://x.example/","singleUrl":true,"sortUrl":"a::https://x.example/a","ruleArticles":"$.data[*]"}]
        """.data(using: .utf8)!
        let source = try #require(try LegadoSourceJSONParser.parse(data: json).first)
        #expect(!source.opensAsWebPage)
        #expect(source.hasSortCategories)
    }

    // MARK: - URL normalization

    @Test("normalizedWebURL repairs scheme-less and option-suffixed URLs")
    func webURLNormalization() {
        #expect(RSSSource.normalizedWebURL(from: "shuyuan.nyasama.net")?.absoluteString == "https://shuyuan.nyasama.net")
        #expect(RSSSource.normalizedWebURL(from: "http://a.example/path")?.absoluteString == "https://a.example/path")
        #expect(RSSSource.normalizedWebURL(from: #"https://a.example/api,{"method":"POST"}"#)?.absoluteString == "https://a.example/api")
        #expect(RSSSource.normalizedWebURL(from: "不是网址") == nil)
        #expect(RSSSource.normalizedWebURL(from: "") == nil)
    }

    @Test("scraper request URL normalization keeps templates untouched")
    func requestURLNormalization() {
        #expect(LegadoRSSScraper.normalizedRequestURL("shuyuan.nyasama.net/feed") == "https://shuyuan.nyasama.net/feed")
        #expect(LegadoRSSScraper.normalizedRequestURL("https://a.example/x") == "https://a.example/x")
        #expect(LegadoRSSScraper.normalizedRequestURL("/relative/path") == "/relative/path")
        #expect(LegadoRSSScraper.normalizedRequestURL("@js:buildUrl()") == "@js:buildUrl()")
        #expect(LegadoRSSScraper.normalizedRequestURL("{{baseUrl}}/x") == "{{baseUrl}}/x")
        #expect(LegadoRSSScraper.normalizedRequestURL("a.example/list,{'method':'POST'}") == "https://a.example/list,{'method':'POST'}")
    }

    // MARK: - Storage backward compatibility

    @Test("RSSSource decodes storage written before the new fields existed")
    func decodesLegacyStorage() throws {
        // Field set exactly as persisted by the previous app version (no new
        // optional Legado fields).
        let legacyJSON = """
        [{
          "id": "ABC",
          "name": "旧源",
          "url": "https://old.example/rss",
          "sortOrder": 0,
          "enabled": true,
          "newArticleNotificationsEnabled": true,
          "articleStyle": 0,
          "customOrder": 0,
          "enableJs": true,
          "enabledCookieJar": false,
          "lastUpdateTime": 0,
          "loadWithBaseUrl": true,
          "singleUrl": true
        }]
        """.data(using: .utf8)!
        let sources = try JSONDecoder().decode([RSSSource].self, from: legacyJSON)
        #expect(sources.count == 1)
        #expect(sources[0].name == "旧源")
        #expect(sources[0].importedFromLegado == nil)
        // Legacy polluted singleUrl must not flip a plain feed into a web page.
        #expect(!sources[0].opensAsWebPage)
    }

    // MARK: - Rule engine wiring (parsing layer used by the scraper)

    @Test("ModernRuleEngine extracts RSS article fields from JSON APIs")
    func jsonRuleParsing() {
        let body = """
        {"data":{"list":[
          {"title":"文章一","url":"/article/1","time":"2026-07-01 08:00","img":"https://cdn.example/1.jpg"},
          {"title":"文章二","url":"/article/2","time":"2026-07-02 09:30","img":"https://cdn.example/2.jpg"}
        ]}}
        """
        let engine = ModernRuleEngine()
        engine.setContent(body, baseUrl: "https://api.example/feed")
        let elements = engine.getElements(ruleStr: "$.data.list[*]")
        #expect(elements.count == 2)

        engine.setContent(elements[0], baseUrl: "https://api.example/feed")
        #expect(engine.getString(ruleStr: "$.title") == "文章一")
        #expect(engine.getString(ruleStr: "$.url", isUrl: true) == "https://api.example/article/1")
        #expect(engine.getString(ruleStr: "$.img") == "https://cdn.example/1.jpg")
    }

    @Test("ModernRuleEngine extracts RSS article fields from HTML lists")
    func htmlRuleParsing() {
        let body = """
        <html><body>
          <div id="content">
            <div class="item"><h3><a href="/p/1">标题一</a></h3><span class="date">2026-07-01</span></div>
            <div class="item"><h3><a href="/p/2">标题二</a></h3><span class="date">2026-07-02</span></div>
          </div>
        </body></html>
        """
        let engine = ModernRuleEngine()
        engine.setContent(body, baseUrl: "https://site.example/list")
        let elements = engine.getElements(ruleStr: "id.content@class.item")
        #expect(elements.count == 2)

        engine.setContent(elements[1], baseUrl: "https://site.example/list")
        #expect(engine.getString(ruleStr: "h3@a@text") == "标题二")
        #expect(engine.getString(ruleStr: "a@href", isUrl: true) == "https://site.example/p/2")
        #expect(engine.getString(ruleStr: "class.date@text") == "2026-07-02")
    }
}
