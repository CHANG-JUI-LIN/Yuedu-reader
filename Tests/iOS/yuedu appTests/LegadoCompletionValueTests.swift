import Foundation
import Testing
@testable import yuedu_app

/// A rule script answers with its completion value, and Legado computes it on Rhino, which
/// keeps ES5's rule: a statement that produces nothing leaves the earlier value in place.
/// JavaScriptCore follows ES2015, where `'a'; if (false) {}` is `undefined`. Each expected value
/// below is what Rhino 1.8.1 (Legado's engine) gives for the same script.
@Suite("Legado completion value")
struct LegadoCompletionValueTests {
    private func run(_ script: String, result: Any? = nil) -> String? {
        JSCoreEngine().evaluateIsolated(script, result: result)
    }

    @Test("美女图站: the answer built in one branch survives a false if after it")
    func valueSurvivesLaterFalseIf() {
        let script = """
        var site = 'iqupu';
        var html = '';
        if (site == 'iqupu') {
            html = '<img src="1.jpg">';
            html
        }
        if (site == 'xgmn02') {
            html = 'other';
            html
        }
        """
        #expect(run(script) == #"<img src="1.jpg">"#)
    }

    @Test("else-if chains, loops that never run and an empty switch keep the earlier value")
    func valuelessStatementsKeepValue() {
        #expect(run("'a'\nif (false) { 'b' } else if (false) { 'c' }") == "a")
        #expect(run("'a'; for (var i = 0; i < 0; i++) { 'b' }") == "a")
        #expect(run("'a'; while (false) {}") == "a")
        #expect(run("'a'; switch (1) { case 2: 'b' }") == "a")
        #expect(run("'a'; for (var k in {}) { 'b' }") == "a")
    }

    @Test("the last value produced inside a branch or loop is the answer")
    func lastProducedValueWins() {
        #expect(run("'a'; if (true) { 'b' }") == "b")
        #expect(run("var s = ''; for (var i = 0; i < 3; i++) { s += i; s }") == "012")
        #expect(run("'a'; switch (2) { case 2: 'b'; break; default: 'c' }") == "b")
        #expect(run("x: { 'a'; break x; 'b' }") == "a")
        #expect(run("'a'; try { 'b' } catch (e) { 'c' }") == "b")
        #expect(run("'a'; try { throw 1 } catch (e) { 'c' }") == "c")
    }

    @Test("a finally block that completes normally leaves the try block's value")
    func finallyDoesNotReplaceValue() {
        #expect(run("try { 'b' } finally { 'f' }") == "b")
    }

    @Test("statements a line break ends, and ones it does not")
    func statementBoundaries() {
        // `do {} while (x)` needs no `;` before the next statement.
        #expect(run("var n = 0\ndo { n++ } while (n < 2) n\nif (false) {}") == "2")
        // An object literal in parentheses is an expression, not a block.
        #expect(run("({a: 'v'}).a\nif (false) {}") == "v")
        // A template with a nested `${}` is one token. On a new line it still continues the
        // line before (a tagged template), as in JavaScript, so the declaration ends with `;`.
        #expect(run("var x = 'q';\n`a${`b${x}`}c`\nif (false) {}") == "abqc")
        // A call continues across a line break; an arrow body does not (多看／宜搜's explore).
        #expect(run("var f = (a) => {\n return a + 1\n}\n[1, 2].map(f).join(',')\nif (false) {}") == "2,3")
        #expect(run("var g = function (a) { return 'g' + a }\n(1)\ng\nif (false) {}") == "g1")
        #expect(run("var h = 'v'\n.toUpperCase()\nh\nif (false) {}") == "V")
    }

    @Test("a straight-line script answers with its last expression")
    func straightLineScripts() {
        let body = LegadoCompletionValue.functionBody("var a = 1; a + 1")
        #expect(body?.contains("\(LegadoCompletionValue.variable) = (a + 1)") == true)
        #expect(run("var a = 1; a + 1") == "2")
        #expect(run("result + '!'", result: "r") == "r!")
        #expect(run("var x; if (x) {}") == nil)
    }

    @Test("a statement's own semicolon is kept, so an else still follows its if")
    func semicolonBeforeElse() {
        #expect(LegadoCompletionValue.functionBody("if (x) 'a'; else 'b'")?.contains(";;") == false)
        #expect(run("if (false) 'a'; else 'b'") == "b")
        #expect(run("if (true) 'a';\nelse 'b'") == "a")
    }

    @Test("functions keep their own statements; only the script's are recorded")
    func functionBodiesUntouched() {
        let script = "function f() { 'inner'; if (true) { return 'r' } }\n'outer'\nif (false) {}\nf()"
        let instrumented = LegadoCompletionValue.functionBody(script)
        #expect(instrumented != nil)
        #expect(instrumented?.contains("\(LegadoCompletionValue.variable) = ('inner')") == false)
        #expect(run(script) == "r")
    }

    @Test("a script the reader cannot follow gets no rewrite")
    func unknownSyntaxIsLeftAlone() {
        #expect(LegadoCompletionValue.functionBody("if (x) { ") == nil)
        #expect(LegadoCompletionValue.functionBody("export default 1; if (x) {}") == nil)
    }
}
