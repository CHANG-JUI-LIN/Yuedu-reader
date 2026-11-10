import Foundation
import Testing
@testable import yuedu_app

/// Legado evaluates each rule script in a scope of its own: a fresh object for the script's
/// bindings whose prototype is the source's shared jsLib scope. Each expected value below is
/// what Rhino 1.8.1 gives for the same jsLib and script with Legado's scopes (one bindings
/// object per evaluation, the jsLib scope as its prototype).
@Suite("Legado rule scope")
struct LegadoRuleScopeTests {
    private static let jsLib = """
    let d = {x: 1}; var v = 1; var counter = 0; var shared = 'lib'; var box = {n: 1};
    function getV() { return v }
    function getD() { return JSON.stringify(d) }
    function inc() { counter++; return counter }
    function readShared() { return shared }
    function seesRuleFunction() { return typeof ruleFunction }
    function seesData() { return typeof data }
    """

    private func engine() -> JSCoreEngine {
        let engine = JSCoreEngine()
        _ = engine.evaluate(Self.jsLib)
        return engine
    }

    @Test("长佩文学 (YCK1330): a rule's var beside jsLib's let of the same name")
    func ruleVarBesideJsLibLet() {
        let engine = engine()
        #expect(engine.evaluateIsolated("var d = 'str'; d", result: nil) == "str")
        #expect(engine.lastError == nil)
        #expect(engine.evaluateIsolated("getD()", result: nil) == #"{"x":1}"#)
    }

    @Test("assigning a global puts it on the script's scope; jsLib's variable is untouched")
    func assignedGlobalStaysInTheScript() {
        let engine = engine()
        #expect(engine.evaluateIsolated("v = 2; getV()", result: nil) == "1")
        #expect(engine.evaluateIsolated("getV() + ',' + v", result: nil) == "1,1")
        #expect(engine.evaluateIsolated("d = 'zz'; getD() + '|' + d", result: nil) == #"{"x":1}|zz"#)
        #expect(engine.evaluateIsolated("getD()", result: nil) == #"{"x":1}"#)
    }

    @Test("a var the script declares is its own; jsLib functions keep reading theirs")
    func declaredVarIsTheScripts() {
        let engine = engine()
        #expect(engine.evaluateIsolated("var v = 3; getV() + ',' + v", result: nil) == "1,3")
        #expect(engine.evaluateIsolated("var shared = 'rule'; readShared()", result: nil) == "lib")
        #expect(engine.evaluateIsolated("readShared() + ',' + shared", result: nil) == "lib,lib")
    }

    @Test("jsLib functions keep their own state, and objects mutate in place")
    func jsLibStateAndObjects() {
        let engine = engine()
        #expect(engine.evaluateIsolated("inc(); inc()", result: nil) == "2")
        #expect(engine.evaluateIsolated("inc()", result: nil) == "3")
        #expect(engine.evaluateIsolated("box.n = 9; box.n", result: nil) == "9")
        #expect(engine.evaluateIsolated("box.n", result: nil) == "9")
    }

    @Test("this is the script's scope; names put on it are gone in the next script")
    func thisIsTheScriptsScope() {
        let engine = engine()
        #expect(engine.evaluateIsolated("this.newp = 4; newp", result: nil) == "4")
        #expect(engine.evaluateIsolated("typeof newp", result: nil) == "undefined")
    }

    @Test("a new name assigned without declaring does not reach the next script")
    func undeclaredAssignmentDoesNotLeak() {
        let engine = engine()
        #expect(engine.evaluateIsolated("fresh1 = 7; fresh1++; fresh1", result: nil) == "8")
        #expect(engine.evaluateIsolated("typeof fresh1", result: nil) == "undefined")
        #expect(engine.evaluateIsolated("for (k1 in {a: 1}) {} k1", result: nil) == "a")
        #expect(engine.evaluateIsolated("typeof k1", result: nil) == "undefined")
        #expect(engine.evaluateIsolated("[s1, s2] = ['x', 'y']; s1 + s2", result: nil) == "xy")
        #expect(engine.evaluateIsolated("typeof s1 + typeof s2", result: nil) == "undefinedundefined")
    }

