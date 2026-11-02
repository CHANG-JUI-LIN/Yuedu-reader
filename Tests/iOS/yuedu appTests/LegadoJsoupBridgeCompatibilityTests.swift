import Foundation
import Testing
@testable import yuedu_app

/// The Rhino-vs-JavaScriptCore gaps from diagnostic report YD-3H4Q-MRDV (1204 sources):
/// each test pins what Legado's own runtime does for a call a real source makes.
@Suite("Legado jsoup bridge compatibility", .serialized)
struct LegadoJsoupBridgeCompatibilityTests {

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
            requestURL: URL(string: "https://example.com/start")!,
            finalURL: URL(string: "https://example.com/final")!,
            statusCode: 200,
            statusMessage: "OK",
            headers: [:],
            cookies: [:],
            body: "ok"
        ))
        #expect(engine.evaluate("typeof result.url + '|' + result.url()", result: response) == "function|https://example.com/final")
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
