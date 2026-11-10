import Foundation
import Testing
@testable import yuedu_app

/// The Rhino-vs-JavaScriptCore gaps from diagnostic report YD-3H4Q-MRDV (1204 sources):
/// each test pins what Legado's own runtime does for a call a real source makes.
@Suite("Legado jsoup bridge compatibility", .serialized)
struct LegadoJsoupBridgeCompatibilityTests {

    // MARK: - Elements a rule hands a script

    /// The chapter titles of a TOC whose list is `.x` and whose chapter name is `script`.
    private func scriptChapterNames(_ html: String, _ script: String) throws -> [String] {
        var source = BookSource()
        source.bookSourceUrl = "https://attached.test"
        source.ruleToc.chapterList = ".x"
        source.ruleToc.chapterName = "@js:" + script
        source.ruleToc.chapterUrl = "@href"
        return try ModernParserBridge(source: source).parseTOC(
            html: html, baseURL: "https://attached.test/b", source: source
        ).map(\.title)
    }

    /// A list item a rule hands a script is the element inside its page, as in Legado: 轻之文库
    /// (YCK1331) names each chapter from its volume, five `parentNode()` up. It used to be a copy
    /// of the item alone, with no parent. Expected values are Rhino 1.8.1 + jsoup 1.16.2's, from
    /// `scripts/legado-compat/oracle/cases/attached-element-toc.json` (case names in comments).
    @Test("a list item handed to a script keeps its page: ancestors, siblings, closest")
    func scriptListItemKeepsItsPage() throws {
        // 轻之文库 chapterName: five parentNode() up, then select('h2')
        #expect(try scriptChapterNames(
            "<div class='vol'><h2>卷一</h2><ul><li><span><b><a class='x' href='/1'>第一章</a></b></span></li></ul></div>",
            "var title = result.parentNode().parentNode().parentNode().parentNode().parentNode(); title.select('h2').text() + '：' + result.text()"
        ) == ["卷一：第一章"])
        // parent, parents, tagName
        #expect(try scriptChapterNames(
            "<div id='a'><p><i class='x' href='/1'>t</i></p></div>",
            "[result.parent().tagName(), result.parents().size(), result.parents().get(1).id()].join('|')"
        ) == ["p|4|a"])
        // siblings
        #expect(try scriptChapterNames(
            "<ul><li>a</li><li class='x' href='/1'>b</li><li>c</li></ul>",
            "[result.elementSiblingIndex(), result.nextElementSibling().text(), result.previousElementSibling().text(), result.siblingElements().size()].join('|')"
        ) == ["1|c|a|2"])
        // closest
        #expect(try scriptChapterNames(
            "<div class='box'><section><p><a class='x' href='/1'>t</a></p></section></div>",
            "[result.closest('div.box').className(), result.closest('section').tagName(), result.closest('table')].join('|')"
        ) == ["box|section|"])
    }

    /// What a script changes is the page, which every later read sees — Legado's scripts edit
    /// the page they were handed. Oracle: `attached-element-toc.json`.
    @Test("a script's change to its page is seen by the next read and by the next item")
    func scriptChangesItsPage() throws {
        // removing the item is seen by the next read of its page
        #expect(try scriptChapterNames(
            "<ul><li class='x' href='/1'>a</li><li>b</li></ul>",
            "var ul = result.parent(); result.remove(); [ul.children().size(), ul.text()].join('|')"
        ) == ["1|b"])
        // one page for every item: what a script removes, the next item's script no longer sees
        #expect(try scriptChapterNames(
            "<ul><li class='x' href='/1'>a</li><li class='x' href='/2'>b</li></ul>",
            "var n = result.parent().children().size(); result.remove(); String(n)"
        ) == ["2", "1"])
    }

    /// jsoup's `Node.equals` is identity, and `List.contains`/`indexOf` use it: 掌阅书城
    /// (YCK1329) drops nested matches with `parents().contains(c)`. Oracle:
    /// `attached-element-toc.json`. Its last case — `==` on two reads of one node, true in
    /// Rhino — is not here: JavaScriptCore's `==` compares the two wrapper objects.
    @Test("an element found again by another path is the same element")
    func elementIdentityAcrossReads() throws {
        #expect(try scriptChapterNames(
            "<div class='a'><ul><li class='x' href='/1'>a</li><li>b</li></ul></div>",
            "var c = result.parent().parent(); [result.parents().contains(c), result.parent().children().indexOf(result), c.select('li').contains(result), c.select('li').get(0).equals(result), c.select('li').get(1).equals(result)].join('|')"
        ) == ["true|0|true|true|false"])
    }

    /// The page copies go when the parse that made them ends, as the engine's own documents
    /// do: one kept per JSContext would hold a page in each session `BookSourceSession` keeps.
    @Test("the page copies a parse handed its scripts go when the parse ends")
    func scriptPageCopiesEndWithTheParse() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://attached.test"
        source.ruleToc.chapterList = ".x"
        source.ruleToc.chapterName = "@js:result.parent().children().size() + ''"
        source.ruleToc.chapterUrl = "@href"
        let parser = ModernParserBridge(source: source)
        let chapters = try parser.parseTOC(
            html: "<ul><li class='x' href='/1'>a</li><li>b</li></ul>", baseURL: "https://attached.test/b", source: source
        )
        #expect(chapters.map(\.title) == ["2"])
        #expect(parser.heldScriptPageCount == 0)
    }

    // MARK: - jsoup

    @Test("selectFirst answers the first match or null, on documents and elements")
    func selectFirst() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var doc = org.jsoup.Jsoup.parse('<div><dl><dt><a href="/b">x</a></dt></dl></div>', 'https://a.example/');
        [doc.selectFirst('dt a').text(), doc.selectFirst('nope') === null,
         doc.select('dl').get(0).selectFirst('a').attr('href'), typeof doc.select('dl').selectFirst].join('|');
        """)
        // jsoup 1.16.2 (the version Legado pins) has no `Elements.selectFirst`.
        #expect(value == "x|true|/b|undefined")
        #expect(engine.lastError == nil)
    }

    /// Expected values are Rhino 1.8.1 + jsoup 1.16.2's, from
    /// `scripts/legado-compat/oracle/cases/elements-hasclass.json` (`lc.py oracle`). 1016
    /// exceptions in the 2026-11-08 audit came from `result.select(…).hasClass(…)`.
    @Test("hasClass on Elements and Element answers as jsoup does")
    func hasClassMatchesJsoup() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        function d(h) { return org.jsoup.Jsoup.parse(h); }
        var two = d("<div class='a b'>x</div><div class='c'>y</div>");
        [two.select('div').hasClass('b'),                                   // one element of several has it
         two.select('div').hasClass('d'),                                   // none has it
         d("<div class='a'>x</div>").select('span').hasClass('a'),          // empty selection
         d("<div class='Active'>x</div>").select('div').hasClass('active'), // Elements: case-insensitive
         d("<div class='Active'>x</div>").selectFirst('div').hasClass('ACTIVE'), // Element: case-insensitive
         d("<div class='a\\tb\\nc'>x</div>").selectFirst('div').hasClass('b'),   // tab separates classes
         d("<div class='a\\tb\\nc'>x</div>").selectFirst('div').hasClass('c'),   // newline separates classes
         d("<div class='active-item'>x</div>").selectFirst('div').hasClass('active'), // a prefix is not the class
         d("<ul><li class='chapter vip'>1</li></ul>").selectFirst('ul').select('li').hasClass('vip'),
        ].join('|');
        """)
        #expect(value == "true|false|false|true|true|true|true|false|true")
        #expect(engine.lastError == nil)
    }

    @Test("Elements is a Java List: toArray, numeric index, and for-in over indices only")
    func elementsBehaveAsJavaList() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var doc = org.jsoup.Jsoup.parse('<ul><li>a</li><li>b</li></ul>');
        var lis = doc.select('li');
        var keys = [];
        for (var k in lis) keys.push(k);
        var arr = lis.toArray();
        [Array.isArray(arr), arr.length, arr.at(-1).text(), lis[0].text(), lis[1].text(),
         lis[2] === undefined, keys.join(','), lis.size(), lis.get(1).text(), JSON.stringify(lis)].join('|');
        """)
        #expect(value == #"true|2|b|a|b|true|0,1|2|b|["<li>a</li>","<li>b</li>"]"#)
        #expect(engine.lastError == nil)
    }

    /// 回饋中心 #124: 🥝猕猴桃漫画's exploreUrl and jsLib, verbatim. The site lives in the source
    /// variable `jsLib`'s `Url()` reads, and its `/cate` page comes from `KiwiCateURLProtocol`;
    /// so the test also covers `const { source, java } = this` inside a jsLib function.
    @Test("🥝猕猴桃漫画's explore rule lists the last tag block's tags")
    func kiwiComicExploreTags() async throws {
        var source = BookSource()
        source.bookSourceName = "🥝猕猴桃漫画"
        source.bookSourceUrl = "https://kiwi-\(UUID().uuidString).test"
        source.enabledExplore = true
        source.jsLib = Self.kiwiJsLib
        source.exploreUrl = Self.kiwiExploreUrl
        let store = BookSourceRuntimeStateStore.shared
        store.setSourceVariableJSON(#"{"sourceurl":"https://\#(KiwiCateURLProtocol.host)"}"#, for: source.bookSourceUrl)
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }

        let items = try await SourceScriptHost(bridgeFor: source, requestSession: KiwiCateURLProtocol.session())
            .getExploreItems(page: 1)

        #expect(items.map(\.title) == ["全部", "热血", "恋爱"])
        #expect(items.map { $0.url?.hasPrefix("{{Url()}}/api/cate") } == [true, true, true])
        #expect(items.dropFirst().first?.url?.contains(#"\"tag\":\"热血\""#) == true)
    }

    /// A rule that throws has categories we failed to read. Returning [] made 回饋中心 #124's
    /// TypeError read as 「暫無發現內容」, a source with nothing to show.
    @Test("an explore rule whose JS throws is an error, not an empty category list")
    func throwingExploreRuleIsAnError() async {
        var source = BookSource()
        source.bookSourceName = "explore throws"
        source.bookSourceUrl = "https://explore-throws-\(UUID().uuidString).test"
        source.enabledExplore = true
        source.exploreUrl = "@js:\nvar tags = undefined; tags.toArray();"

        await #expect(throws: ModernParserBridge.ExploreScriptError.self) {
            try await SourceScriptHost(bridgeFor: source).getExploreItems(page: 1)
        }
        await #expect(throws: ModernParserBridge.ExploreScriptError.self) {
            try await BookSourceFetcher.shared.discoverItems(page: 1, in: source)
        }
    }

    @Test("an element returned from a script reads as its outer HTML")
    func elementResultIsOuterHTML() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("org.jsoup.Jsoup.parse('<p class=\"c\">x</p>').selectFirst('p')") == "<p class=\"c\">x</p>")
    }

    @Test("select throws jsoup's SelectorParseException for Legado rule syntax")
    func selectThrowsForUnparseableQuery() {
        let engine = JSCoreEngine()
        let caught = engine.evaluate("""
        var doc = org.jsoup.Jsoup.parse('<ul id="ul_all_chapters"><li>a</li><li>b</li></ul>');
        var caught = 'no throw';
        try { doc.select('[id="ul_all_chapters"]@li'); } catch (e) { caught = String(e); }
        [caught.indexOf('SelectorParseException') >= 0, doc.select('[id="ul_all_chapters"] li').size()].join('|');
        """)
        #expect(caught == "true|2")

        #expect(engine.evaluate("org.jsoup.Jsoup.parse('<p>').select('[id=\"ul_all_chapters\"]@li').size()") == nil)
        #expect(engine.lastError?.contains("SelectorParseException") == true)
    }

    @Test("chapterList JS can return jsoup Elements, or an array of them, as the list")
    func chapterListReturnsJsoupElements() throws {
        let lists = [
            "doc.select('#list a')",
            "var rows = []; doc.select('#list a').forEach(function (a) { rows.push(a); }); rows",
        ]
        for list in lists {
            var source = BookSource()
            source.bookSourceUrl = "jsoup-elements-toc-\(UUID().uuidString)"
            source.ruleToc.chapterList = "@js:\nvar doc = org.jsoup.Jsoup.parse(result, baseUrl);\n\(list)"
            source.ruleToc.chapterName = "@text"
            source.ruleToc.chapterUrl = "@href"

            let chapters = try ModernParserBridge(source: source).parseTOC(
                html: #"<div id="list"><a href="/1">First</a><a href="/2">Second</a></div>"#,
                baseURL: "https://example.com/book",
                source: source
            )

            #expect(chapters.map(\.title) == ["First", "Second"], "\(list)")
            #expect(chapters.map(\.url) == ["https://example.com/1", "https://example.com/2"], "\(list)")
        }
    }

    // MARK: - StrResponse.url()

    @Test("StrResponse.url() is a method, as in every Legado fork")
    func strResponseURLIsAMethod() {
        let engine = JSCoreEngine()
        let response = LegadoStrResponse(result: LegadoHTTPResult(
            finalURL: URL(string: "https://example.com/final")!,
            statusCode: 200,
            statusMessage: "OK",
            headers: [:],
            cookies: [:],
            body: "ok"
        ))
        #expect(engine.evaluate("typeof result.url + '|' + result.url()", result: response) == "function|https://example.com/final")
        // Under Rhino `result.body` is the Java method: 台湾小说's (YCK1331) loginCheckJs reads
        // it with `typeof b === 'function' ? b.call(result) : b`.
        #expect(engine.evaluate(
            "var b = result.body; if (typeof b === 'function') b = b.call(result); "
                + "var c = result.code; if (typeof c === 'function') c = c.call(result); "
                + "String(b) + '|' + c + '|' + result.url.apply(result, [])",
            result: response
        ) == "ok|200|https://example.com/final")
    }

    @Test("each loginCheckJs run has a scope of its own, as Legado's evalJS does")
    func loginCheckRunsInItsOwnScope() {
        let engine = JSCoreEngine()
        let response = LegadoStrResponse(result: LegadoHTTPResult(
            finalURL: URL(string: "https://example.com/api-info-1")!,
            statusCode: 200,
            statusMessage: "OK",
            headers: [:],
            cookies: [:],
            body: "packed"
        ))
        // 三爱小说 (YCK1331) opens its check with `let url`; the second response's check used
        // to fail with "Can't create duplicate variable: 'url'" and leave the body packed.
        let check = """
        let url = result.url()
        let body = result.body()
        if (url.includes('format=g2')) {
          Packages.io.legado.app.help.http.StrResponse(url, body)
        } else {
          Packages.io.legado.app.help.http.StrResponse(url, 'unpacked:' + body)
        }
        """
        for _ in 0..<2 {
            #expect(engine.evaluateResponseScript(check, response: response).body() == "unpacked:packed")
            #expect(engine.lastError == nil)
        }
    }

    // MARK: - Header JS

    @Test("header JS sees baseUrl as the source URL, and the running rule keeps its own")
    func headerJSBaseURL() {
        var source = BookSource()
        source.bookSourceUrl = "https://header-base.example"
        source.header = "@js:JSON.stringify({Referer: baseUrl})"
        let engine = JSCoreEngine()
        engine.bookSource = source
        engine.networkHandler = { request, _ in
            .bodyOnly(request: request, body: request.value(forHTTPHeaderField: "Referer") ?? "-")
        }

        // The header rule first runs inside this rule's `java.ajax`.
        let value = engine.evaluate(
            "java.ajax('https://header-base.example/api') + '|' + baseUrl",
            bindings: ["baseUrl": "https://header-base.example/book/1"]
        )
        #expect(value == "https://header-base.example|https://header-base.example/book/1")
        #expect(engine.resolvedSourceHeaders()["Referer"] == "https://header-base.example")
    }

    // MARK: - Java String length() and eval'd source

    @Test("the normalizer routes Java length() calls and direct eval arguments")
    func normalizerRewrites() {
        let input = "k.length(); a.length; s.length(1); 'x.length()'; eval(code); eval('y.length()'); eval(); obj.eval(code); function eval(x) {}"
        let once = LegadoRhinoNormalizer.normalize(input)
        #expect(once.source == "k.__yueduJavaLength(); a.length; s.length(1); 'x.length()'; eval(__yueduRhinoSource(code)); eval(__yueduRhinoSource('y.length()')); eval(); obj.eval(code); function eval(x) {}")
        #expect(LegadoRhinoNormalizer.normalize(once.source).source == once.source)
    }

    @Test("a java.* string answers Java's length(), in rules and in eval'd source")
    func javaStringLength() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("var k = java.digestHex('abc', 'sha-256'); k.length()") == "64")
        #expect(engine.evaluate("var code = 'var k = \"abcd\"; k.length()'; eval(code)") == "4")
        // Still a direct eval: the evaluated code sees the caller's locals.
        #expect(engine.evaluate("(function () { var local = 'xyz'; return eval('local.length()'); })()") == "3")
        #expect(engine.evaluate("({ length: function () { return 7; } }).length()") == "7")
        #expect(engine.evaluate("String(eval(42))") == "42")
        #expect(engine.lastError == nil)
    }

    /// Expected values: rhino 1.8.1, `oracle/cases/string-replaceall-regexp.json` — a wrapped
    /// Java String (every `java.*` result on Legado) reads a RegExp as its `/source/` text.
    /// 紫云宫 (YCK1330) strips zero-width characters from each decrypted chapter this way.
    @Test("replaceAll with a non-global RegExp is a Java String's replaceAll")
    func javaStringReplaceAllRegExp() {
        let engine = JSCoreEngine()
        // "wrapped Java String .replaceAll(non-global RegExp, '') on text with U+200B"
        #expect(engine.evaluate(#"escape('a\u200Bb/\u200A/c'.replaceAll(/[\u200A-\u200F]/, ''))"#) == "a%u200Bbc")
        // "… (non-global RegExp with a group, '[$1]'): Java's $1"
        #expect(engine.evaluate("'x/b/y b'.replaceAll(/(b)/, '[$1]')") == "x[b]y b")
        #expect(engine.lastError == nil)
        // "… (RegExp valid in JS, invalid as a Java regex)": Java's PatternSyntaxException.
        #expect(engine.evaluate(
            #"try { 'a p'.replaceAll(/\p/, ''); 'replaced' } catch (e) { String(String(e).indexOf('java.util.regex.PatternSyntaxException') >= 0) }"#
        ) == "true")
        // What both engines do alike keeps JS's meaning: "JS string .replaceAll(global RegExp,
        // '')" and "JS string .replaceAll(string, string) is literal".
        #expect(engine.evaluate(#"escape('a\u200Bb'.replaceAll(/[\u200A-\u200F]/g, ''))"#) == "ab")
        #expect(engine.evaluate("'a.b.c'.replaceAll('.', '-')") == "a-b-c")
    }

    @Test("Integer.parseInt has Java's radix and NumberFormatException behaviour")
    func integerParseInt() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("String(Packages.java.lang.Integer.parseInt('ff', 16))") == "255")
        #expect(engine.evaluate("String(Packages.java.lang.Integer.parseInt('-12'))") == "-12")
        #expect(engine.evaluate(
            "try { Packages.java.lang.Integer.parseInt('12px'); 'parsed' } catch (e) { String(e) }"
        ) == #"Error: java.lang.NumberFormatException: For input string: "12px""#)
        #expect(engine.evaluate(
            "try { Packages.java.lang.Integer.parseInt('2147483648'); 'parsed' } catch (e) { 'overflow' }"
        ) == "overflow")
    }

    @Test("new String(bytes) replaces malformed UTF-8 the way Android does")
    func javaStringMalformedUTF8() {
        let engine = JSCoreEngine()
        func units(_ bytes: String) -> String? {
            engine.evaluate("Array.prototype.map.call(String(new Packages.java.lang.String([\(bytes)])), function (c) { return c.charCodeAt(0); }).join(',')")
        }
        // The example in ART's StringFactory: maximal subparts "C0", "AF", "F4 80 80".
        #expect(units("0x41,0xC0,0xAF,0x41,0xF4,0x80,0x80,0x41") == "65,65533,65533,65,65533,65")
        // An encoded surrogate is three malformed bytes.
        #expect(units("0x41,0xED,0xA0,0x80,0x41") == "65,65533,65533,65533,65")
        #expect(units("0xF0,0x9F,0x98,0x80,0xE4,0xB8,0xAD") == "55357,56832,20013")
    }

    /// 小小阅读 keeps this decoder in `bookSourceComment` and runs it with
    /// `eval(String(source.bookSourceComment))`. The vector was built in Java the way the
    /// source reads it, with malformed UTF-8 in the salt and tail, and Rhino 1.8.1 running
    /// this same script decodes it to the plaintext below.
    @Test("小小阅读's decoder runs unchanged through eval")
    func xiaoxiaoDecoder() {
        var source = BookSource()
        source.bookSourceUrl = "https://xxyd.example"
        source.bookSourceComment = Self.xiaoxiaoDecoderScript
        let engine = JSCoreEngine()
        engine.bookSource = source

        let value = engine.evaluateIsolated(
            "eval(String(source.bookSourceComment));\nresult = decode(result);",
            result: Self.xiaoxiaoVector
        )
        #expect(value == #"{"data":{"book":[{"name":"小小阅读测试","author":"作者"}]}}"#)
        #expect(engine.lastError == nil)
    }

    private static let xiaoxiaoVector = "/8Mo4oJB8J+YgPiIgMCvejMJ4cqvwYYpinZ+xXR0c4k5UezpnVNPNqk9Mwbu9d5sE3PVsWW+Ok0kf/KjGOl1JyLrmZYwSmgD1wgECSgA71lafUxecjbRCvV3UpLL5Es0gOaWh/SQgIAx4ID+wgDvvw=="

    private static let xiaoxiaoDecoderScript = #"""
    var javaImport = new JavaImporter();
    javaImport.importPackage(
        Packages.java.lang,
        Packages.javax.crypto.spec,
        Packages.javax.crypto,
        Packages.java.util,
        Packages.java.io
    );
    with(javaImport) {
        function decode(str) {
            data=java.base64DecodeToByteArray(str);
            datas=Arrays.copyOfRange(data,16,data.length-16);
            k=String(Arrays.copyOfRange(data, 0, 16));
            k=java.digestHex(k,'sha-256');
            ks=[];
            length = k.length();
            if (length % 2 == 1) {
                length++;
                k = "0" + k;
            }
            i = 0;
            i2 = 0;
            while (i < length) {
                i3 = i + 2;
    ks[i2] =intToByte( Integer.parseInt(k.substring(i, i3),16));
                i2++;
                i = i3;
            }
            i=String(Arrays.copyOfRange(data,data.length-16, data.length));
             v=java.md5Encode(i);
            bytes = i.getBytes();
            bytes2 = v.getBytes();
            ivs=[];
            for (i = 0; i < 16; i++) {
                ivs[i] = (bytes2[i] ^ bytes[i]) ^ (-1);
            }
           key = SecretKeySpec(ks, "AES");
           iv = IvParameterSpec(ivs);
            var chipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            chipher.init(2, key, iv);
            return String(chipher.doFinal(datas));
        }
    }
    function intToByte(i) {
            var b = i & 0xFF;
            var c = 0;
            if (b >= 128) {
                c = b % 128;
                c = -1 * (128 - c);
            } else {
                c = b;
            }
            return c;
        }
    """#

    // MARK: - 🥝猕猴桃漫画 (回饋中心 #124)

    private static let kiwiJsLib = #"""
    function Url() {
        const { source, java } = this;
        var original = {
            "sourceurl": "https://www.mhtmh.com",
            "imageSourceUrl": "",
            "Urls": [],
            "imageSource": []
        };
        if (source.getVariable() == '') {
            source.setVariable(JSON.stringify(original, null, "\t"));
            java.toast('已初始化');
        }
        return JSON.parse(source.getVariable()).sourceurl;
    }
    """#

    private static let kiwiExploreUrl = #"""
    @js:
    var result = [];
    var push = (title, tag, p, size) => result.push({
        title: title,
        url: `{{Url()}}/api${p}` + "," + JSON.stringify({
      "body": `{\"page\":{\"page\":{{page}},\"pageSize\":10},\"category\":\"comic\",\"sort\":0,\"comic\":{\"status\":-1,\"day\":0,\"tag\":\"${tag}\"},\"video\":{\"year\":0,\"typeId\":0,\"typeId1\":0,\"area\":\"\",\"lang\":\"\",\"status\":-1,\"day\":0},\"novel\":{\"status\":-1,\"day\":0,\"sortId\":0}}`,
      "method": "POST"
    }),
        style: {
            layout_flexGrow: 1,
            layout_flexBasisPercent: size
        }
    });
    var tags = org.jsoup.Jsoup.parse(java.ajax(Url() + '/cate')).select('.tag-container').toArray().at(-1).select('a');
    if (tags[0].text() != '全部') push('全部', '', '/cate', 1);
    for (let i in tags) {
    	let size = tags[i].text() == '全部' ? 1 : 0.25;
    	push(tags[i].text(), tags[i].attr('data-value'), tags[i].attr('href'), size);
    }
    JSON.stringify(result);
    """#
}

/// 🥝猕猴桃漫画's `/cate` page: two `.tag-container` blocks, the rule reads the last one.
private final class KiwiCateURLProtocol: URLProtocol {
    static let host = "kiwi-cate.yuedu.test"
    private static let page = """
    <div class="tag-container"><a data-value="x" href="/other">其他</a></div>
    <div class="tag-container"><a data-value="" href="/cate">全部</a><a data-value="热血" href="/cate?t=1">热血</a><a data-value="恋爱" href="/cate?t=2">恋爱</a></div>
    """

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiwiCateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == "/cate" else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.page.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
