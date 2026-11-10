import Testing
@testable import yuedu_app

@Suite("Legado Rhino Normalizer Scanner", .serialized)
struct LegadoRhinoNormalizerScannerTests {
    @Test("non-BMP identifiers do not crash the UTF-16 scanner")
    func nonBMPIdentifierDoesNotCrash() {
        let input = "function read(𠮷) { let 𠮷 = 1; return 𠮷; }"

        let normalized = LegadoRhinoNormalizer.normalize(input)

        #expect(normalized.source == "function read(𠮷) { var 𠮷 = 1; return 𠮷; }")
        #expect(normalized.edits.count == 1)
    }

    /// Rhino 1.8.1 `TokenStream.getChar` skips Unicode format characters everywhere but inside a
    /// string or template literal (`getChar(false)` there). 移动阅读 (YCK1330) calls
    /// `source.getSource\u{200B}()`, which JavaScriptCore rejects as an invalid character.
    @Test("format characters drop out of code and regex literals, as Rhino drops them")
    func formatCharactersFollowRhino() throws {
        let input = "eval(String(source.getSource\u{200B}().bookSourceComment));"
            + " var s = \"a\u{200B}b\", t = `c\u{200D}d`, r = /x\u{200B}y/g; le\u{200B}t result = 1; // z\u{200B}"

        let normalized = LegadoRhinoNormalizer.normalize(input).source

        #expect(normalized == "eval(__yueduRhinoSource(String(source.getSource().bookSourceComment)));"
            + " var s = \"a\u{200B}b\", t = `c\u{200D}d`, r = /xy/g; var result = 1; // z\u{200B}")
        #expect(LegadoRhinoNormalizer.normalize(normalized).source == normalized)

        let engine = JSCoreEngine()
        let value = engine.evaluate(
            "var o = { getSource: function () { return 'ok' } }; o.getSource\u{200B}() + '|' + 'a\u{200B}b'.length"
        )
        #expect(value == "ok|3")
    }

    /// Rhino 1.8.1 compiles E4X (`FEATURE_E4X` is on for `VERSION_ES6`) and Legado ships no XML
    /// runtime, so a descendant query throws only when it runs. 哔哩哔哩 (YCK1331) has
    /// `return data..item_null.text` in one `switch` case of its jsLib; JavaScriptCore rejected
    /// the whole jsLib.
    @Test("an E4X descendant query compiles, and throws only when it runs")
    func e4xDescendantsThrowWhenRun() {
        let input = "function f(t, d) { switch (t) { case 1: return 'ok'; case 2: return d..item_null.text } }"
        #expect(LegadoRhinoNormalizer.normalize(input).source
            == #"function f(t, d) { switch (t) { case 1: return 'ok'; case 2: return d[__yueduE4XDescendants("item_null")].text } }"#)
        #expect(LegadoRhinoNormalizer.normalize("x = c ? o..y : o..@id, z = o..*;").source
            == #"x = c ? o[__yueduE4XDescendants("y")] : o[__yueduE4XDescendants("@id")], z = o[__yueduE4XDescendants("*")];"#)
        // A number's decimal point and a spread are not descendant queries.
        let untouched = "var a = 1..toString(), b = [...[1]], c = 1.5.toFixed(1);"
        #expect(LegadoRhinoNormalizer.normalize(untouched).source == untouched)

        let engine = JSCoreEngine()
        _ = engine.evaluate(input)
        #expect(engine.evaluate("f(1, {})") == "ok")
        #expect(engine.evaluate("try { f(2, { item_null: { text: 'x' } }) } catch (e) { e instanceof TypeError }") == "true")
    }
}
