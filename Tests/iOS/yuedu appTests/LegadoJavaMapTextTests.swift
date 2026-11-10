import Foundation
import Testing
@testable import yuedu_app

/// Legado reads JSON with jayway and json-smart's default provider: an object is a
/// `LinkedHashMap`, in document order, whose text is `{key=value, …}` (`OrderedJSON`).
/// Sources in YCK1331 match on that text.
@Suite("Legado JSON object text and order", .serialized)
struct LegadoJavaMapTextTests {

    private func object(_ text: String) -> Any {
        OrderedJSON.parse(text)!
    }

    // MARK: - Renderer

    @Test("an object reads as LinkedHashMap.toString, nested arrays as JSONArray text")
    func javaText() {
        let item = object(#"""
        {"id":7,"name":"a\/b","tags":["x","http:\/\/t\/1"],"none":null,"vip":true,
         "score":9.0,"ratio":0.0001,"count":12,"sub":{"z":1,"a":"文"}}
        """#)
        #expect(OrderedJSON.javaText(item)
                == #"{id=7, name=a/b, tags=["x","http:\/\/t\/1"], none=null, vip=true, score=9.0, ratio=1.0E-4, count=12, sub={z=1, a=文}}"#)
        // json-smart's toJSONString: keys in order, `/` and U+2000–U+20FF escaped.
        #expect(OrderedJSON.jsonText(object(#"{"b":"1/2…","a":[1.5,{"y":2,"x":1}]}"#))
                == #"{"b":"1\/2\u2026","a":[1.5,{"y":2,"x":1}]}"#)
    }

    @Test("Double.toString spellings")
    func javaDouble() {
        let cases: [(Double, String)] = [
            (1, "1.0"), (1000, "1000.0"), (1234567, "1234567.0"), (1e7, "1.0E7"),
            (123456789.25, "1.2345678925E8"), (0.001, "0.001"), (0.0001, "1.0E-4"),
            (-2.5, "-2.5"), (-0.0, "-0.0"), (1e20, "1.0E20"),
        ]
        for (value, text) in cases {
            #expect(OrderedJSON.javaDouble(value) == text)
        }
    }

    // MARK: - Order

    @Test("$.*, $..key and $..* read in document order")
    func documentOrder() {
        let json = object(#"""
        {"zeta":{"url":"z"},"alpha":{"url":"a"},"mid":{"inner":{"url":"m"}},"beta":2}
        """#)
        #expect(JSONPathEvaluator.query("$.*", on: json).map(JSONPathEvaluator.stringify)
                == ["{url=z}", "{url=a}", "{inner={url=m}}", "2"])
        #expect(JSONPathEvaluator.query("$..url", on: json).map(JSONPathEvaluator.stringify)
                == ["z", "a", "m"])
        // jayway's `..*`: a container's children, then each child's descendants.
        let tree = object(#"{"a":{"x":1},"b":2}"#)
        #expect(JSONPathEvaluator.query("$..*", on: tree).map(JSONPathEvaluator.stringify)
                == ["{x=1}", "2", "1"])
    }

    // MARK: - Rules

    /// 猫耳有声 (YCK1331): `id=String(result).match(/id=(\d+)/)[1]` on each search item.
    @Test("a script reads a JSON item as its Java Map text, keys in document order")
    func scriptReadsItemAsJavaMap() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://maoer.test"
        source.ruleSearch.bookList = "$.info.Datas[*]"
        source.ruleSearch.name = "$.soundstr"
        source.ruleSearch.bookUrl = #"""
        <js>
        id=String(result).match(/id=(\d+)/)[1];
        'https://maoer.test/sound?id='+id+'&size='+result.size+'&get='+result.get('ipr_id')
        </js>
        """#
        source.ruleSearch.intro = "<js>String(result)</js>"
        let page = #"""
        {"info":{"Datas":[{"id":7,"front_cover":"https:\/\/c\/7.jpg","soundstr":"广播剧","ipr_id":4,
         "user_id":3,"size":11,"catalog_name":"有声"}]}}
        """#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: page, baseURL: "https://maoer.test/s", source: source
        )
        #expect(books.first?.bookUrl == "https://maoer.test/sound?id=7&size=11&get=4")
        #expect(books.first?.intro
                == "{id=7, front_cover=https://c/7.jpg, soundstr=广播剧, ipr_id=4, user_id=3, size=11, catalog_name=有声}")
    }

    /// Lofter (YCK1331 index 280): `'{{$.postCount}}'` inside a script's string literal, and a
    /// cover read with `result.match(/bigAvaImg=(.*?),/)` from `$.post`'s text.
    @Test("an object a rule reads is Java Map text, in templates and before a script")
    func ruleReadsObjectAsJavaMap() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://lofter.test"
        source.ruleSearch.bookList = "$.data.posts[*]"
        source.ruleSearch.name = "$.post.title"
        source.ruleSearch.bookUrl = "https://lofter.test/p/{{$.post.id}}"
        source.ruleSearch.wordCount = #"@js:a='{{$.postCount}}';a.match(/hotCount=(\d+)/)[1]"#
        source.ruleSearch.coverUrl = #"""
        $.post
        @js:result.match(/bigAvaImg=(.*?),/)[1]
        """#
        let page = #"""
        {"data":{"posts":[{"post":{"id":5,"title":"标题","firstImageUrl":["",""],
         "bigAvaImg":"https:\/\/img\/a.png","digest":"d"},"postCount":{"blogId":2240831649,"hotCount":2509}}]}}
        """#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: page, baseURL: "https://lofter.test/s", source: source
        )
        #expect(books.first?.name == "标题")
        #expect(books.first?.wordCount == "2509")
        #expect(books.first?.coverUrl == "https://img/a.png")
    }

    /// 猫耳 (YCK1331 301–305): a list script hands its rows on as `JSON.stringify(list)` text,
    /// the next step reads them into objects, and the link script matches the object's text.
    @Test("a list script's text goes on to the next step, which reads it into objects")
    func listScriptTextReadByNextStep() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://maoer.test"
        source.ruleSearch.bookList = """
        <js>
        var list = JSON.parse(result).info.Datas;
        result = JSON.stringify(list)
        </js>
        $.[*]
        """
        source.ruleSearch.name = "$.name"
        source.ruleSearch.bookUrl = #"""
        <js>
        id = String(result).match(/id=(\d+)/)[1];
        result = 'https://maoer.test/drama?id=' + id
        </js>
        """#
        let page = #"{"info":{"Datas":[{"id":44753,"name":"一"},{"id":58217,"name":"二"}]}}"#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: page, baseURL: "https://maoer.test/s", source: source
        )
        #expect(books.map(\.name) == ["一", "二"])
        #expect(books.map(\.bookUrl) == ["https://maoer.test/drama?id=44753", "https://maoer.test/drama?id=58217"])
    }

    /// Legado's detail content is what `init` returned: a script's string stays a string (its
    /// `String(result)` is the text), a JSONPath object stays a `LinkedHashMap`.
    @Test("ruleBookInfo.init: a script's JSON text stays text, a JSONPath object a map")
    func bookInfoInitContent() throws {
        let page = #"{"data":{"name":"书","id":3}}"#
        var scripted = BookSource()
        scripted.bookSourceUrl = "https://init-json.test"
        scripted.ruleBookInfo.initScript = "<js>JSON.stringify(JSON.parse(result).data)</js>"
        scripted.ruleBookInfo.name = "$.name"
        scripted.ruleBookInfo.intro = "<js>String(result)</js>"
        let fromScript = try ModernParserBridge(source: scripted).parseBookInfo(
            html: page, bookUrl: "https://init-json.test/b", baseURL: "https://init-json.test/b", source: scripted
        )
        #expect(fromScript.name == "书")
        #expect(fromScript.intro == #"{"name":"书","id":3}"#)

        var selected = scripted
        selected.ruleBookInfo.initScript = "$.data"
        let fromPath = try ModernParserBridge(source: selected).parseBookInfo(
            html: page, bookUrl: "https://init-json.test/b", baseURL: "https://init-json.test/b", source: selected
        )
        #expect(fromPath.name == "书")
        #expect(fromPath.intro == "{name=书, id=3}")
    }

    /// 书香之家 (YCK1331) decrypts inside `with (javaImport)`, where `String(…)` is
    /// `java.lang.String` and hands back a `String` object; its rules `JSON.parse` that. Rhino
    /// parses its argument's text.
    @Test("JSON.parse reads a String object as text")
    func jsonParseReadsStringObject() {
        let engine = JSCoreEngine()
        _ = engine.evaluate("""
            var javaImport = new JavaImporter();
            javaImport.importPackage(Packages.java.lang);
            with (javaImport) { function decode(text) { return String(text); } }
            """)
        #expect(engine.evaluate(#"typeof decode('{"a":1}')"#) == "object")
        #expect(engine.evaluate(#"JSON.parse(decode('{"a":1}')).a"#) == "1")
        #expect(engine.evaluate(#"JSON.parse(new String('[2]'))[0]"#) == "2")
    }
}