    @Test("functions the script declares are its own, even in a block")
    func functionsAreTheScripts() {
        let engine = engine()
        // While the script runs, jsLib reads its top-level function through the global
        // accessor `Function` code needs (Rhino: "undefined"); the next script does not.
        #expect(engine.evaluateIsolated("function ruleFunction() {} seesRuleFunction()", result: nil) == "function")
        #expect(engine.evaluateIsolated("seesRuleFunction() + typeof ruleFunction", result: nil) == "undefinedundefined")
        #expect(engine.evaluateIsolated("{ function bf() { return 7 } } bf()", result: nil) == "7")
        #expect(engine.evaluateIsolated("typeof bf", result: nil) == "undefined")
        #expect(engine.evaluateIsolated("function g() { return 'g' } g = g(); g", result: nil) == "g")
    }

    @Test("bindings: result can be reassigned, a function reads it, var reads the given value")
    func bindings() {
        let engine = engine()
        #expect(engine.evaluateIsolated("result = 'r2'; result", result: "r1") == "r2")
        #expect(engine.evaluateIsolated("function rf() { return result } rf()", result: "r1") == "r1")
        #expect(engine.evaluateIsolated("var key = encodeURIComponent(key); key", bindings: ["key": "斗 罗"])
            == "%E6%96%97%20%E7%BD%97")
        #expect(engine.evaluateIsolated("var a = 1, b = result; b", result: "given") == "given")
        #expect(engine.evaluateIsolated("for (var i = 0, page = page * 2; i < 1; i++) {} page", bindings: ["page": 3]) == "6")
    }

    @Test("eval inside a script declares into that script")
    func evalDeclaresIntoTheScript() {
        let engine = engine()
        #expect(engine.evaluateIsolated("eval('var ev = 3'); ev", result: nil) == "3")
        #expect(engine.evaluateIsolated("typeof ev", result: nil) == "undefined")
    }

    @Test("completion value, top-level return, and a ReferenceError for an undeclared read")
    func answers() {
        let engine = engine()
        #expect(engine.evaluateIsolated("var a1 = 1; a1 + 1;", result: nil) == "2")
        #expect(engine.evaluateIsolated("if (true) return 'early'; 'late'", result: nil) == "early")
        #expect(engine.evaluateIsolated("if (result) 'a'; else 'b'", result: "x") == "a")
        #expect(engine.evaluateIsolated("try { nope; 'no error' } catch (e) { 'ReferenceError' }", result: nil)
            == "ReferenceError")
        #expect(engine.evaluateIsolated("let url = 1; url", result: nil) == "1")
        #expect(engine.evaluateIsolated("let url = 2; url", result: nil) == "2")
    }

    @Test("Function code and indirect eval read and write the script's names")
    func functionCodeSeesTheScript() {
        let engine = engine()
        #expect(engine.evaluateIsolated("var data = 5; (new Function('return typeof data'))()", result: nil) == "number")
        #expect(engine.evaluateIsolated("var data = 5; [].constructor.constructor('return typeof data')()", result: nil)
            == "number")
        #expect(engine.evaluateIsolated("var data = 5; (0, eval)('typeof data')", result: nil) == "number")
        #expect(engine.evaluateIsolated("var data = 5; [].constructor.constructor('return typeof this.data')()", result: nil)
            == "number")
        #expect(engine.evaluateIsolated("User = 'u'; [].constructor.constructor('return User')()", result: nil) == "u")
        #expect(engine.evaluateIsolated("var w = 1; (new Function('w = 7'))(); w", result: nil) == "7")
        // jsLib's variable stays jsLib's, for Function code too.
        #expect(engine.evaluateIsolated("[].constructor.constructor('return shared')()", result: nil) == "lib")
        // Gone with the script, also when it throws.
        #expect(engine.evaluateIsolated("typeof data + typeof User", result: nil) == "undefinedundefined")
        _ = engine.evaluateIsolated("var thrown = 1; throw new Error('boom')", result: nil)
        #expect(engine.evaluate("typeof thrown + Object.getOwnPropertyNames(globalThis).indexOf('thrown')") == "undefined-1")
    }

    @Test("G站漫画 (YCK1329): what eval'd code declares or assigns, its decoder's Function code shares")
    func evalCodeNamesReachFunctionCode() {
        let engine = engine()
        #expect(engine.evaluateIsolated("eval('var data = 5'); [].constructor.constructor('return typeof data')()", result: nil)
            == "number")
        #expect(engine.evaluateIsolated(
            "var data = [1, 2]; [].constructor.constructor('Data = function () { return data.length }')(); Data()",
            result: nil) == "2")
        // The search script's shape: its `var data` and `User`, set by the decoder's Function
        // code. The second search must not meet what the first one left.
        let search = "var data; eval(decoder); User = ''; user_Check(); data = []; "
            + "if (User == true) { var list = [1, 2]; for (i in list) { push(data, list[i]) } } data.join(',')"
        let decoder = "[].constructor.constructor('push = function (l, x) { l.push(x) }; "
            + "user_Check = function () { User = true }')()"
        for _ in 0..<2 {
            #expect(engine.evaluateIsolated("eval(String(search))", bindings: ["search": search, "decoder": decoder]) == "1,2")
        }
        #expect(engine.evaluate("typeof data + typeof User + typeof i + typeof list") == "undefinedundefinedundefinedundefined")
        #expect(engine.evaluateIsolated("eval('function put(x) { return x + 1 }'); [].constructor.constructor('return put(1)')()",
            result: nil) == "2")
        #expect(engine.evaluateIsolated("eval('flag = false'); [].constructor.constructor('flag = true')(); flag", result: nil)
            == "true")
        #expect(engine.evaluateIsolated("var rv = 1; eval('rv = 5'); [].constructor.constructor('return rv')() + ',' + rv",
            result: nil) == "5,5")
        // An eval'd var reads the binding the rule was given, as on Rhino.
        #expect(engine.evaluateIsolated("eval('var key = encodeURIComponent(key)'); key", bindings: ["key": "斗 罗"])
            == "%E6%96%97%20%E7%BD%97")
        // jsLib's var assigned by eval'd code stays jsLib's; strict eval code keeps its own.
        #expect(engine.evaluateIsolated("eval('shared = 2'); shared + readShared()", result: nil) == "2lib")
        #expect(engine.evaluateIsolated("eval(\"'use strict'; var s9 = 1\"); typeof s9", result: nil) == "undefined")
        // The eval's value is the code's, never the added first statement's.
        #expect(engine.evaluateIsolated("String(eval('var b9 = 5'))", result: nil) == "undefined")
        #expect(engine.evaluateIsolated("var k2 = 'A'; eval('var k2 = k2 + 1'); k2", result: nil) == "A1")
    }

    @Test("where Function code differs from Rhino's")
    func functionCodeDivergences() {
        let engine = engine()
        // A new global Function code assigns stays for the next script (Rhino: gone).
        #expect(engine.evaluateIsolated("[].constructor.constructor('fresh9 = 9')(); fresh9", result: nil) == "9")
        #expect(engine.evaluateIsolated("typeof fresh9", result: nil) == "number")
        // While the script runs, a jsLib function sees its names (Rhino: "undefined").
        #expect(engine.evaluateIsolated("var data = 5; seesData()", result: nil) == "number")
    }

    @Test("the names code evaluated by a direct eval declares in its caller")
    func callerNames() {
        func names(_ source: String) -> [String] {
            guard let tokens = LegadoCompletionValue.tokens(source) else { return [] }
            let found = LegadoRuleScope.callerNames(in: tokens)
            return found.vars + found.functions
        }
        #expect(names("var a = 1; if (x) { var b } for (var i = 0; i < 1; i++) {} function f() { var inner } f()")
            == ["a", "b", "i", "f"])
        #expect(names("var g = function h() { var inner }, k = () => { var arrow }; ({ m() { var method } })") == ["g", "k"])
        #expect(names("{ function blockFn() {} } (function iife() {})(); x = function named() {}") == [])
        #expect(names("var {p, q: r} = o") == [])
        #expect(names("try {} catch (e) { var c } while (x) { var w }") == ["c", "w"])
    }

    @Test("the names a script starts with")
    func seededNames() {
        #expect(LegadoRuleScope.seededNames(in: "var a = 1, b = 2\nc = 3, d = 4") == ["a", "b", "c", "d"])
        #expect(LegadoRuleScope.seededNames(in: "var {x, y: z} = o; var [p, ...q] = r") == ["x", "y", "z", "p", "q"])
        #expect(LegadoRuleScope.seededNames(in: "for (var k in o) {} for (var i = 0, n = 2; i < n; i++) {}")
            == ["k", "i", "n"])
        #expect(LegadoRuleScope.seededNames(in: "var a = 1\nb = 2") == ["a", "b"])
        // Declared with let, const, class or function anywhere: never a starting name.
        #expect(LegadoRuleScope.seededNames(in: "let x = 1; x = 2; function f() {} f = 1; class C {} C = 2") == [])
        #expect(LegadoRuleScope.seededNames(in: "{ let y = 1 } y = 2") == [])
        // Members and object keys are not assigned names; `package` is a name outside strict mode.
        #expect(LegadoRuleScope.seededNames(in: "o.a = 1; arr[i] = 2; x = {k: 1}; var package = 1") == ["x", "package"])
    }
}
