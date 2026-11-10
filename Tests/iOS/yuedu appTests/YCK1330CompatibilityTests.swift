import Foundation
import JavaScriptCore
import os
import Security
import Testing
import SwiftSoup
@testable import yuedu_app

/// The shared-pipeline gaps from the YCK1330 compatibility report
/// (`Technotes/Diagnostics/2026-11-05-YCK1330-source-compatibility.md`): each test pins what
/// Legado (legado-E / MD3) does for a call a source in that pack makes.
@Suite("YCK1330 source compatibility", .serialized)
struct YCK1330CompatibilityTests {

    // MARK: - Elements keep their identity between rule steps

    /// 全本小說網 (`www.qbxs.net`): a search list of table rows. Re-parsing each row's outer
    /// HTML as a page dropped every `<td>`, so all 100 books were discarded.
    @Test("table-row list items keep their cells for the field rules")
    func tableRowsKeepCells() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://qbxs.test"
        source.bookSourceName = "qbxs fixture"
        source.ruleSearch.bookList = "class.grid@tag.tr!0"
        source.ruleSearch.name = "tag.td.0@tag.a@text"
        source.ruleSearch.bookUrl = "tag.td.0@tag.a@href"
        source.ruleSearch.author = "tag.td.2@text"
        let html = """
        <table class="grid"><tbody>
        <tr><th>書名</th><th>最新</th><th>作者</th></tr>
        <tr><td><a href="/book/1">第一本</a></td><td>第10章</td><td>甲</td></tr>
        <tr><td><a href="/book/2">第二本</a></td><td>第20章</td><td>乙</td></tr>
        </tbody></table>
        """
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://qbxs.test/search", source: source
        )
        #expect(books.map(\.name) == ["第一本", "第二本"])
        #expect(books.map(\.author) == ["甲", "乙"])
        #expect(books.map(\.bookUrl) == ["https://qbxs.test/book/1", "https://qbxs.test/book/2"])
    }

    @Test("a JS field rule receives the list item as a jsoup Element")
    func jsFieldRuleReadsElement() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://element.test"
        source.ruleSearch.bookList = "tag.tr"
        source.ruleSearch.name = "@js:result.select('td a').text()"
        source.ruleSearch.bookUrl = "@js:result.selectFirst('a').attr('href')"
        source.ruleSearch.author = "@js:java.getElements('tag.td')[1].text()"
        let html = #"<table><tr><td><a href="/b/9">名</a></td><td>作者甲</td></tr></table>"#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://element.test/s", source: source
        )
        #expect(books.first?.name == "名")
        #expect(books.first?.author == "作者甲")
        #expect(books.first?.bookUrl == "https://element.test/b/9")
    }

    /// 八叉书库: `java.getElement(…).attr("href")` for a link the page lacks threw
    /// `zxe.attr is not a function` — the empty selection reached the script as an array.
    /// Legado's `AnalyzeRule.getElement(s)` answers jsoup's `Elements` for a CSS rule even when
    /// nothing matched. Expected values: Rhino 1.8.1 + jsoup 1.16.2, oracle case file
    /// `empty-elements.json` (cases "empty Elements.attr is an empty string", "empty Elements:
    /// size, isEmpty, text, html, first", "empty Elements.select and hasClass").
    @Test("java.getElement and java.getElements hand a script an empty Elements when nothing matched")
    func emptyJsoupSelectionIsElements() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://empty-selection.test"
        source.ruleSearch.bookList = "tag.tr"
        source.ruleSearch.name = """
        @js:var e = java.getElement('h3 a');
        ['[' + e.attr('href') + ']', e.size(), e.isEmpty(), '[' + e.text() + ']', '[' + e.html() + ']', e.first()].join('|')
        """
        source.ruleSearch.author = """
        @js:var e = java.getElements('span');
        [e.size(), e.select('a').size(), e.hasClass('a'), e.hasAttr('href')].join('|')
        """
        source.ruleSearch.bookUrl = "tag.a@href"
        let html = #"<table><tr><td><a href="/b/1">名</a></td></tr></table>"#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://empty-selection.test/s", source: source
        )
        #expect(books.first?.name == "[]|0|true|[]|[]|")
        #expect(books.first?.author == "0|0|false|false")
    }

    /// 八叉书库: a page the script fetched itself is read with
    /// `Packages.io.legado.app.model.analyzeRule.AnalyzeRule().setContent(page).getElement(rule)`,
    /// which threw UnsupportedLegadoAPIError. Legado (legado-E `AnalyzeRule.kt`, visible to
    /// scripts through `RhinoClassShutter`): the no-argument reader reads only what it is given —
    /// `setContent` returns the reader, `getElement` a CSS rule's jsoup `Elements`,
    /// `getString(rule, mContent)` the content of that call. Its own `@js:` step leaves the
    /// calling step's `java` reading the calling step's row.
    @Test("a script's own AnalyzeRule() reads the content it is given")
    func scriptAnalyzeRuleReadsItsContent() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://analyze-rule.test"
        source.ruleSearch.bookList = "tag.tr"
        source.ruleSearch.name = """
        @js:var AR = Packages.io.legado.app.model.analyzeRule.AnalyzeRule;
        var page = '<div class="divbox"><h3><a href="/b/7">最新</a></h3></div>';
        var e = AR().setContent(page).getElement('.divbox h3 a||span.x');
        [e.attr('href'), e.size(), AR().getString('h3@text', page),
         AR().setContent(page).getStringList('a@href').length, AR().getString("@js:'in'", page),
         java.getString('tag.td@text')].join('|')
        """
        source.ruleSearch.bookUrl = "tag.a@href"
        let html = #"<table><tr><td><a href="/b/1">名</a></td></tr></table>"#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://analyze-rule.test/s", source: source
        )
        #expect(books.first?.name == "/b/7|1|最新|1|in|名")
    }

    /// 群小说: `ruleBookInfo.init` of `@put:{…}` plus a selector. The old raw-JS fallback
    /// evaluated it as script — `SyntaxError: Invalid character '@'`.
    @Test("a ruleBookInfo.init with @put selects content and stores the variable")
    func bookInfoInitWithPut() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://init.test"
        source.ruleBookInfo.initScript = #"@put:{bid:"class.bid@text"}class.info"#
        source.ruleBookInfo.name = "tag.h1@text"
        source.ruleBookInfo.author = "@get:{bid}"
        let html = #"<div class="bid">B-42</div><div class="info"><h1>書名甲</h1></div><h1>頁外</h1>"#
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: html, bookUrl: "https://init.test/b", baseURL: "https://init.test/b", source: source
        )
        #expect(book.name == "書名甲")
        #expect(book.author == "B-42")
    }

    /// 万象书城 / 夜伴书屋: several bare keys in one `@put`, read leniently as GSON does.
    @Test("an @put block with bare keys stores every variable")
    func putWithBareKeys() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://bare-put.test"
        source.ruleBookInfo.initScript =
            "@put:{n:\"[property$=book_name]@content\", \ta:\"[property$=author]@content\"}"
        source.ruleBookInfo.name = "@get:{n}"
        source.ruleBookInfo.author = "@get:{a}"
        let html = """
        <meta property="og:novel:book_name" content="書名乙"><meta property="og:novel:author" content="作者乙">
        """
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: html, bookUrl: "https://bare-put.test/b", baseURL: "https://bare-put.test/b", source: source
        )
        #expect(book.name == "書名乙")
        #expect(book.author == "作者乙")
    }

    // MARK: - jsoup DOM in source JS

    @Test("jsoup mutators edit the tree a script reads back")
    func jsoupMutators() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var doc = org.jsoup.Jsoup.parse('<div id="c"><p class="ad">廣告</p><p>正文</p><span>x</span></div>');
        doc.select('.ad').remove();
        doc.select('span').attr('data-k', 'v');
        var p = doc.selectFirst('p');
        [doc.select('#c').html().replace(/\\s+/g, ''), p.nextElementSibling().attr('data-k'),
         doc.select('p').size(), new org.jsoup.select.Elements().size(),
         doc.selectFirst('#c').attributes().get('id')].join('|');
        """)
        #expect(value == #"<p>正文</p><spandata-k="v">x</span>|v|1|0|c"#)
        #expect(engine.lastError == nil)
    }

    // MARK: - Java / Android classes

    @Test("MessageDigest, URLEncoder, Charset, TextUtils and Thread under Packages")
    func javaClasses() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var md = Packages.java.security.MessageDigest.getInstance('MD5');
        md.update(new Packages.java.lang.String('abc').getBytes('UTF-8'));
        var hex = md.digest().map(function (b) { return ((b & 255) < 16 ? '0' : '') + (b & 255).toString(16); }).join('');
        var cs = Packages.java.nio.charset.Charset.forName('ISO-8859-1');
        Packages.java.lang.Thread.sleep(1);
        [hex,
         Packages.java.net.URLEncoder.encode('a b&中', 'UTF-8'),
         Packages.java.net.URLEncoder.encode('中', 'GBK'),
         Packages.java.net.URLDecoder.decode('a+b%26%E4%B8%AD', 'UTF-8'),
         String(new Packages.java.lang.String([0xe9], cs)),
         Packages.android.text.TextUtils.isEmpty(''), Packages.android.text.TextUtils.isEmpty('x')].join('|');
        """)
        #expect(value == "900150983cd24fb0d6963f7d28e17f72|a+b%26%E4%B8%AD|%D6%D0|a b&中|é|true|false")
        #expect(engine.lastError == nil)
    }

    /// 桔纸书屋 / 台湾小说网: `Packages.org.jsoup.Jsoup` is the same jsoup as `org.jsoup`.
    @Test("Packages.org.jsoup reaches the jsoup polyfill")
    func packagesJsoupAlias() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        Packages.org.jsoup.Jsoup.parse('<p>x</p><p>y</p>').select('p').text();
        """)
        #expect(value == "x y")
        #expect(engine.lastError == nil)
    }

    /// Legado joins links with Java's `new URL(base, spec)`, which keeps the characters as
    /// written and resolves only `.` / `..`; a `charset` option then encodes them on the request.
    @Test("a relative link resolves as Java's URL(base, spec) does")
    func javaRelativeURLResolution() {
        let base = "https://h.test/a/b/c.html?q=1#f"
        #expect(AnalyzeUrl.javaAbsoluteURL("d.html", base: base) == "https://h.test/a/b/d.html")
        #expect(AnalyzeUrl.javaAbsoluteURL("../d?k=搜索", base: base) == "https://h.test/a/d?k=搜索")
        #expect(AnalyzeUrl.javaAbsoluteURL("./../../../d", base: base) == "https://h.test/../d")
        #expect(AnalyzeUrl.javaAbsoluteURL("/s.php?key=我的", base: base) == "https://h.test/s.php?key=我的")
        #expect(AnalyzeUrl.javaAbsoluteURL("?p=2", base: base) == "https://h.test/a/b/c.html?p=2")
        #expect(AnalyzeUrl.javaAbsoluteURL("#top", base: base) == "https://h.test/a/b/c.html?q=1#top")
        #expect(AnalyzeUrl.javaAbsoluteURL("", base: base) == "https://h.test/a/b/c.html?q=1")
        #expect(AnalyzeUrl.javaAbsoluteURL("//cdn.test/x.jpg", base: "http://h.test/") == "http://cdn.test/x.jpg")
        #expect(AnalyzeUrl.javaAbsoluteURL("x", base: "https://h.test") == "https://h.test/x")
        #expect(AnalyzeUrl.javaAbsoluteURL("dir/", base: "https://h.test/a/,{\"charset\":\"gbk\"}")
            == "https://h.test/a/dir/")
        #expect(AnalyzeUrl.javaAbsoluteURL("javascript:void(0)", base: base) == "javascript:void(0)")
        #expect(AnalyzeUrl.javaAbsoluteURL("x", base: "not a url") == nil)
    }

    /// Legado's `java.encodeURI` is Java's `URLEncoder.encode(str, enc)`: a form encoder in
    /// the charset given. 民间故事 (index 28) searches with `{{java.encodeURI(key,'gb2312')}}`.
    @Test("java.encodeURI is URLEncoder.encode, in the charset given")
    func javaEncodeURICharset() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        [java.encodeURI('我的'), java.encodeURI('我的', 'gb2312'), java.encodeURI('a b/c?d=1&e+f~*'),
         java.encodeURI('x', 'no-such-charset')].join('|');
        """)
        #expect(value == "%E6%88%91%E7%9A%84|%CE%D2%B5%C4|a+b%2Fc%3Fd%3D1%26e%2Bf%7E*|")
        #expect(engine.lastError == nil)
    }

    /// Legado's `java.put` and `source.put` return the value they store: 晋江 (index 109) searches
    /// with `keyword={{key;java.put("key",key)}}`.
    @Test("java.put and source.put return the value they store")
    func putReturnsValue() {
        let engine = JSCoreEngine()
        let store = OSAllocatedUnfairLock(initialState: [String: String]())
        engine.getData = { key in store.withLock { $0[key] } }
        engine.putData = { key, value in store.withLock { $0[key] = value } }
        let value = engine.evaluate("""
        var key = '我的'; var page = 2;
        [(key, java.put('key', key)), source.put('p', String(page)), java.get('key')].join('|');
        """)
        #expect(value == "我的|2|我的")
        #expect(engine.lastError == nil)
    }

    /// Rhino hands a page to the script as a string; Linpx (index 95) tests its JSON detail
    /// page with `result.startsWith("<!DOCTYPE html>")` before parsing it.
    @Test("a JSON page given to a script still answers the string methods")
    func jsonResultAnswersStringMethods() {
        let engine = JSCoreEngine()
        let object = engine.evaluate("""
        [result.startsWith('<!DOCTYPE html>'), result.startsWith('{"a"'), result.a.b,
         JSON.parse(result).a.b, String(result).length, Object.keys(result).join(','),
         result.indexOf('"b"')].join('|');
        """, result: #"{"a":{"b":7}}"#)
        #expect(object == #"false|true|7|7|13|a|6"#)
        let array = engine.evaluate("[result.indexOf(2), result.length].join('|');", result: "[1,2]")
        #expect(array == "1|2")
        #expect(engine.lastError == nil)
    }

    @Test("StrResponse is callable with or without new, and answers raw() and callTime()")
    func strResponseConstructor() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var S = Packages.io.legado.app.help.http.StrResponse;
        var a = new S('https://a.test/x', 'body-a');
        var b = S('https://b.test/y', 'body-b');
        [a.body(), b.body(), a.raw().request().url(), a.callTime(), a.raw().code(),
         a.header('X-None') === null].join('|');
        """)
        #expect(value == "body-a|body-b|https://a.test/x|0|200|true")
        #expect(engine.lastError == nil)
    }

    /// Legado's StrResponse has `val url` / `var body` beside `url()` / `body()`; a loginCheckJs
    /// writes `String(result.url).replace(…)` and a rule `JSON.parse(result.body)`.
    @Test("a response's url and body read as properties and as calls")
    func strResponseURLAndBodyProperties() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var r = Packages.io.legado.app.help.http.StrResponse('https://a.test/search?q=1', '{"n":7}');
        [String(r.url).replace('/search', '/verified'), r.url(), r.url + '', r.url.indexOf('q=1') > 0,
         JSON.parse(r.body).n, r.body(), r.body.length, r.url == 'https://a.test/search?q=1',
         JSON.stringify({u: r.url})].join('|');
        """)
        #expect(value == #"https://a.test/verified?q=1|https://a.test/search?q=1|https://a.test/search?q=1|true|7|{"n":7}|7|true|{"u":"https://a.test/search?q=1"}"#)
        #expect(engine.lastError == nil)
    }

    // MARK: - URL template order

    /// legado-E replaces `{{…}}` before the page rule: a `<` inside the JS (黄果短劇) must not
    /// be read as the start of a page rule.
    @Test("{{js}} with a comparison resolves before the <…> page rule")
    func templateBeforePageRule() {
        let engine = JSCoreEngine()
        let evaluator: (String, [String: Any]) -> String? = { code, bindings in
            engine.evaluate(code, result: nil, bindings: bindings)
        }
        let rule = "https://h.test/s?p={{page<2?'first':'more'}}<,&n={{page}}>"
        #expect(AnalyzeUrl(ruleUrl: rule, page: 1, jsEvaluator: evaluator).url == "https://h.test/s?p=first")
        #expect(AnalyzeUrl(ruleUrl: rule, page: 2, jsEvaluator: evaluator).url == "https://h.test/s?p=more&n=2")
    }

    @Test("a page rule list is indexed by page and keeps its last item after the end")
    func pageRuleList() {
        let rule = "https://h.test/<a,b,c>.html"
        #expect(AnalyzeUrl(ruleUrl: rule, page: 1).url == "https://h.test/a.html")
        #expect(AnalyzeUrl(ruleUrl: rule, page: 2).url == "https://h.test/b.html")
        #expect(AnalyzeUrl(ruleUrl: rule, page: 5).url == "https://h.test/c.html")
    }

    // MARK: - Request parameters go out in the source's charset (11-06 report §1)

    /// 新御书屋3, 桔纸书屋, po18城, 笔趣阁: a GBK site answered a UTF-8 keyword with zero books.
    @Test("a charset option encodes the query and the form body in that charset")
    func requestCharsetEncoding() throws {
        let get = try #require(AnalyzeUrl(
            ruleUrl: #"https://gbk.test/s.php?q={{key}}&t=1,{"charset":"gbk"}"#, key: "我的"
        ).toURLRequest())
        #expect(get.url?.absoluteString == "https://gbk.test/s.php?q=%CE%D2%B5%C4&t=1")

        // 搜小说 (index 0): a relative URL with a literal 搜索 and a header option.
        let relative = try #require(AnalyzeUrl(
            ruleUrl: #"/modules/article/search.php?keywords=all&searchkey={{key}}&submit=搜索,{"charset":"gbk","headers":{"Referer":"https://www.sou78.com/modules/article/search.php"}}"#,
            key: "我的", baseUrl: "https://www.sou78.com/"
        ).toURLRequest())
        #expect(relative.url?.absoluteString
            == "https://www.sou78.com/modules/article/search.php?keywords=all&searchkey=%CE%D2%B5%C4&submit=%CB%D1%CB%F7")

        let post = try #require(AnalyzeUrl(
            ruleUrl: #"https://gbk.test/s.php,{"charset":"gb2312","method":"POST","body":"searchkey={{key}}&type=articlename"}"#,
            key: "我的"
        ).toURLRequest())
        #expect(post.httpBody.flatMap { String(data: $0, encoding: .ascii) }
            == "searchkey=%CE%D2%B5%C4&type=articlename")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        // 文学壬二酸 (index 668), as the pack writes it: a multi-line option block, `GBK` in
        // capitals and an empty field first. The site answers a UTF-8 keyword "无结果".
        let po18 = AnalyzeUrl(
            ruleUrl: "/s.php,{\n  \"body\": \"submit=&type=articlename&s={{key}}\",\n  \"method\": \"POST\",\n  \"charset\": \"GBK\"\n}",
            key: "不死不灭", baseUrl: "https://m.po18co.com/"
        )
        let po18Request = try #require(po18.toURLRequest())
        #expect(po18Request.url?.absoluteString == "https://m.po18co.com/s.php")
        #expect(po18Request.httpBody.flatMap { String(data: $0, encoding: .ascii) }
            == "submit=&type=articlename&s=%B2%BB%CB%C0%B2%BB%C3%F0")

        // A GBK character's second byte can be ASCII (丂 is 81 40): Java encodes it, as here.
        let trail = try #require(AnalyzeUrl(
            ruleUrl: #"https://gbk.test/s?q={{key}},{"charset":"gbk"}"#, key: "丂"
        ).toURLRequest())
        #expect(trail.url?.absoluteString == "https://gbk.test/s?q=%81%40")

        // `escape` is JavaScript's escape(); what the URL parser then does with `%u` is its own.
        #expect(AnalyzeUrl.encodeParams("q=我的 a", charsetName: "escape", isQuery: true)
            == "q=%u6211%u7684%20a")

        // A query the source already encoded is sent as written.
        let encoded = try #require(AnalyzeUrl(
            ruleUrl: #"https://gbk.test/s?q=%CE%D2,{"charset":"gbk"}"#
        ).toURLRequest())
        #expect(encoded.url?.absoluteString == "https://gbk.test/s?q=%CE%D2")
    }

    /// 百合会坛 (YCK1331 index 324) builds its whole search URL in one template ending
    /// `,{"method":"POST",…}`. Legado splits the options off after the templates ran; the source
    /// has no jsLib, which until 11-08 kept it on the native path, and that reads no options:
    /// they went to the site in the path of a GET.
    @Test("options a template writes are read, jsLib or not")
    func templateWrittenOptions() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://bbs.yamibo.test"
        source.searchUrl = "{{\n(function(){\n    var option = {\"method\": \"POST\", \"body\": \"srchtxt=\" + encodeURIComponent(String(key)) + \"&searchsubmit=yes\"};\n    return \"https://bbs.yamibo.test/search.php?mod=forum&mobile=2,\" + JSON.stringify(option);\n})()\n}}"
        #expect(source.jsLib.isEmpty)
        #expect(source.shouldUseLegadoRuntimeFetch(for: source.searchUrl))

        let engine = JSCoreEngine()
        let request = try #require(AnalyzeUrl(
            ruleUrl: source.searchUrl, key: "我的", page: 1, baseUrl: source.bookSourceUrl,
            jsEvaluator: { code, bindings in engine.evaluateIsolated(code, bindings: bindings) },
            jsErrorProvider: { engine.lastError }
        ).toURLRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://bbs.yamibo.test/search.php?mod=forum&mobile=2")
        #expect(request.httpBody.flatMap { String(data: $0, encoding: .ascii) }
            == "srchtxt=%E6%88%91%E7%9A%84&searchsubmit=yes")
    }

    /// 趣悦小说 (YCK1331 index 72, as the pack writes it) posts a JSON body inside a
    /// single-quoted option string. The regexes that read option blocks until 11-07 turned its
    /// inner `"` into string ends; the block parsed as nothing and the search went out as a GET
    /// without a body, which the site answers "小说搜索关键字为空！".
    @Test("a single-quoted option string keeps the double quotes inside it, as Gson reads it")
    func singleQuotedOptionHoldingJSON() throws {
        let request = try #require(AnalyzeUrl(
            ruleUrl: "https://vreader.vivo.com.cn/book/search.do,{'method': 'POST',\n'body': '{\"model\":\"MI PAD 4\",\"vreaderVersion\":121020,\"bookshelfBookIds\":[],\"page\":0,\"size\":20,\"keyword\":\"{{key}}\",\"tab\":0}'\n}",
            key: "斗破"
        ).toURLRequest())
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["keyword"] as? String == "斗破")
        #expect(json["model"] as? String == "MI PAD 4")

        // The rest of Gson's lenient syntax: bare names and values, `=`/`=>` and `;`,
        // comments, and `\'` inside a single-quoted string.
        let lenient = try #require(AnalyzeUrl.parseOptionDictionary(
            "{method = POST; charset => gbk, // the site's own\n retry: 2, /* none */ webView: true, # last\n body: 'a=\\'b\\'&c=\"d\"'}"
        ))
        #expect(lenient["method"] as? String == "POST")
        #expect(lenient["charset"] as? String == "gbk")
        #expect(lenient["retry"] as? Int == 2)
        #expect(lenient["webView"] as? Bool == true)
        #expect(lenient["body"] as? String == #"a='b'&c="d""#)
    }

    /// Legado form-encodes a POST body only when it is not JSON or XML and the source set no
    /// `Content-Type`; a body under the source's own header goes out as written.
    @Test("a POST body under the source's Content-Type is sent as written, in that header's charset")
    func postBodyUnderSourceContentType() throws {
        let written = try #require(AnalyzeUrl(
            ruleUrl: #"https://gbk.test/s,{"charset":"gbk","method":"POST","body":"k=%CE%D2&n=我","headers":{"Content-Type":"application/x-www-form-urlencoded; charset=gbk"}}"#
        ).toURLRequest())
        let gbk = try #require(HTMLResponseDecoder.encoding(forIANA: "gbk"))
        #expect(written.httpBody == "k=%CE%D2&n=我".data(using: gbk))

        let xml = try #require(AnalyzeUrl(
            ruleUrl: #"https://x.test/rpc,{"method":"POST","body":"<q>我的</q>"}"#
        ).toURLRequest())
        #expect(xml.httpBody == Data("<q>我的</q>".utf8))
        #expect(xml.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    }

    /// Without a charset a form value is still encoded as Java's URLEncoder does: the app's own
    /// encoder kept `+` `/` `=`, so a base64 field's `+` reached the server as a space.
    @Test("a form value is URL-encoded unless it is already encoded")
    func formValueEncodingWithoutCharset() throws {
        let raw = try #require(AnalyzeUrl(
            ruleUrl: #"https://f.test/api,{"method":"POST","body":"d=ab+/c==&k=我 的"}"#
        ).toURLRequest())
        #expect(raw.httpBody.flatMap { String(data: $0, encoding: .ascii) }
            == "d=ab%2B%2Fc%3D%3D&k=%E6%88%91+%E7%9A%84")

        let done = try #require(AnalyzeUrl(
            ruleUrl: #"https://f.test/api,{"method":"POST","body":"k=%E6%88%91"}"#
        ).toURLRequest())
        #expect(done.httpBody.flatMap { String(data: $0, encoding: .ascii) } == "k=%E6%88%91")
    }

    // MARK: - URL templates that yield nothing (11-06 report §2)

    /// `{{page == 1 ? '' : …}}` and `{{cookie.removeCookie(…)}}` render as "", as Legado's
    /// `evalJS(it) ?: ""`; they stayed in the URL verbatim and 404'd.
    @Test("a URL template that yields nothing is removed; one that throws fails the request")
    func emptyURLTemplates() {
        let engine = JSCoreEngine()
        func analyze(_ rule: String, page: Int) -> AnalyzeUrl {
            AnalyzeUrl(
                ruleUrl: rule, page: page,
                jsEvaluator: { code, bindings in engine.evaluateIsolated(code, bindings: bindings) },
                jsErrorProvider: { engine.lastError }
            )
        }
        let paged = "https://t.test/list{{page == 1 ? '' : '_' + page}}.html"
        #expect(analyze(paged, page: 1).url == "https://t.test/list.html")
        #expect(analyze(paged, page: 2).url == "https://t.test/list_2.html")
        #expect(analyze("https://t.test/a{{(function(){})()}}/b", page: 1).url == "https://t.test/a/b")
        // A script error is not "nothing": Legado's `evalJS` throws and no request is made.
        // 绿色小说 (YCK1331) posted its template's text to the site as a path until 11-08.
        let threw = analyze("https://t.test/a{{noSuchFunction()}}/b", page: 1)
        #expect(threw.scriptFailure?.contains("noSuchFunction") == true)
        #expect(threw.toURLRequest() == nil)
        // A template runs to the next `}}`, unbalanced, as Legado's AnalyzeUrl scans it; 连城读书
        // (YCK1329) writes `{{page-1}*20}`, which has none, and Legado sends it as text.
        let unclosed = analyze("http://t.test/ranking.html?pn={{page-1}*20}&rank=xinshu,{\"webView\":true}", page: 2)
        #expect(unclosed.scriptFailure == nil)
        #expect(unclosed.toURLRequest() != nil)
        #expect(unclosed.url.hasPrefix("http://t.test/ranking.html?pn="))
        #expect(unclosed.url.hasSuffix("&rank=xinshu"))
        #expect(analyze("https://t.test/s?a={{page}}&b={{'x' + '}'}}", page: 3).url == "https://t.test/s?a=3&b=x}")
    }

    /// 偶然中文's search URL is one `@js:` whose `eval` of the site's script throws. Legado's
    /// `evalJS` throws there and nothing is sent; the rule's own text went out as a path.
    @Test("a URL script that throws builds no request; one that gives no value does")
    func throwingURLScriptBuildsNoRequest() throws {
        let engine = JSCoreEngine()
        func analyze(_ rule: String) -> AnalyzeUrl {
            AnalyzeUrl(
                ruleUrl: rule, key: "k", page: 1, baseUrl: "https://m.test",
                jsEvaluator: { code, bindings in engine.evaluateIsolated(code, bindings: bindings) },
                jsErrorProvider: { engine.lastError }
            )
        }
        let failed = analyze("@js:\neval('if (1) {');\nbaseUrl + '/s?q={{key}}'")
        #expect(failed.scriptFailure?.contains("SyntaxError") == true)
        #expect(failed.toURLRequest() == nil)

        let ran = analyze("@js:\nbaseUrl + '/s?q={{key}}'")
        #expect(ran.scriptFailure == nil)
        #expect(ran.toURLRequest()?.url?.absoluteString == "https://m.test/s?q=k")

        // A block that gives no value did not fail: Rhino's `undefined` is null, "null" is the
        // URL so far, and the text after the block replaces it (棉花小说, YCK1331).
        let sideEffect = analyze(
            "<js>cookie.removeCookie(source.key);</js>\n/search/,{\"method\":\"POST\",\"body\":\"searchkey={{key}}\"}"
        )
        #expect(sideEffect.scriptFailure == nil)
        let request = try #require(sideEffect.toURLRequest())
        #expect(request.url?.absoluteString == "https://m.test/search/")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody.flatMap { String(data: $0, encoding: .ascii) } == "searchkey=k")
        #expect(analyze("@js:\nvoid 0").evaluatedRuleUrl == "null")
    }

    /// 存档书库 (YCK1331): its header script runs `var Proxy = Map('代理：').split(",")`, which
    /// lands on the global; the AnalyzeUrl `java` and `Packages` then threw "Array is not a
    /// constructor". Legado's are Java objects no source script can replace.
    @Test("a source's global named Proxy leaves java and Packages working")
    func sourceGlobalNamedProxy() {
        let engine = JSCoreEngine()
        _ = engine.evaluateIsolated("var Proxy = '代理1,代理2'.split(',');", bindings: [:])
        #expect(engine.evaluate("Proxy.length") == "2")
        let url = AnalyzeUrl(
            ruleUrl: "@js:\nbaseUrl + '/s?q=' + java.encodeURI(key)", key: "我", page: 1, baseUrl: "https://m.test",
            jsEvaluator: { code, bindings in engine.evaluateIsolated(code, bindings: bindings) },
            jsErrorProvider: { engine.lastError }
        )
        #expect(url.scriptFailure == nil)
        #expect(url.toURLRequest()?.url?.absoluteString == "https://m.test/s?q=%E6%88%91")
        #expect(engine.evaluate("Packages.android.text.TextUtils.isEmpty('')") == "true")
        #expect(engine.lastError == nil)
    }

    /// 恩京书房: the native search URL `…/<,page/{{page}}/>?s={{key}}` sent `/<` and 404'd.
    @Test("the native search URL reads <,page/{{page}}/> by page")
    func nativeSearchPageRule() async {
        var source = BookSource()
        source.bookSourceUrl = "https://enjing.test"
        source.searchUrl = "https://enjing.test/<,page/{{page}}/>?s={{key}}"
        #expect(source.shouldUseLegadoRuntimeFetch(for: source.searchUrl) == false)
        let first = await source.renderSearchURL(query: "x", page: 1)
        let second = await source.renderSearchURL(query: "x", page: 2)
        #expect(first.url == "https://enjing.test/?s=x")
        #expect(second.url == "https://enjing.test/page/2/?s=x")
    }

    // MARK: - A search that lands on a book page

    private static func detailSource(pattern: String = "") -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://banxia.test"
        source.bookSourceName = "半夏 fixture"
        source.bookUrlPattern = pattern
        source.ruleSearch.bookList = "class.result@tag.li"
        source.ruleSearch.name = "tag.a@text"
        source.ruleSearch.bookUrl = "tag.a@href"
        source.ruleBookInfo.name = "class.book-title@text"
        source.ruleBookInfo.author = "class.book-author@text"
        return source
    }

    private static let detailHTML = #"<h1 class="book-title">偉大航路賣八卦的人生</h1><p class="book-author">某作者</p>"#

    /// 半夏小說: the search redirects an exact title to the book's own page.
    @Test("a final URL matching bookUrlPattern is read with the detail rules")
    func searchLandsOnBookPage() throws {
        let source = Self.detailSource(pattern: #"https://banxia\.test/book/\d+/"#)
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: Self.detailHTML, baseURL: "https://banxia.test/book/7/", source: source
        )
        #expect(books.map(\.name) == ["偉大航路賣八卦的人生"])
        #expect(books.first?.author == "某作者")
        #expect(books.first?.bookUrl == "https://banxia.test/book/7/")
    }

    @Test("an empty list without bookUrlPattern is read as a book page")
    func emptyListReadsAsBookPage() throws {
        let source = Self.detailSource()
        let bridge = ModernParserBridge(source: source)
        let books = try bridge.parseSearchResults(
            html: Self.detailHTML, baseURL: "https://banxia.test/book/7/", source: source
        )
        #expect(books.map(\.name) == ["偉大航路賣八卦的人生"])
        // A "no results" page reads no name: still empty.
        let none = try bridge.parseSearchResults(
            html: "<p>沒有找到</p>", baseURL: "https://banxia.test/search?q=x", source: source
        )
        #expect(none.isEmpty)
    }

    // MARK: - Failures are not empty pages

    @Test("a search whose rule script throws is a script error, not an empty page")
    func throwingSearchRuleIsAnError() {
        var source = BookSource()
        source.bookSourceUrl = "https://throws.test"
        source.ruleSearch.bookList = "@js:undefined.nothing"
        source.ruleSearch.name = "tag.a@text"
        #expect(throws: ModernParserBridgeError.self) {
            try ModernParserBridge(source: source).parseSearchResults(
                html: "<a>x</a>", baseURL: "https://throws.test/s", source: source
            )
        }
    }

    // MARK: - checkKeyWord

    @Test("checkKeyWord that is debugger input falls back to the run's keyword")
    func checkKeyword() {
        var source = BookSource()
        for (keyword, expected) in [
            ("斗罗", "斗罗"), ("", "我的"), ("  ", "我的"),
            ("https://x.test/book/1", "我的"), ("分类::https://x", "我的"),
            ("++https://x.test/toc", "我的"), ("--https://x.test/c", "我的"),
        ] {
            source.ruleSearch.checkKeyWord = keyword
            #expect(source.checkKeyword(default: "我的") == expected)
        }
    }

    // MARK: - Waiting for the user

    @Test("cancelling the registry ends a script parked on the user")
    func userWaitCancellation() async {
        let registry = LegadoUserWaitRegistry()
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let semaphore = DispatchSemaphore(value: 0)
            let token = registry.register { semaphore.signal() }
            #expect(registry.isWaiting)
            DispatchQueue.global().async {
                semaphore.wait()
                registry.unregister(token)
                continuation.resume(returning: true)
            }
            registry.cancelAll()
        }
        #expect(ended)
        #expect(!registry.isWaiting)
    }

    @Test("a withdrawn wait tells its sheet, even one installed afterwards")
    func waitWithdrawalReachesPresenter() async {
        let early = SourceWaitWithdrawal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            early.onWithdraw { continuation.resume() }
            early.withdraw()
        }
        let late = SourceWaitWithdrawal()
        late.withdraw()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            late.onWithdraw { continuation.resume() }
        }
        #expect(early.isWithdrawn && late.isWithdrawn)
    }

    // MARK: - java.* the pack calls

    private static func ok(_ request: URLRequest, _ body: Data) -> LegadoHTTPResult {
        .make(
            request: request, data: body,
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
    }

    /// 黄果短剧 / Linpx: legado-E's `ajaxTestAll` answers every URL, a failure as its error code.
    @Test("ajaxTestAll answers each request's time, or Legado's error code")
    func ajaxTestAll() {
        let engine = JSCoreEngine()
        engine.networkHandler = { request, _ in
            let url = request.url!.absoluteString
            if url.contains("dns") {
                return .make(request: request, data: nil, response: nil, error: URLError(.cannotFindHost))
            }
            // The deadline leaves the prompt request room for the test host's main-thread
            // stalls (~600 ms, measured), which once timed it out at a 300 ms deadline.
            if url.contains("slow") { Thread.sleep(forTimeInterval: 2) }
            return Self.ok(request, Data("pong".utf8))
        }
        let value = engine.evaluate("""
        var r = java.ajaxTestAll(['https://ok.test/', 'https://dns.test/', 'https://slow.test/'], 1000);
        [r.length, r[0].body(), r[0].callTime() >= 0, r[1].callTime(), r[2].callTime(), r[2].body()].join('|');
        """)
        #expect(value == "3|pong|true|-3|-1|timeout")
        #expect(engine.lastError == nil)
    }

    /// 棉花糖: its `java.webView` page never finished loading, the script read "" and then died
    /// on `"".match(…)[1]`. Legado's `BackstageWebView` raises instead (`withTimeout(60000L)`,
    /// and `js执行超时` once its script has read `null` 32 times), and reads a script's empty
    /// string as the page's answer rather than reading again. Not on the main actor: the
    /// bridge blocks its thread while the WebView loads on main.
    @Test("java.webView raises Legado's timeout, and answers a script's empty string at once")
    func webViewTimeoutAndEmptyAnswer() {
        let engine = JSCoreEngine()
        engine.bridge.webViewTimeoutSeconds = 1
        let timedOut = engine.evaluate("""
        try { java.webView('<p>x</p>', 'https://webview.test/', 'null'); 'answered' } catch (e) { String(e) }
        """)
        #expect(timedOut?.contains("TimeoutCancellationException: Timed out waiting for 1000 ms") == true)

        // Read again after "" or "null" text, the script would read until the deadline and raise.
        engine.bridge.webViewTimeoutSeconds = 20
        let answers = engine.evaluate("""
        var html = '<p id="a">x</p>', url = 'https://webview.test/';
        [JSON.stringify(java.webView(html, url, "''")), java.webView(html, url, "'null'"),
         java.webView(html, url, "document.getElementById('a').textContent"),
         java.webView(html, url, null).indexOf('id="a"') > 0].join('|');
        """)
        #expect(answers == "\"\"|null|x|true")
        #expect(engine.lastError == nil)
    }

    /// 爱腐文: `downloadFile(url)` then `readTxtFile(path, 'ISO8859_1')` reads a PNG's bytes
    /// losslessly. 番茄听书: `downloadFile(hex, 'https://x/…,{"type":"m4a"}')`.
    @Test("source files: download, read as bytes and ISO8859_1 text, delete, and stay in their root")
    func sourceFiles() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://files.test"
        source.bookSourceName = "files fixture"
        source.ruleBookInfo.name = #"""
        @js:
        var p = java.downloadFile('https://k.test/key/favicon.ico');
        var s = java.readTxtFile(p, 'ISO8859_1');
        var codes = [];
        for (var i = 0; i < s.length; i++) codes.push(s.charCodeAt(i));
        var hexPath = java.downloadFile('89ff00', 'https://x.test/a.m4a,{"type":"m4a"}');
        var none = java.downloadFile('89ff00', 'https://x.test/a.m4a');
        var bad;
        try { java.readFile('../escape'); bad = 'no'; } catch (e) { bad = 'threw'; }
        var bytes = java.readFile(p).join(',');
        var deleted = java.deleteFile(p);
        [p.charAt(0) + p.slice(-4), p.length, codes.join(','), bytes, hexPath.slice(-4),
         java.readFile(hexPath).join(','), none === '', bad, deleted, java.readFile(p) === null,
         java.deleteFile(hexPath), java.deleteFile(hexPath)].join(';')
        """#
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request, _ in
            Self.ok(request, Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00, 0x80]))
        }
        let book = try bridge.parseBookInfo(
            html: "<p></p>", bookUrl: "https://files.test/b", baseURL: "https://files.test/b", source: source
        )
        #expect(book.name == "/.ico;21;137,80,78,71,255,0,128;137,80,78,71,255,0,128;.m4a;137,255,0;true;threw;true;true;true;false")
    }

    /// 拷贝轻说 (YCK1331) reads every chapter's text — GBK — through `java.cacheFile(url)`,
    /// which Legado downloads once and reads back as `readTxtFile` does, detecting the charset.
    @Test("java.cacheFile downloads once, reads the file's charset, and skips a value that names no file")
    func cacheFileDownloadsOnce() {
        let engine = JSCoreEngine()
        engine.bookSource = BookSource(
            bookSourceUrl: "cache-file-\(UUID().uuidString)", bookSourceName: "cacheFile fixture"
        )
        let url = "https://cache-file.test/\(UUID().uuidString).txt"
        let text = "第一章 开学\n　　清晨的阳光照在教学楼上，同学们陆陆续续走进教室，准备开始新学期的第一节课。"
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let bytes = text.data(using: gbk)!
        var requests = 0
        engine.networkHandler = { request, _ in
            requests += 1
            return Self.ok(request, bytes)
        }

        #expect(engine.evaluate("java.cacheFile('\(url)')") == text)
        #expect(engine.evaluate("java.cacheFile('\(url)', 0)") == text)
        #expect(requests == 1)
        #expect(engine.lastError == nil)

        // What `importScript` kept under this key before it read through `cacheFile`.
        _ = engine.evaluate("cache.put(java.md5Encode16('\(url)'), 'var a = \"../../x\";')")
        #expect(engine.evaluate("java.cacheFile('\(url)')") == text)
        #expect(requests == 2)
        #expect(engine.lastError == nil)
    }

    /// Legado `CacheManager.put(key, value, saveTime)` / `putFile(…, saveTime)`: a stored value
    /// past its deadline reads as missing. 34 sources in YCK1330／1331 pass one (哔哩哔哩: 300).
    @Test("cache.put and cache.putFile keep a value for saveTime seconds")
    func cacheSaveTime() {
        let id = "cache-deadline-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: "com.yuedu.cache.\(id)") }
        let context = JSContext()!
        context.setObject(LegadoCacheBridge(sourceId: id), forKeyedSubscript: "cache" as NSString)
        context.evaluateScript("""
        cache.put('kept', 'a'); cache.put('expired', 'b', -1); cache.put('later', 'c', 3600);
        cache.putFile('fileKept', 'd'); cache.putFile('fileExpired', 'e', -1);
        """)
        #expect(context.exception == nil)

        // A second bridge reads the store, not the first one's memory cache.
        let reader = LegadoCacheBridge(sourceId: id)
        #expect(reader.get("kept") == "a")
        #expect(reader.get("expired") == nil)
        #expect(reader.get("later") == "c")
        #expect(reader.getFile("fileKept") == "d")
        #expect(reader.getFile("fileExpired") == nil)
    }

    /// 起点中文 (YCK1331) fetches a chapter's ciphertext with okhttp3 — `response.body().bytes()`,
    /// `response.close()` in a `finally` — and keys its decryption with hutool's
    /// `DigestUtil.md5(bytes)`.
    @Test("okhttp3 Response answers body().bytes() and close(); hutool DigestUtil digests bytes")
    func okhttpBytesAndHutoolDigest() {
        let engine = JSCoreEngine()
        engine.networkHandler = { request, _ in Self.ok(request, Data([0x89, 0x50, 0x4E, 0x47])) }
        let value = engine.evaluate("""
        var ji = new JavaImporter();
        ji.importPackage(Packages.okhttp3);
        var out;
        with (ji) {
          var response = new OkHttpClient().newCall(new Request.Builder().url('https://ok.test/c').get().build()).execute();
          try { var b = response.body().bytes(); out = [b.length, b[0], b[3]]; } finally { response.close(); }
        }
        var D = Packages.cn.hutool.crypto.digest.DigestUtil;
        var md5 = D.md5([97, 98, 99]);
        out.concat([md5.length, md5[0], D.md5Hex([97, 98, 99]), D.md5Hex('abc'), D.sha1Hex('abc').slice(0, 8)]).join('|');
        """)
        #expect(engine.lastError == nil)
        // `bytes()` and `md5` answer Java's signed bytes: 0x89 reads -119 and 0x90 -112, as every
        // `byte[]` does under Rhino (java-byte-sign.json).
        #expect(value == "4|-119|71|16|-112|900150983cd24fb0d6963f7d28e17f72|900150983cd24fb0d6963f7d28e17f72|a9993e36")
    }

    @Test("getTag is the source's name on source and java")
    func getTag() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://tag.test"
        source.bookSourceName = "Z-Library fixture"
        source.ruleBookInfo.name = "@js:(source.getTag ? source.getTag() : 'none') + '|' + java.getTag()"
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: "<p></p>", bookUrl: "https://tag.test/b", baseURL: "https://tag.test/b", source: source
        )
        #expect(book.name == "Z-Library fixture|Z-Library fixture")
    }

    /// 移动阅读 (index 326) runs `eval(String(source.getSource\u{200B}().bookSourceComment))`: Rhino
    /// drops the zero-width space, and Legado's `BaseSource.getSource()` is the source itself.
    @Test("source.getSource() is the source, written with a format character too")
    func getSourceIsItself() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://get-source.test"
        source.bookSourceComment = "var config = 'from comment';"
        source.ruleBookInfo.name = "@js:eval(String(source.getSource\u{200B}().bookSourceComment)); config + '|' + (source.getSource().getKey() == source.getKey())"
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: "<p></p>", bookUrl: "https://get-source.test/b", baseURL: "https://get-source.test/b", source: source
        )
        #expect(book.name == "from comment|true")
    }

    @Test("source.refreshJSLib() runs the jsLib again before the next script")
    func refreshJSLib() {
        var source = BookSource()
        source.bookSourceUrl = "https://refresh-jslib.test"
        source.jsLib = "var hits = (typeof hits == 'number' ? hits : 0) + 1;"
        let bridge = ModernParserBridge(source: source)
        #expect(bridge.evaluateSourceScript("String(hits)") == "1")
        #expect(bridge.evaluateSourceScript("String(hits)") == "1")
        #expect(bridge.evaluateSourceScript("source.refreshJSLib(); String(hits)") == "1")
        #expect(bridge.evaluateSourceScript("String(hits)") == "2")
    }

    /// 露西弗俱乐部 (index 114) calls it from its login button, so that 發現 lists 我的收藏.
    @Test("source.refreshExplore() drops the source's cached 發現 categories")
    func refreshExplore() {
        let url = "https://refresh-explore.test"
        let key = DiscoverKindsCache.key(sourceUrl: url, exploreUrl: "熱門::/hot", variableJSON: nil)
        DiscoverKindsCache.shared.store([.init(title: "熱門", url: "\(url)/hot")], forKey: key)
        var source = BookSource()
        source.bookSourceUrl = url
        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate("source.refreshExplore()")
        #expect(engine.lastError == nil)
        #expect(DiscoverKindsCache.shared.items(forKey: key) == nil)
    }

    /// Legado `ConcurrentRateLimiter.updateConcurrentRate`: a rate that parses replaces the
    /// source's, one that does not leaves it.
    @Test("source.putConcurrent() sets the rate the source's requests go at")
    func putConcurrent() async {
        let url = "https://put-concurrent-\(UUID().uuidString).test"
        var source = BookSource()
        source.bookSourceUrl = url
        source.concurrentRate = "1000"
        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate("source.putConcurrent('3/1000'); source.putConcurrent('fast')")
        #expect(engine.lastError == nil)
        let started = Date()
        for _ in 0..<3 {
            await SourceRateLimit.run(rate: source.concurrentRate, key: url) { @Sendable in }
        }
        #expect(Date().timeIntervalSince(started) < 0.5, "three requests fit 3/1000 at once; 1000 would space them a second apart")
    }

    @Test("openUrl sends legado:// and yuedu:// import links to the importer, anything else to the reader")
    func openURLRouting() {
        func request(_ url: String) -> SourceOpenURLRequest {
            SourceOpenURLRequest(url: URL(string: url)!, mimeType: nil, sourceName: "s")
        }
        #expect(request("legado://import/importonline?src=https://cdn.test/pixiv.json").isImportLink)
        #expect(request("yuedu://import/auto?src=https://cdn.test/a.json").isImportLink)
        #expect(!request("mqqapi://card/show_pslcard?src_type=internal&uin=1").isImportLink)
        #expect(!request("https://h1.test/enter").isImportLink)
    }

    // MARK: - RSA (乐读小说)

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let length: [UInt8]
        switch content.count {
        case ..<0x80: length = [UInt8(content.count)]
        case ..<0x100: length = [0x81, UInt8(content.count)]
        default: length = [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)]
        }
        return [tag] + length + content
    }

    private static let rsaAlgorithm: [UInt8] =
        der(0x30, [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])

    @Test("createAsymmetricCrypto decrypts with the public key by default, and round-trips both ways")
    func asymmetricCrypto() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let publicPKCS1 = [UInt8](try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)
        let privatePKCS1 = [UInt8](try #require(SecKeyCopyExternalRepresentation(privateKey, nil)) as Data)
        // Java's encodings: X.509 SubjectPublicKeyInfo and PKCS#8.
        let spki = Self.der(0x30, Self.rsaAlgorithm + Self.der(0x03, [0x00] + publicPKCS1))
        let pkcs8 = Self.der(0x30, [0x02, 0x01, 0x00] + Self.rsaAlgorithm + Self.der(0x04, privatePKCS1))

        // What the server sends: private-key encryption, type-1 blocks of 117 bytes, made here
        // with SecKey's raw signature — not with the code under test.
        let text = String(repeating: "第一章 正文。", count: 12)
        let plain = [UInt8](text.utf8)
        var cipher: [UInt8] = []
        var offset = 0
        while offset < plain.count {
            let chunk = Array(plain[offset..<min(offset + 117, plain.count)])
            let block = [0x00, 0x01] + [UInt8](repeating: 0xFF, count: 128 - 3 - chunk.count) + [0x00] + chunk
            let signed = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureRaw, Data(block) as CFData, nil))
            cipher += [UInt8](signed as Data)
            offset += 117
        }
        #expect(cipher.count == 256)

        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var pub = java.base64DecodeToByteArray('\(Data(spki).base64EncodedString())');
        var priv = java.base64DecodeToByteArray('\(Data(pkcs8).base64EncodedString())');
        var server = java.createAsymmetricCrypto("RSA").setPublicKey(pub)
            .decryptStr(java.base64DecodeToByteArray('\(Data(cipher).base64EncodedString())'));
        var c = java.createAsymmetricCrypto('RSA').setPublicKey(pub).setPrivateKey(priv);
        var enc = c.encryptBase64('\(text)');
        [server === '\(text)', c.decryptStr(enc, false) === '\(text)',
         c.decryptStr(c.encrypt('\(text)', false)) === '\(text)'].join('|');
        """)
        #expect(value == "true|true|true")
        #expect(engine.lastError == nil)
    }

    // MARK: - Discover pages and infoHtml

    @Test("an empty discover list without bookUrlPattern is read as a book page")
    func exploreEmptyListReadsAsBookPage() {
        let source = Self.detailSource()
        let books = ModernParserBridge(source: source).parseExploreResults(
            html: Self.detailHTML, baseURL: "https://banxia.test/book/7/", source: source
        )
        #expect(books.map(\.name) == ["偉大航路賣八卦的人生"])
        #expect(books.first?.infoHtml == Self.detailHTML)
    }

    /// A page that answers a request without reaching the network.
    private final class NoNetworkProtocol: URLProtocol {
        static let requests = OSAllocatedUnfairLock(initialState: 0)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.withLock { $0 += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    @Test("the detail stage reads a book's infoHtml instead of requesting its page again")
    func detailReusesInfoHTML() async throws {
        let source = Self.detailSource()
        let found = try ModernParserBridge(source: source).parseSearchResults(
            html: Self.detailHTML, baseURL: "https://banxia.test/search?q=x", source: source
        )
        let book = try #require(found.first)
        #expect(book.infoHtml == Self.detailHTML)
        // Never encoded: a cached result has none.
        let decoded = try JSONDecoder().decode(OnlineBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.infoHtml == nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkProtocol.self]
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: URLSession(configuration: configuration)))
        let before = NoNetworkProtocol.requests.withLock { $0 }
        let package = try await fetcher.fetchBookInfoPackage(
            url: book.bookUrl, source: source, knownBook: book, usesCache: false
        )
        #expect(package.onlineBook.name == "偉大航路賣八卦的人生")
        #expect(package.onlineBook.author == "某作者")
        #expect(NoNetworkProtocol.requests.withLock { $0 } == before)
    }

    // MARK: - A request whose URL says webView (11-06 report §3)

    /// A page that fills itself in with script: its HTTP body is an empty shell.
    private static let scriptedPage = Data("""
    <html><head><title>scripted</title></head><body><div id="out"></div>
    <script>document.getElementById('out').textContent = 'rendered by ' + 'script';</script>
    </body></html>
    """.utf8)

    /// Answers every `wv.test` request with `scriptedPage`.
    final class ScriptedPageProtocol: URLProtocol {
        static let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScriptedPageProtocol.self]
            return URLSession(configuration: configuration)
        }
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wv.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let method = request.httpMethod ?? "GET"
            Self.methods.withLock { $0.append(method) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: YCK1330CompatibilityTests.scriptedPage)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static func webViewSource() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://wv.test"
        source.bookSourceName = "WebView fixture"
        return source
    }

    /// Legado's `executeStrRequest`: a POST goes out over HTTP and its response is rendered at its
    /// URL; `webJs` reads the rendered page, and `bodyJs` is not applied to a WebView result.
    @Test("a POST whose URL says webView is rendered and read by its webJs, without bodyJs")
    func webViewPostIsRendered() async throws {
        let host = SourceScriptHost(bridgeFor: Self.webViewSource(), requestSession: ScriptedPageProtocol.session())
        let rule = #"https://wv.test/search,{"method":"POST","body":"q=1","webView":true,"webJs":"document.getElementById('out').textContent","bodyJs":"'bodyJs ran'"}"#
        let (body, url) = try await host.fetch(ruleUrl: rule)
        #expect(body == "rendered by script")
        #expect(url == "https://wv.test/search")
        #expect(ScriptedPageProtocol.methods.withLock { $0.last } == "POST")
    }

    /// Without a `webJs` of its own the content stage runs the content rule's, as Legado's
    /// `getContentAwait` passes it; with neither, the rendered page's HTML is the body.
    @Test("the content stage runs ruleContent.webJs; no script reads the rendered HTML")
    func webViewContentStageScript() async throws {
        var source = Self.webViewSource()
        source.ruleContent.webJs = "document.title + ':' + document.getElementById('out').textContent"
        let host = SourceScriptHost(bridgeFor: source, requestSession: ScriptedPageProtocol.session())
        let rule = #"https://wv.test/c/1,{"method":"POST","webView":"true"}"#
        let (content, _) = try await host.fetch(ruleUrl: rule, contentStage: true)
        #expect(content == "scripted:rendered by script")
        let (page, _) = try await host.fetch(ruleUrl: rule)
        #expect(page.contains(#"<div id="out">rendered by script</div>"#))
    }

    /// `java.ajax` reads its URL the same way: Legado's `getStrResponseAwait` is behind both.
    @Test("java.ajax with a webView URL returns the rendered page")
    func scriptAjaxWebView() throws {
        var source = Self.webViewSource()
        source.ruleBookInfo.name = #"""
        @js:java.ajax(`https://wv.test/api,{"method":"POST","body":"a=1","webView":true,"webJs":"document.getElementById('out').textContent"}`)
        """#
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request, _ in Self.ok(request, Self.scriptedPage) }
        let book = try bridge.parseBookInfo(
            html: "<p></p>", bookUrl: "https://wv.test/b", baseURL: "https://wv.test/b", source: source
        )
        #expect(book.name == "rendered by script")
    }

    // MARK: - List rules: plain CSS, XPath nodes, the `+` prefix

    /// 万象书城 / 夜伴书屋: a search list of `tbody tr`. No extractor claimed a plain
    /// descendant selector, so the text fallback handed each row over as text and the
    /// `td` fields found nothing — 0 books of 429.
    @Test("a plain descendant selector selects rows the field rules can read")
    func plainDescendantSelector() throws {
        #expect(JsoupDefaultExtractor().canHandle(rule: "tbody tr"))
        #expect(JsoupDefaultExtractor().canHandle(rule: "dl dd"))
        var source = BookSource()
        source.bookSourceUrl = "https://wanxiang.test"
        source.ruleSearch.bookList = "tbody tr"
        source.ruleSearch.name = "td.0@a@text"
        source.ruleSearch.bookUrl = "td.0@a@href"
        source.ruleSearch.author = "td.2@text"
        let html = """
        <table><thead><tr><th>書名</th><th>最新</th><th>作者</th></tr></thead><tbody>
        <tr><td><a href="/book/1">第一本</a></td><td>第10章</td><td>甲</td></tr>
        <tr><td><a href="/book/2">第二本</a></td><td>第20章</td><td>乙</td></tr>
        </tbody></table>
        """
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://wanxiang.test/s", source: source
        )
        #expect(books.map(\.name) == ["第一本", "第二本"])
        #expect(books.map(\.author) == ["甲", "乙"])
        #expect(books.map(\.bookUrl) == ["https://wanxiang.test/book/1", "https://wanxiang.test/book/2"])
    }

    private static let ddTOC = """
    <div id="list"><dl><dt>正文</dt>
    <dd><a href="/c/1">第一章</a></dd><dd><a href="/c/2">第二章</a></dd>
    </dl></div>
    """

    private static func tocSource(list: String, name: String, url: String) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://toc.test"
        source.ruleToc.chapterList = list
        source.ruleToc.chapterName = name
        source.ruleToc.chapterUrl = url
        return source
    }

    private static func chapters(_ source: BookSource, _ html: String = ddTOC) throws -> [OnlineChapterRef] {
        try ModernParserBridge(source: source).parseTOC(
            html: html, baseURL: "https://toc.test/book/1/", source: source
        )
    }

    /// 言情小说 (YCK1330) keeps each chapter's next-page selector with `chapter.putVariable` in
    /// its TOC and next-page rules. Legado's `chapter` is the `BookChapter` whose variables
    /// `java.put` writes and `java.get` reads while it is in scope.
    @Test("chapter.putVariable is the chapter's variable, from its TOC row to its pages")
    func chapterVariablesFollowTheChapter() throws {
        var source = Self.tocSource(
            list: "dd", name: "a@text",
            url: "a@href@js:chapter.putVariable('next', 'n-' + String(result).split('/').pop()); result"
        )
        source.ruleContent.content = "@js:java.get('next') + '|' + chapter.getVariable('next')"
        source.ruleContent.nextContentUrl =
            "@js:chapter.putVariable('page', '2'); 'https://toc.test/c/' + chapter.getVariable('next')"
        let bridge = ModernParserBridge(source: source)
        let chapters = try bridge.parseTOC(html: Self.ddTOC, baseURL: "https://toc.test/book/1/", source: source)
        let first = try #require(chapters.first)
        #expect(first.runtimeVariables?["next"] == "n-1")
        #expect(chapters.last?.runtimeVariables?["next"] == "n-2")

        let page = try bridge.parseChapterResult(
            html: "{}", baseURL: first.url, source: source, runtimeVariables: first.runtimeVariables, chapterRef: first
        )
        #expect(page.content == "n-1|n-1")
        let next = bridge.extractNextContentURLs(
            html: "{}", baseURL: first.url, source: source,
            runtimeVariables: page.runtimeVariables ?? first.runtimeVariables, chapterRef: first
        )
        #expect(next.urls == ["https://toc.test/c/n-1"])
        #expect(next.runtimeVariables?["page"] == "2")
    }

    /// 黄区 (YCK1330) builds its play list from `new org.jsoup.nodes.Element('a')`; 完本小说 and
    /// 小红书库 order their chapter rows with `Elements.sort(comparator)`.
    @Test("new Element(tag) is a new element; Elements.sort sorts in place")
    func jsoupElementConstructorAndSort() {
        let engine = JSCoreEngine()
        let built = engine.evaluate("""
        var els = org.jsoup.Jsoup.parse('<p>x</p>').select('p');
        var a = new org.jsoup.nodes.Element('a');
        a.attr('href', 'https://h.test/1'); a.text('第1集'); els.add(a);
        els.size() + '|' + els.get(1).outerHtml() + '|' + els.get(1).attr('href')
        """)
        #expect(built == #"2|<a href="https://h.test/1">第1集</a>|https://h.test/1"#)
        #expect(engine.evaluate("try { new org.jsoup.nodes.TextNode('x'); 'made' } catch (e) { 'threw' }") == "threw")
        let sorted = engine.evaluate("""
        var e = org.jsoup.Jsoup.parse('<i n="3"></i><i n="1"></i><i n="2"></i>').select('i');
        var r = e.sort((a, b) => +a.attr('n') - +b.attr('n'));
        [r === undefined, e.get(0).attr('n') + e.get(1).attr('n') + e.get(2).attr('n'), e[0].attr('n')].join('|')
        """)
        #expect(sorted == "true|123|1")
        #expect(engine.lastError == nil)
    }

    /// 移动阅读 (YCK1330) signs its requests with DES through Java's key factory. The expected
    /// text is what Java 26 answers for the same calls.
    @Test("DESKeySpec and SecretKeyFactory make the key Cipher reads")
    func desKeyFactory() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var ji = new JavaImporter();
        ji.importPackage(Packages.java.lang, Packages.javax.crypto.spec, Packages.javax.crypto, Packages.android.util);
        with (ji) {
            var cipher = Cipher.getInstance("DES");
            var key = SecretKeyFactory.getInstance("DES").generateSecret(new DESKeySpec(String('web@hzlq').getBytes()));
            cipher.init(Cipher.ENCRYPT_MODE, key);
            Base64.encodeToString(cipher.doFinal(String('hello').getBytes()), Base64.NO_WRAP)
        }
        """)
        #expect(value == "bzvS8/UiI48=")
        #expect(engine.lastError == nil)
    }

    /// 爱巴士 (YCK1330) searches with `let key = java.encodeURI(key)`, which reads the search key
    /// under Rhino: it has no temporal dead zone (checked on Rhino 1.8.1 with Legado's scopes).
    @Test("a let that reads its own name reads the outer binding, as Rhino has no TDZ")
    func letReadingItsOwnName() {
        func normalized(_ script: String) -> String { LegadoRhinoNormalizer.normalize(script).source }
        #expect(normalized("let key = java.encodeURI(key)\nlet url = key + '/s'")
            == "var key = java.encodeURI(key)\nlet url = key + '/s'")
        #expect(normalized("function f() { let q = typeof q; return q }") == "function f() { var q = typeof q; return q }")
        #expect(normalized("let a = 1, b = typeof b;") == "var a = 1, b = typeof b;")
        for script in ["if (x) { let k = k }", "let k = { k: 1 }", "let k = o.k", "let k = f(1)\nk()"] {
            #expect(normalized(script) == script)
        }
        let engine = JSCoreEngine()
        #expect(engine.evaluateIsolated("let key = encodeURIComponent(key); key", bindings: ["key": "斗 罗"])
            == "%E6%96%97%20%E7%BD%97")
        #expect(engine.evaluateIsolated("let z = typeof z; z", bindings: [:]) == "undefined")
    }

    /// 吾爱耽美 (YCK1330) lists its discover page with an `@js:` that tests `baseUrl.match(/##/)`.
    /// Legado's `getElements` runs a list rule as written; split at `##`, the script ended inside
    /// the regex literal.
    @Test("a list rule's script keeps its ##")
    func listScriptKeepsDoubleHash() {
        var source = BookSource()
        source.bookSourceUrl = "https://list.test"
        source.ruleExplore.bookList = "@js:\nvar m = String(baseUrl).match(/##/);\njava.getElements(m ? 'li.a' : 'li.b')"
        source.ruleExplore.name = "text"
        source.ruleExplore.bookUrl = "text"
        let books = ModernParserBridge(source: source).parseExploreResults(
            html: "<ul><li class='a'>甲</li><li class='b'>乙</li></ul>", baseURL: "https://list.test/##", source: source
        )
        #expect(books.map(\.name) == ["甲"])
    }

    /// 爱巴士 (YCK1330) reads its chapter with `$.data.content_data` — the text
    /// `["第一段","第二段"]` — and then `result.match(…)`. Legado's `getString` hands a script
    /// the string a JSONPath, XPath, JSoup or replace step made.
    @Test("a script after a JSONPath step reads the step's string")
    func scriptAfterJSONStepReadsAString() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://abs.test"
        source.ruleContent.content = #"$.data.content_data\#n@js:\#nresult = result.match(/\["(.*)"\]/)[1].split("\",\"").join("\n")"#
        let bridge = ModernParserBridge(source: source)
        let body = #"{"data":{"content_data":"[\"第一段\",\"第二段\"]","arr":[1,2],"obj":{"k":"v"},"n":3}}"#
        let page = try bridge.parseChapterResult(html: body, baseURL: "https://abs.test/c/1", source: source)
        #expect(page.content.contains("第一段"))
        #expect(page.content.contains("第二段"))

        let engine = ModernRuleEngine()
        let js = JSCoreEngine()
        engine.jsEvaluator = { script, result in js.evaluateRuleStep(script, result: result) }
        engine.setContent(body, baseUrl: "https://abs.test/c/1")
        #expect(engine.getString(ruleStr: "$.data.content_data@js:typeof result") == "string")
        #expect(engine.getString(ruleStr: "$.data.content_data##第一##1@js:typeof result + result.length") == "string12")
        // A number, a list or an object is the string `AnalyzeByJSonPath.getString` makes of it.
        for field in ["arr", "obj", "n"] {
            #expect(engine.getString(ruleStr: "$.data.\(field)@js:typeof result") == "string")
        }
        #expect(js.lastError == nil)
    }

    /// 吾爱耽美 (YCK1330) lists its 排行榜 at `/##` and tests `baseUrl.match(/##/)`. Legado's
    /// `baseUrl` is okhttp's `HttpUrl.toString()`, which keeps a fragment as written.
    @Test("a response's URL keeps the fragment the source wrote, as okhttp's does")
    func responseURLKeepsWrittenFragment() throws {
        func read(_ written: String, final: String? = nil) throws -> String {
            let requested = try #require(AnalyzeUrl.requestURL(written))
            let finalURL = try final.map { try #require(URL(string: $0)) } ?? requested
            return AnalyzeUrl.legadoURLString(final: finalURL, requested: requested)
        }
        #expect(try read("https://www.520danmei.com/##") == "https://www.520danmei.com/##")
        // A response URL without the fragment is the same resource.
        #expect(try read("https://www.520danmei.com/##", final: "https://www.520danmei.com/") == "https://www.520danmei.com/##")
        #expect(try read(#"https://a.test/l#{"t":"排行","p":1}"#) == #"https://a.test/l#{"t":"排行","p":1}"#)
        // okhttp 5.3.2 encodes a control character in a fragment, nothing else — not a `%`.
        #expect(try read("https://a.test/#a\u{1}b%41 100%") == "https://a.test/#a%01b%41 100%")
        // A redirect's URL reads as it arrived.
        #expect(try read("https://a.test/##", final: "https://b.test/x") == "https://b.test/x")
        #expect(AnalyzeUrl.canonicalRequestURLString("https://a.test/#%41{x}") == "https://a.test/#%2541%7Bx%7D")

        let request = URLRequest(url: try #require(AnalyzeUrl.requestURL("https://www.520danmei.com/##")))
        let response = LegadoStrResponse(result: LegadoHTTPResult.make(request: request, data: Data(), response: nil))
        #expect(response.url() == "https://www.520danmei.com/##")
    }

    /// Index 635: an XPath chapter list read each node's string value, so `a@href` had no
    /// element to read — 0 chapters, against 1104 for the same list written in CSS.
    @Test("an XPath list hands its nodes to jsoup field rules")
    func xpathListNodesForJsoupFields() throws {
        let chapters = try Self.chapters(Self.tocSource(list: "//dd", name: "a@text", url: "a@href"))
        #expect(chapters.map(\.title) == ["第一章", "第二章"])
        #expect(chapters.map(\.url) == ["https://toc.test/c/1", "https://toc.test/c/2"])
    }

    /// JsoupXpath reads a rule with one leading `/` from the item it is given, as Legado's
    /// `AnalyzeByXPath(JXNode)` does: `/a/@href` is the item's link, `/@value` its own attribute.
    @Test("a single-slash XPath field rule reads from its list item")
    func xpathFieldRelativeToItem() throws {
        let links = try Self.chapters(Self.tocSource(list: "//dd", name: "/a/text()", url: "/a/@href"))
        #expect(links.map(\.title) == ["第一章", "第二章"])
        #expect(links.map(\.url) == ["https://toc.test/c/1", "https://toc.test/c/2"])

        let select = #"<select><option value="/p/1">第1頁</option><option value="/p/2">第2頁</option></select>"#
        let pages = try Self.chapters(
            Self.tocSource(list: "//select/option", name: "/text()", url: "/@value"), select
        )
        #expect(pages.map(\.title) == ["第1頁", "第2頁"])
        #expect(pages.map(\.url) == ["https://toc.test/p/1", "https://toc.test/p/2"])
    }

    /// Expected values: JsoupXpath 2.5.3 (the jar Legado pins) on this markup — `//@href` on an
    /// `a` row is `/c/1`, `/c/2`; `//li/a//@href` on an li row the same. 黑岩阅读 (YCK1330)
    /// reads each chapter link's `//@href`; 耽美小说 its search rows' `//h2/a//@href`.
    @Test("an X//@attr field rule reads the attribute of X and of everything under it")
    func xpathDescendantOrSelfAttribute() throws {
        let html = #"<ul><li><span>1</span><a href="/c/1">第一章</a></li><li><span>2</span><a href="/c/2">第二章</a></li></ul>"#
        let links = try Self.chapters(Self.tocSource(list: "//li[span]/a", name: "/text()", url: "//@href"), html)
        #expect(links.map(\.title) == ["第一章", "第二章"])
        #expect(links.map(\.url) == ["https://toc.test/c/1", "https://toc.test/c/2"])
        let rows = try Self.chapters(Self.tocSource(list: "//li", name: "/a/text()", url: "//li/a//@href"), html)
        #expect(rows.map(\.url) == ["https://toc.test/c/1", "https://toc.test/c/2"])
    }

    /// JsoupXpath reads jsoup's tree, where a table always has its `<tbody>`: the browser path
    /// `//div[@class='box_info']/table/tbody/tr[1]//h1/text()` (pack index 759) matches a page
    /// whose markup has none. libxml2's own HTML tree has no tbody there.
    @Test("an XPath through an implied tbody reads the page as jsoup builds it")
    func xpathThroughImpliedTbody() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://box.test"
        source.ruleBookInfo.name = "//div[@class='box_info']/table/tbody/tr[1]//h1/text()"
        source.ruleBookInfo.author = "//div[@class='box_info']/table/tbody/tr[1]/td/div/p[1]/a[1]/text()"
        let html = """
        <div class="box_info"><table>
        <tr><td><div><h1>書名甲</h1><p><a href="/a/1">作者乙</a><a href="/c/9">最新章</a></p></div></td></tr>
        </table></div>
        """
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: html, bookUrl: "https://box.test/b/1", baseURL: "https://box.test/b/1", source: source
        )
        #expect(book.name == "書名甲")
        #expect(book.author == "作者乙")
    }

    /// SwiftSoup prints an unmodified element's raw source when pretty-printing is off, and
    /// the `<tbody>` its tree builder implies is not in that source: the markup lost it although
    /// the tree had it, and XPath (libxml2 reads that markup) never saw it. jsoup prints it.
    @Test("an implied tbody is in the markup SwiftSoup prints")
    func impliedTbodySerialised() throws {
        let soup = try SwiftSoup.parse("<div><table>\n<tr><td>x</td></tr>\n</table></div>")
        soup.outputSettings().prettyPrint(pretty: false)
        let html = try soup.outerHtml()
        #expect(html.contains("<table>\n<tbody><tr><td>x</td></tr>\n</tbody></table>"))
        #expect(try soup.select("table > tbody > tr").count == 1)
    }

    /// Legado's `replaceRegex` under `###` keeps the first match alone, transformed, whatever
    /// the extraction rule before the `##`. 搜小说 (index 0) builds its TOC URL that way; keeping
    /// the text around the match made `https://www.sou78.com/chapterhttps://wap.sou78.com/…`.
    @Test("### keeps only the transformed first match after a selector rule")
    func replaceFirstAfterSelector() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://www.sou78.com/"
        source.ruleBookInfo.name = "h1@text"
        source.ruleBookInfo.tocUrl = ".mubtn@a@href##/(\\d+)##https://wap.sou78.com/info.php?aid=$1###"
        let html = #"<h1>高楼万丈</h1><div class="mubtn"><a href="/chapter/172275/">目录</a></div>"#
        let book = try ModernParserBridge(source: source).parseBookInfo(
            html: html, bookUrl: "https://www.sou78.com/book/172275/",
            baseURL: "https://www.sou78.com/book/172275/", source: source
        )
        #expect(book.tocUrl == "https://wap.sou78.com/info.php?aid=172275")

        #expect(RegexReplacer.replaceRegex(
            result: "abc123def456", pattern: "\\d+", replacement: "<$0>", replaceFirst: true
        ) == "<123>")
        #expect(RegexReplacer.replaceRegex(
            result: "abc", pattern: "\\d+", replacement: "x", replaceFirst: true
        ) == "")
    }

    /// Legado's `getElementsSingle` reads `tag.div.bg` as `getElementsByTag("div")` — the part
    /// after a second dot is dropped — and jsoup's collector includes the element itself. 瀚海书阁
    /// (index 88) reads its link off the list item with `tag.div.bg-light-secondary@onclick`.
    @Test("tag.name.extra reads the tag name only and includes the element itself")
    func tagRuleSecondDotDropped() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://hh.test"
        source.ruleSearch.bookList = "@css:div.card"
        source.ruleSearch.name = "tag.h3@text"
        source.ruleSearch.bookUrl = "tag.div.card@data-url"
        let html = """
        <div class="card" data-url="/b/1"><div><h3>第一本</h3></div></div>
        <div class="card" data-url="/b/2"><div><h3>第二本</h3></div></div>
        """
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://hh.test/s", source: source
        )
        #expect(books.map(\.bookUrl) == ["https://hh.test/b/1", "https://hh.test/b/2"])
    }

    /// Legado splits a rule on every `##` (`rule.split("##")`). Skipping the ones inside quotes
    /// lost the replacement of a regex with an odd number of `"`: 肉文屋 (index 55), 未来天王 and
    /// 起点中文's discover page all write `##<img\s*src="([^"]+)"##$1###`.
    @Test("## splits a rule even between quotes")
    func hashHashSplitIgnoresQuotes() {
        var rule = SourceRule(ruleStr: ###"##<img\s*src="([^"]+)"##$1###"###)
        rule.makeUpRule(result: nil, getData: { _ in "" }, evalJS: { _ in nil }, analyzeRule: { _ in nil })
        #expect(rule.rule == "")
        #expect(rule.replaceRegex == #"<img\s*src="([^"]+)""#)
        #expect(rule.replacement == "$1")
        #expect(rule.replaceFirst)

        // `@put` comes off before the split, as Legado's `splitPutRule` runs first: 夜寒书库's
        // put holds a `##` of its own.
        var put = SourceRule(ruleStr: #"@put:{w:"text.字数：@text##字数："}class.x@text"#)
        put.makeUpRule(result: nil, getData: { _ in "" }, evalJS: { _ in nil }, analyzeRule: { _ in nil })
        #expect(put.putMap["w"] == "text.字数：@text##字数：")
        #expect(put.rule == "class.x@text")
        #expect(put.replaceRegex.isEmpty)

        var trailing = SourceRule(ruleStr: "text##a##b##")
        trailing.makeUpRule(result: nil, getData: { _ in "" }, evalJS: { _ in nil }, analyzeRule: { _ in nil })
        #expect(trailing.replaceFirst)
    }

    /// Legado's BookList / BookChapterList drop a `+` after the reverse `-`. 8 TOCs in the pack
    /// start with one; po18城's `+<js>` failed with `result.replace is not a function`.
    @Test("a list rule's leading + is dropped, after a reversing -")
    func listPlusPrefix() throws {
        let plain = try Self.chapters(Self.tocSource(list: "+tag.dd", name: "a@text", url: "a@href"))
        #expect(plain.map(\.title) == ["第一章", "第二章"])

        // The `-` reverses the whole TOC once every page is read (LegadoBookStateTests): a page
        // keeps its order, and the `+` after it is still dropped.
        let reversed = try Self.chapters(Self.tocSource(list: "-+tag.dd", name: "a@text", url: "a@href"))
        #expect(reversed.map(\.title) == ["第一章", "第二章"])
        let split = ModernParserBridge.tocListRule("-+tag.dd")
        #expect(split.rule == "+tag.dd")
        #expect(split.reverses)

        let scripted = try Self.chapters(Self.tocSource(
            list: "+<js>result.replace(/第/g, '卷')</js>tag.dd", name: "a@text", url: "a@href"
        ))
        #expect(scripted.map(\.title) == ["卷一章", "卷二章"])
    }

    /// Index 11 (精华书阁): every search field is a path from the page's root —
    /// `@css:html > body > div.searchbook > div.bookinfo > h4.bookname a@text` — read against a
    /// `div.searchbook` row. jsoup 1.16.2, which Legado pins, walks a `>` chain past the row
    /// (`ImmediateParentRun`); upstream SwiftSoup stopped there and read nothing.
    @Test("a > chain reaches above the row it is read against, as in jsoup 1.16.2")
    func childChainAboveTheRow() {
        let engine = ModernRuleEngine()
        engine.setContent(
            #"<html><body><div class="searchbook"><div class="bookinfo"><h4 class="bookname"><a href="/1/">書甲</a></h4></div></div><div class="searchbook"><div class="bookinfo"><h4 class="bookname"><a href="/2/">書乙</a></h4></div></div></body></html>"#,
            baseUrl: "https://m.jhsssd.com/search.html"
        )
        let rows = engine.getElements(ruleStr: "@css:div.searchbook")
        #expect(rows.count == 2)
        let names = rows.map { row in
            ModernRuleEngine().setContent(row, baseUrl: "https://m.jhsssd.com/search.html")
                .getString(ruleStr: "@css:html > body > div.searchbook > div.bookinfo > h4.bookname a@text")
        }
        #expect(names == ["書甲", "書乙"])
        // A descendant step still stops at the row, as jsoup's `Parent` does: the other row's
        // link is not this row's.
        let first = ModernRuleEngine().setContent(rows[0], baseUrl: "https://m.jhsssd.com/search.html")
        #expect(first.getStringList(ruleStr: "@css:body a@text") == [])
    }

    /// Legado `getHeaderMap`: strict Gson, then lenient Gson, else only the default User-Agent.
    /// 猫眼看书 writes single quotes; 楠楠漫画's `Referer` string never closes.
    @Test("a header rule parses as Gson does: lenient JSON kept, broken JSON dropped whole")
    func headerRuleParse() async {
        var lenient = BookSource()
        lenient.bookSourceUrl = "https://lenient-header.test"
        lenient.header = "{ 'User-Agent': 'okhttp/4.9.2','client-version': '2.3.0', Retry: 2 }"
        #expect(await lenient.resolvedHeaders() == [
            "User-Agent": "okhttp/4.9.2", "client-version": "2.3.0", "Retry": "2"
        ])
        let lenientEngine = JSCoreEngine()
        lenientEngine.bookSource = lenient
        #expect(lenientEngine.resolvedSourceHeaders()["client-version"] == "2.3.0")

        var broken = BookSource()
        broken.bookSourceUrl = "https://broken-header.test"
        broken.header = #"{  "User-Agent": "Mozilla/5.0 (Linux; Android 8.1.0)", "Referer": "https://guiwb.nnmh.info/}"#
        #expect(await broken.resolvedHeaders() == ["User-Agent": BookSource.legadoDefaultUserAgent])
        let brokenEngine = JSCoreEngine()
        brokenEngine.bookSource = broken
        #expect(brokenEngine.resolvedSourceHeaders() == ["User-Agent": BookSource.legadoDefaultUserAgent])
    }

    /// 1331 存档书库 signs its login with `java.aesEncodeToBase64String`; legado's deprecated
    /// `aes*` helpers are all `createSymmetricCrypto(transformation, key, iv)` underneath.
    @Test("legado's aes* helpers encrypt and decrypt as createSymmetricCrypto does")
    func aesHelpers() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var k = '1234567890123456', t = 'AES/CBC/PKCS5Padding';
        var cbc = java.aesEncodeToBase64String('hello', k, t, k);
        [cbc, java.aesDecodeToString(cbc, k, t, k),
         java.aesEncodeArgsBase64Str('hello', k, 'ECB', 'PKCS5Padding', ''),
         java.aesDecodeArgsBase64Str(cbc, java.base64Encode(k), 'CBC', 'PKCS5Padding', java.base64Encode(k)),
         String(java.aesEncodeToBase64ByteArray('hello', k, 'AES/ECB/PKCS5Padding', '').length)].join('|');
        """)
        #expect(value == "ObBxtb9plyPvM6ZEdBv6MQ==|hello|67fHA+Z12z2jlwOLTBeCPA==|hello|24")
        #expect(engine.lastError == nil)
    }

    /// 1331 品书斋子: `bookSourceUrl` is `"https://www.pinshuzhai.com "` and `searchUrl`
    /// `page/{{page}}?s={{key}}`. Java's `URL` trims the base, so Legado searches
    /// `https://www.pinshuzhai.com/page/1?s=…`.
    @Test("a relative search URL resolves against a bookSourceUrl with a trailing space, as Java's URL")
    func baseWithTrailingSpace() {
        var source = BookSource()
        source.bookSourceUrl = "https://www.pinshuzhai.com "
        #expect(source.cleanedBookSourceURL == "https://www.pinshuzhai.com")
        #expect(RuleEngine.resolveURL("page/1?s=%E6%88%91", base: source.bookSourceUrl)
            == "https://www.pinshuzhai.com/page/1?s=%E6%88%91")
        // Java keeps the characters as written; Foundation would percent-encode them.
        #expect(RuleEngine.resolveURL("s.php?q=我的,{\"charset\":\"gbk\"}", base: "https://a.test/x/y.html")
            == "https://a.test/x/s.php?q=我的,{\"charset\":\"gbk\"}")
    }

    /// 1329 G站漫画 and the other qyyuapi sources: `jsLib` is `{"G站漫画": "https://…/jsLib.js"}`.
    /// Legado's `SharedJsScope` downloads each URL value with the bare client, keeps it by the
    /// URL's MD5 and evaluates the libraries in the object's order; other values are ignored.
    @Test("a JSON-object jsLib downloads its libraries in order, without source headers, and keeps them")
    func jsonObjectJsLib() throws {
        let run = UUID().uuidString
        let first = "https://lib.test/\(run)/a.js"
        let second = "https://lib.test/\(run)/b.js"
        defer {
            for url in [first, second] {
                let file = LegadoSharedJsLibrary.cacheDirectory
                    .appendingPathComponent(LegadoSharedJsLibrary.cacheKey(for: url) + ".js")
                try? FileManager.default.removeItem(at: file)
            }
        }
        var source = BookSource()
        source.bookSourceUrl = "https://jslib.test"
        source.bookSourceName = "jsLib fixture"
        source.header = #"{"X-Source":"yes"}"#
        source.jsLib = #"{"甲": "\#(first)", "說明": "not a library", "乙": "\#(second)"}"#
        source.ruleBookInfo.name = "@js:B_VALUE + '|' + typeof 說明"
        // The runtime downloads jsLib while it is built, before a test could swap its network
        // handler, so the libraries come from the session the bridge is given.
        let bridge = ModernParserBridge(source: source, requestSession: SharedJsLibURLProtocol.session())
        let book = try bridge.parseBookInfo(
            html: "<p></p>", bookUrl: "https://jslib.test/b", baseURL: "https://jslib.test/b", source: source
        )
        #expect(book.name == "ab|undefined")
        let sent = SharedJsLibURLProtocol.requests(containing: run)
        #expect(sent.map { $0.url!.absoluteString } == [first, second])
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-Source") == nil })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == BookSource.legadoDefaultUserAgent })

        // Kept: a second source naming the same library reads it without a request.
        let again = ModernParserBridge(source: source, requestSession: SharedJsLibURLProtocol.session())
        let second_ = try again.parseBookInfo(
            html: "<p></p>", bookUrl: "https://jslib.test/b", baseURL: "https://jslib.test/b", source: source
        )
        #expect(second_.name == "ab|undefined")
        #expect(SharedJsLibURLProtocol.requests(containing: run).count == 2)

        // Code that happens to sit in braces is still code.
        #expect(LegadoSharedJsLibrary.libraryURLs(in: "{ var a = 1; }") == nil)
        #expect(LegadoSharedJsLibrary.libraryURLs(in: "function f() {}") == nil)
    }

    /// G站漫画 (YCK1329) runs `JSON.parse(cache.get(md5 + "headers"))` on every search before it
    /// has saved anything: `null` under Rhino, and the SyntaxError
    /// `Unexpected identifier "undefined"` when a Swift nil crossed as `undefined`.
    @Test("a getter Legado declares nullable is null to the script, not undefined")
    func nullableGettersAreJavaNull() throws {
        let context = try #require(JSContext())
        let cache = LegadoCacheBridge(sourceId: "null-parity-\(UUID().uuidString)")
        let source = LegadoSourceBridge(source: BookSource())
        let javaMap = LegadoJavaMap(["A": "1"])
        let headerMap = LegadoHeaderMap(["Referer": "r"])
        context.setObject(cache, forKeyedSubscript: "cache" as NSString)
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        context.setObject(javaMap, forKeyedSubscript: "m" as NSString)
        context.setObject(headerMap, forKeyedSubscript: "h" as NSString)

        let result = context.evaluateScript("""
            [JSON.parse(cache.get('missing')) === null,
             cache.getFromMemory('missing') === null,
             cache.getFile('missing') === null,
             source.getLoginInfo() === null,
             source.getLoginHeader() === null,
             m.get('B') === null, m.put('B', '2') === null, m.put('B', '3') === '2', m.get('A') === '1',
             h.get('X') === null, h.remove('X') === null, h.put('X', 'x') === null,
             h.put('X', 'y') === 'x', h.remove('X') === 'y', h.get('Referer') === 'r'
            ].join(',') + '|' + (cache.put('k', 'v'), cache.get('k'))
            """)?.toString()

        #expect(result == Array(repeating: "true", count: 15).joined(separator: ",") + "|v")
        #expect(context.exception == nil)
        // The Swift twins keep `String?` for Swift callers.
        #expect(cache.get("missing") == nil)
        #expect(cache.get("k") == "v")
        cache.delete("k")
    }

    /// okhttp's and jsoup's `headers(name)` answer one header's values; 精品小说 (YCK1331) takes
    /// its search's redirect from `java.post(…).headers("location")[0]`.
    @Test("a response's headers(name) lists that header's values, headers() keeps the map")
    func responseHeadersByName() throws {
        let context = try #require(JSContext())
        let url = try #require(URL(string: "https://jp.example/e/search/indexsearch.php"))
        let response = LegadoStrResponse(result: LegadoHTTPResult(
            finalURL: url, statusCode: 302, statusMessage: "Found",
            headers: ["Location": "result/?searchid=12"], cookies: [:], body: ""
        ))
        context.setObject(response, forKeyedSubscript: "r" as NSString)

        let result = context.evaluateScript("""
            [r.headers('location')[0], r.headers('LOCATION').length, r.headers('x-none').length,
             r.headers().get('location'), r.header('Location')].join('|')
            """)?.toString()

        #expect(result == "result/?searchid=12|1|0|result/?searchid=12|result/?searchid=12")
        #expect(context.exception == nil)
    }

    /// 酷狗小说 (YCK1329)'s jsLib signs with `java.security.MessageDigest` inside a jsLib
    /// function, where Legado's `java` is Rhino's Java package; 听友在线 (YCK1331) reaches
    /// `javax.crypto.Cipher` without `Packages.`.
    @Test("java.* subpackages and Rhino's top-level package names resolve without Packages.")
    func rhinoTopLevelPackages() {
        var source = BookSource()
        source.bookSourceUrl = "packages-\(UUID().uuidString)"
        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate("""
            function b(str) {
                try {
                    var md = java.security.MessageDigest.getInstance("MD5");
                    var bytes = new java.lang.String(str).getBytes("UTF-8");
                    md.update(bytes);
                    var digest = md.digest(), hex = "";
                    for (var i = 0; i < digest.length; i++) {
                        var x = digest[i] & 0xFF;
                        if (x < 16) hex += "0";
                        hex += x.toString(16);
                    }
                    return hex;
                } catch (e) { return "ERR " + e; }
            }
            """)
        let result = engine.evaluate("""
            [b('abc'), typeof javax.crypto.Cipher.getInstance,
             android.util.Base64.encodeToString(java.util.Base64.getDecoder().decode('YWJj'), 2),
             java.md5Encode('abc')].join('|')
            """)
        #expect(result == "900150983cd24fb0d6963f7d28e17f72|function|YWJj|900150983cd24fb0d6963f7d28e17f72")
    }

    /// 酷狗小说 (YCK1329 #119, 1330 #293) calls its jsLib signer from the search URL's `@js:`,
    /// where `java` is that AnalyzeUrl (`LegadoAnalyzeUrlScriptView` over the bridge). The
    /// signature still came out empty there — `signature=&mid=1…`, answered `err signature`.
    @Test("a jsLib function reaches java.security from an AnalyzeUrl script, where java is the URL's")
    func jsLibJavaPackagesUnderAnalyzeUrlJava() {
        var source = BookSource()
        source.bookSourceUrl = "https://kugou-\(UUID().uuidString).test"
        source.jsLib = """
            function b(str) {
                try {
                    var md = java.security.MessageDigest.getInstance("MD5");
                    var bytes = new java.lang.String(str).getBytes("UTF-8");
                    md.update(bytes);
                    var digest = md.digest(), hex = "";
                    for (var i = 0; i < digest.length; i++) {
                        var x = digest[i] & 0xFF;
                        if (x < 16) hex += "0";
                        hex += x.toString(16);
                    }
                    return hex;
                } catch (e) { return "ERR-" + e; }
            }
            """
        let bridge = ModernParserBridge(source: source)
        let parsed = AnalyzeUrl(
            ruleUrl: "@js:'https://h.test/s?signature=' + b('abc')", page: 1,
            baseUrl: source.bookSourceUrl,
            jsEvaluator: { code, bindings in bridge.evaluateSourceScript(code, bindings: bindings) }
        )
        #expect(parsed.url == "https://h.test/s?signature=900150983cd24fb0d6963f7d28e17f72")
    }

    /// 言情小说 (YCK1330 #652, 1329 #263) POSTs its search form with
    /// `java.connect('…/index.php,{"method":"POST",…}')` and reads where it landed from
    /// `res.raw().request().url()`. A URL with options goes the AnalyzeUrl route, whose result
    /// was rebuilt from the URL asked for: `index.php`, status 200, no headers. Legado's
    /// `connect` answers `AnalyzeUrl.getStrResponseAwait()`, the okhttp response itself.
    @Test("java.connect on the AnalyzeUrl route keeps the response's URL, status and headers")
    func connectWithOptionsKeepsResponse() {
        var source = BookSource()
        source.bookSourceUrl = "https://connect-route-\(UUID().uuidString).test"
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request, _ in
            LegadoHTTPResult(
                finalURL: URL(string: "https://m.bg.test/e/search/result/?searchid=24")!,
                statusCode: 201, statusMessage: "Created", headers: ["X-Route": "analyzeUrl"],
                cookies: ["sid": "7"], body: request.httpMethod ?? "", requestedURL: request.url
            )
        }
        let value = bridge.evaluateSourceScript("""
            var res = java.connect('https://m.bg.test/e/search/index.php,{"body":"keyboard=k","method":"POST"}');
            [res.raw().request().url(), res.url(), res.code(), res.header('X-Route'),
             res.cookie('sid'), res.body()].join('|')
            """)
        #expect(value == "https://m.bg.test/e/search/result/?searchid=24|https://m.bg.test/e/search/result/?searchid=24|201|analyzeUrl|7|POST")
    }

    /// 漫画戏说 (YCK1329): `q={{key}}&sa=搜尋` — the keyword arrives encoded beside raw CJK,
    /// and Foundation encoded the keyword's `%` a second time.
    @Test("a half-encoded request URL keeps its %XX and encodes the rest once, as OkHttp does")
    func requestURLKeepsPercentEscapes() {
        let search = "https://comic.acgn.cc/searchcse?ie=UTF-8&q=%E6%88%91%E7%9A%84&sa=搜尋"
        let expected = "https://comic.acgn.cc/searchcse?ie=UTF-8&q=%E6%88%91%E7%9A%84&sa=%E6%90%9C%E5%B0%8B"
        #expect(AnalyzeUrl.requestURL(search)?.absoluteString == expected)
        #expect(safeURL(string: search)?.absoluteString == expected)

        #expect(AnalyzeUrl.canonicalRequestURLString(" https://a.com/书/%E6%88%91.html?x={1}|2&p=100%#a#b\n")
            == "https://a.com/%E4%B9%A6/%E6%88%91.html?x=%7B1%7D%7C2&p=100%25#a%23b")
        // A URL a script joined across lines, as HttpUrl reads it.
        #expect(AnalyzeUrl.canonicalRequestURLString("https://a.com/p?a=1&\n\tb=2") == "https://a.com/p?a=1&b=2")
        // Already valid: unchanged, `%xx` case and all.
        #expect(AnalyzeUrl.canonicalRequestURLString("https://a.com/s?q=%e6%88%91&t='a'(b)")
            == "https://a.com/s?q=%e6%88%91&t='a'(b)")
        // No scheme: nothing is taken for an authority.
        #expect(AnalyzeUrl.canonicalRequestURLString("/书?u=http://x") == "/%E4%B9%A6?u=http://x")
    }

    /// 男友书屋 (YCK1329): a GBK page, already decoded, that libxml2 decoded again as GBK from
    /// its own `<meta charset>`; and a content rule that selects the chapter's element.
    @Test("XPath reads a page that declares GBK, and an element with no accessor is its outer HTML")
    func xpathOnDeclaredCharsetPages() throws {
        let extractor = XPathExtractor()
        let rule = "//div[contains(@class, 'panel-body') and contains(@class, 'content-body')]"
        for head in [
            #"<meta charset="gbk">"#,
            #"<meta http-equiv="Content-Type" content="text/html; charset=gb2312">"#,
        ] {
            let page = """
                <!DOCTYPE html><html><head>\(head)<title>第一章</title></head><body>
                <div class="panel-body content-body content-ext">第一段<br />第二段</div></body></html>
                """
            let content = try extractor.extractValue(from: page, rule: rule, baseURL: "https://www.nanyou15.com")
            #expect(content.hasPrefix("<div"), "\(head)")
            #expect(content.contains("第一段") && content.contains("<br") && content.contains("第二段"), "\(head)")
            #expect(try extractor.extractValue(from: page, rule: "//title/text()", baseURL: "") == "第一章")
        }
        let feed = #"<?xml version="1.0" encoding="gbk"?><rss><item><title>中文标题</title></item></rss>"#
        #expect(try extractor.extractValue(from: feed, rule: "//item/title/text()", baseURL: "") == "中文标题")
    }

    /// 有声骚麦 (YCK1330 #371): `book.bookUrl + "#" + String(result)` — the play page, then the
    /// chapter's element. Legado requests it as written (`BookChapter.getAbsoluteURL`,
    /// `AnalyzeUrl.initUrl`); taken for a link, the fragment's `data-src` was fetched instead.
    @Test("markup in a chapter URL's fragment is the URL's text; a URL that is markup still gives its link")
    func chapterURLFragmentMarkupStays() {
        let chapter = #"https://www.yssm.test/play.php?id=65#<div class="audio-item" data-src="/upload/audio/1.mp3" data-subtitle="第一集">第一集</div>"#
        #expect(RuleEngine.sanitizeExtractedURL(chapter) == chapter)
        #expect(RuleEngine.sanitizeExtractedURL(" \(chapter)\n") == chapter)
        #expect(RuleEngine.sanitizeExtractedURL("https://a.test/play?id=1#%3Cdiv%20data-src=%22/x.mp3%22%3E") == "https://a.test/play?id=1#%3Cdiv%20data-src=%22/x.mp3%22%3E")
        var ref = OnlineChapterRef(index: 0, title: "第一集", url: chapter)
        #expect(ref.sanitizedContentURL == chapter)

        // Markup outside a fragment: the old chapter lists' links.
        #expect(RuleEngine.sanitizeExtractedURL(#"<a href="/1.html#top">第一章</a>"#) == "/1.html#top")
        #expect(RuleEngine.sanitizeExtractedURL(#"https://a.test/<a href="/2.html">第二章</a>"#) == "/2.html")
        #expect(RuleEngine.sanitizeExtractedURL("https://a.test/%3Ca%20href=%22/3.html%22%3Ex%3C/a%3E#f") == "/3.html")
        ref.url = "https://a.test/4.html#p2"
        #expect(ref.sanitizedContentURL == "https://a.test/4.html#p2")
    }

    /// 新龙小说 (YCK1330 #290): `<a class="title" href="…" class="r">` on its category pages.
    /// jsoup 1.16.2 keeps an element's first attribute of a name (`Attributes.deduplicate` in
    /// `HtmlTreeBuilder`/`XmlTreeBuilder`): HTML names compared ignoring case, XML names as
    /// written. SwiftSoup kept the last, so the discover rule's `.title@text` read no name.
    @Test("an element's duplicate attributes keep the first, as jsoup does")
    func duplicateAttributesKeepFirst() throws {
        let unit = #"<div class="u"><p><a class="title" href="/book/1/" class="r">失败的妻子们</a><a class="read" href="/book/1/">阅读</a></p></div>"#
        let page = try SwiftSoup.parse(unit)
        let title = try #require(try page.select("a").first())
        #expect(try title.attr("class") == "title")
        #expect(try page.select(".title").count == 1)
        #expect(try page.select(".r").isEmpty())
        #expect(try title.outerHtml() == #"<a class="title" href="/book/1/">失败的妻子们</a>"#)
        #expect(try SwiftSoup.parse(#"<b CLASS="x" class="y" Id="1" id="2">b</b>"#).select("b").first()?.outerHtml()
            == #"<b class="x" id="1">b</b>"#)

        let xml = try SwiftSoup.parse(#"<x A="1" a="2" A="3"/>"#, "", Parser.xmlParser())
        let element = try #require(try xml.select("x").first())
        let pairs = (element.getAttributes()?.asList() ?? []).map { "\($0.getKey())=\($0.getValue())" }
        #expect(pairs == ["A=1", "a=2"])

        let engine = ModernRuleEngine()
        engine.setContent(unit, baseUrl: "https://www.longshuwu.test")
        #expect(engine.getString(ruleStr: "span.1@a@text||.title@text") == "失败的妻子们")
    }
}

/// Serves `https://lib.test/<run>/a.js` and `…/b.js` for `jsonObjectJsLib`, and records what it
/// was asked for.
private final class SharedJsLibURLProtocol: URLProtocol {
    private static let log = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedJsLibURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requests(containing run: String) -> [URLRequest] {
        log.withLock { $0 }.filter { $0.url?.absoluteString.contains(run) == true }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lib.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let received = request
        guard let url = received.url else { return }
        Self.log.withLock { $0.append(received) }
        let script = url.path.hasSuffix("a.js") ? "function A() { return 'a'; }" : "var B_VALUE = A() + 'b';"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/javascript"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(script.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
