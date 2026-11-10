import Foundation
import JavaScriptCore

/// Rhino's per-evaluation scope on JavaScriptCore.
///
/// Legado evaluates every rule script in a scope of its own: `RhinoScriptEngine` makes a
/// fresh object for the script's bindings whose prototype is the source's shared jsLib
/// scope. What the script declares, or assigns without declaring, lives on that object and
/// is gone when the script ends; what jsLib declared is read through the prototype, and a
/// jsLib function sees jsLib's variables, never the script's. One JSContext has a single
/// global scope instead, so one script met another's names there: 长佩文学 (YCK1330)
/// declares `let d` in its jsLib and `var d` in a rule script, two separate variables on
/// Rhino and a SyntaxError ("Can't create duplicate variable") in one global scope.
///
/// A script runs as the body of a function inside `with (scope)`, where `scope` is a fresh
/// object whose prototype is the global object, and `this` is `scope`:
/// - its `var`, `let`, `const`, functions and classes are the function's own;
/// - assigning a global property it did not declare (a binding such as `result`, a jsLib
///   `var`) puts the value on `scope`, as Rhino puts it on the script's scope: jsLib's own
///   variable keeps its value, and so does the next script's;
/// - a name it declares with `var`, or assigns without declaring when no global property
///   holds it (a new name, or a jsLib `let`/`const`), is a variable of the function that
///   starts with the name's outer value, or undefined for a new name (`seededNames`). As on
///   Rhino, where `var` leaves a name the scope already has as it is, `var key =
///   encodeURIComponent(key)` reads the `key` the rule was given.
///
/// Code compiled by the `Function` constructor, and by an indirect eval, runs with Rhino's
/// top-level scope, which for a rule script is that script's scope: it reads and assigns
/// the script's names. On JavaScriptCore it runs in the global scope, so while a script
/// runs, each of its names that no global property holds is also a global accessor that
/// reads and writes the script's variable (`registry`, `__yueduRuleNames`): the names it
/// starts with, the functions declared at its top level, and what code it evaluates with a
/// direct eval declares in its function (`evalSource`). G站漫画 (YCK1329) evaluates its
/// search script, which declares `var data`, and then an obfuscated decoder whose
/// `Function` code defines `Data()` reading `data`.
///
/// What Rhino 1.8.1 gives with Legado's scopes, case by case, is `LegadoRuleScopeTests`.
/// Where this differs:
/// - a name it starts with is a copy taken on entry: a jsLib function that changes that
///   global while the script runs is not seen by the script, which Rhino reads through;
/// - reading a new name before assigning it is undefined (Rhino: ReferenceError);
/// - a top-level `var` is not a property of `this` (Rhino: it is);
/// - an assignment the scanner does not see (`eval('x = 1')`, or in `Function` code)
///   still creates a global, which the next script meets;
/// - a jsLib function can still create a new global (Rhino's shared scope is sealed);
/// - while the script runs, a jsLib function sees the script's names that are global
///   accessors (Rhino: it sees only jsLib's), and `Function` code sees a jsLib variable or
///   binding, not the script's variable of the same name (Rhino: the script's);
/// - a `"use strict"` at the top of a rule script is no longer a directive (the YCK packs
///   have one only in two jsLibs, which run in the global scope).
enum LegadoRuleScope {
    /// What a rule script's direct `eval` passes its argument through: JSCoreEngine's
    /// `__yueduRuleEval`, which answers `evalSource` for a string.
    static let evalWrapper = "__yueduRuleEval"

    /// The global `__yueduRuleNames`, which JSCoreEngine evaluates once per context.
    /// - `run(scope, body)` calls `body` with `this` = `scope` as a script's frame. When it
    ///   ends, normally or by an exception, the accessors the frame installed are deleted. (A
    ///   script that times out is abandoned with its whole context: `JSCoreEngine.resetEngine`.)
    /// - `add(names, read, write)` gives the running frame its names: a global accessor
    ///   for each that no global property holds, reading through `read(name)` and writing
    ///   through `write(name, value)` of the innermost frame that has it. A name another frame
    ///   installed keeps its accessor.
    /// - `own(names)` makes each name the frame's own: a property of the script's scope that
    ///   starts undefined, which the script reads and writes as it would one it assigned, and
    ///   a global accessor for it, unless a global property holds the name or the frame has it
    ///   already. It is gone with the scope, as Rhino's scope is.
    /// - `outer(name)` is the name's global value, or undefined: what a script's variable
    ///   starts with. The accessors are no global value: inside `outer` they are unresolved,
    ///   so a script run inside another (a `java.getString` rule) does not start with that
    ///   script's variables.
    /// An accessor reached again while it reads or writes (a name that is no binding where
    /// `read` was written) is unresolved too, rather than an endless recursion.
    static let registry = """
        (function () {
            var frames = [];
            var installed = Object.create(null);
            var reading = 0;
            var hasOwn = Object.prototype.hasOwnProperty;
            function owner(name) {
                for (var i = frames.length - 1; i >= 0; i--) {
                    if (frames[i].readers[name] !== undefined) return frames[i];
                }
                return null;
            }
            function unresolved(name) { return new ReferenceError("Can't find variable: " + name); }
            function accessor(name) {
                var busy = false;
                return {
                    get: function () {
                        var frame = reading || busy ? null : owner(name);
                        if (!frame) throw unresolved(name);
                        busy = true;
                        try { return frame.readers[name](name); } finally { busy = false; }
                    },
                    set: function (value) {
                        var frame = busy ? null : owner(name);
                        if (!frame) throw unresolved(name);
                        busy = true;
                        try { frame.writers[name](name, value); } finally { busy = false; }
                    },
                    configurable: true, enumerable: false
                };
            }
            function readScope(name) { return this[name]; }
            function writeScope(name, value) { this[name] = value; }
            function install(frame, name, read, write) {
                if (installed[name] === undefined) {
                    if (hasOwn.call(globalThis, name)) return false;
                    Object.defineProperty(globalThis, name, accessor(name));
                    installed[name] = frames.length;
                }
                frame.readers[name] = read;
                frame.writers[name] = write;
                return true;
            }
            var names = {
                run: function (scope, body) {
                    var frame = { scope: scope, readers: Object.create(null), writers: Object.create(null) };
                    frames.push(frame);
                    try {
                        return body.call(scope);
                    } finally {
                        frames.pop();
                        var depth = frames.length + 1;
                        for (var name in frame.readers) {
                            if (installed[name] === depth) {
                                delete globalThis[name];
                                delete installed[name];
                            }
                        }
                    }
                },
                add: function (list, read, write) {
                    var frame = frames[frames.length - 1];
                    if (!frame) return;
                    for (var i = 0; i < list.length; i++) install(frame, list[i], read, write);
                },
                own: function (list) {
                    var frame = frames[frames.length - 1];
                    if (!frame) return;
                    var scope = frame.scope;
                    var read = readScope.bind(scope), write = writeScope.bind(scope);
                    for (var i = 0; i < list.length; i++) {
                        var name = list[i];
                        if (frame.readers[name] !== undefined) continue;
                        if (!install(frame, name, read, write)) continue;
                        if (!hasOwn.call(scope, name)) {
                            Object.defineProperty(scope, name, { value: undefined, writable: true, enumerable: true, configurable: true });
                        }
                    }
                },
                outer: function (name) {
                    reading++;
                    try { return (0, eval)(name); } catch (error) { return undefined; } finally { reading--; }
                }
            };
            Object.defineProperty(globalThis, '__yueduRuleNames', { value: names, enumerable: false });
        })();
        """

    /// What `JSCoreEngine` evaluates for a rule script already normalized for Rhino: an
    /// expression whose value is the script's answer, its completion value
    /// (`LegadoCompletionValue`) or what a top-level `return` gives.
    ///
    /// Fallback: a script whose rewrite does not parse although the script does runs through
    /// a direct `eval` inside the same scope, with JavaScriptCore's own completion value and
    /// no starting copies, and logs. It guards a script the statement reader or the scanner
    /// follows wrongly: none of the 4,011 scripts of the YCK 1329／1330／1331 packs takes it.
    /// Delete it once the diagnostics have never logged it.
    ///
    /// `prepared` is normalized with `evalWrapper`, so the code it evaluates with a direct
    /// eval declares its names to the script (`evalSource`).
    static func payload(for prepared: String) -> String {
        if let body = LegadoCompletionValue.functionBody(prepared),
           let tokens = LegadoCompletionValue.tokens(prepared) {
            let seeds = seededNames(in: tokens)
            let functions = callerNames(in: tokens).functions.filter { !seeds.contains($0) }
            let scoped = scopedFunction(starting: seeds, mirroring: seeds + functions, body: body)
            if SyntaxCheck.shared.parses(scoped) { return scoped }
        }
        let plain = scopedFunction(starting: [], mirroring: [], body: prepared)
        // The script itself does not parse: run it as it is, for its own SyntaxError.
        guard SyntaxCheck.shared.parses(plain) else { return plain }
        AppLogger.parse(
            "Rule script scope rewrite does not parse; running the script through eval",
            context: ["length": prepared.utf16.count, "head": String(prepared.prefix(80))],
            level: .anomaly
        )
        // A top-level `return` is a SyntaxError in eval code; such a script keeps the
        // function body, answering only by its `return`.
        guard SyntaxCheck.shared.parses(prepared) else { return plain }
        return """
        (function (__yueduScope, __yueduSource) { with (__yueduScope) { return __yueduRuleNames.run(__yueduScope, \
        function () { return eval(\(evalWrapper)(__yueduSource)); }); } })(Object.create(globalThis), \
        \(stringLiteral(prepared)))
        """
    }

    /// The wrapper opens on the body's first line, so a JavaScript error reports the line
    /// of the script's own text.
    private static func scopedFunction(starting names: [String], mirroring mirrored: [String], body: String) -> String {
        let starts = names.isEmpty ? "" : "var "
            + names.map { "\($0) = __yueduRuleNames.outer(\(stringLiteral($0)))" }.joined(separator: ", ") + "; "
        let mirrors = mirrored.isEmpty ? "" : mirrorCall(mirrored) + "; "
        return "(function (__yueduScope) { with (__yueduScope) { return __yueduRuleNames.run(__yueduScope, "
            + "function () { " + starts + mirrors + body + "\n}); } })(Object.create(globalThis))"
    }

    /// `__yueduRuleNames.add` for `names`, each a binding where this is written: a name the
    /// script's function declares, or the code a direct eval runs declares in it.
    private static func mirrorCall(_ names: [String]) -> String {
        let list = names.map(stringLiteral).joined(separator: ", ")
        let reads = names.map { "case \(stringLiteral($0)): return \($0);" }.joined(separator: " ")
        let writes = names.map { "case \(stringLiteral($0)): \($0) = __yueduValue; break;" }.joined(separator: " ")
        return "__yueduRuleNames.add([\(list)], function (__yueduName) { switch (__yueduName) { \(reads) } }, "
            + "function (__yueduName, __yueduValue) { switch (__yueduName) { \(writes) } })"
    }

    // MARK: - Code a script evaluates

    /// What a rule script's direct `eval` compiles for `code`: the code normalized as the
    /// script is, so its own evals come here too, and, when it declares or assigns names,
    /// one first statement that gives them to the running script, so `Function` code reads
    /// and writes them:
    /// - what it declares in the caller's function (`callerNames`) is read where it is
    ///   (`__yueduRuleNames.add`), and each new `var` that is still undefined starts with its
    ///   outer value, as the script's own vars start: as on Rhino, eval'd
    ///   `var key = encodeURIComponent(key)` reads the `key` the rule was given;
    /// - a name it assigns without declaring becomes the scope's (`__yueduRuleNames.own`),
    ///   where Rhino puts it, instead of a new global the next script would meet: G站漫画
    ///   (YCK1329) sets `User = ""` there, its decoder's `Function` code sets `User = true`,
    ///   and on a second search a global left by the first took the decoder's write alone.
    /// The statement is a declaration, so it never becomes the eval's value, and it is on the
    /// code's first line, so errors keep the code's line numbers. Strict code is left alone:
    /// its declarations stay in the eval.
    static func evalSource(for code: String) -> String {
        let normalized = LegadoRhinoNormalizer.normalize(code, evalWrapper: evalWrapper).source
        guard let tokens = LegadoCompletionValue.tokens(normalized), let first = tokens.first,
              !(first.kind == .string && (first.text == "'use strict'" || first.text == "\"use strict\"")) else {
            return normalized
        }
        let (vars, functions) = callerNames(in: tokens)
        let declared = declaredNames(in: tokens, partners: matchingBrackets(tokens))
        let assigned = seededNames(in: tokens).filter { !declared.contains($0) && !$0.contains("\\") }
        let names = vars + functions.filter { !vars.contains($0) }
        guard !names.isEmpty || !assigned.isEmpty else { return normalized }
        var parts: [String] = []
        if !names.isEmpty { parts.append(mirrorCall(names)) }
        if !assigned.isEmpty { parts.append("__yueduRuleNames.own([\(assigned.map(stringLiteral).joined(separator: ", "))])") }
        parts += vars.map { "\($0) === undefined && (\($0) = __yueduRuleNames.outer(\(stringLiteral($0))))" }
        return "var __yueduMirrored = (" + parts.joined(separator: ", ") + "); " + normalized
    }

    /// Every name a `var` anywhere in the code declares, patterns included.
    private static func declaredNames(in tokens: [Token], partners: [Int: Int]) -> Set<String> {
        var names = Set<String>()
        for index in tokens.indices where tokens[index].kind == .name && tokens[index].text == "var"
            && !isMember(index, in: tokens) {
            names.formUnion(declaredNames(after: index, in: tokens, partners: partners))
        }
        return names
    }

    /// The names code evaluated by a direct eval declares in its caller's function: each
    /// name a `var` outside the code's own functions declares, and each function declared at
    /// its top level. Each must be a binding there, or reading it would reach its global
    /// accessor again, so these are left out: a destructuring `var` (its keys and defaults
    /// are names too), a function declared in a block (whether that is a binding of the
    /// caller is the engine's web-compatibility rule), and a name written with an escape.
    static func callerNames(in tokens: [Token]) -> (vars: [String], functions: [String]) {
        let partners = matchingBrackets(tokens)
        // Tokens inside a function body: from each body's `{` to its `}`.
        var marks = [Int](repeating: 0, count: tokens.count + 1)
        for index in tokens.indices where opensFunctionBody(index, in: tokens, partners: partners) {
            guard let close = partners[index] else { continue }
            marks[index] += 1
            marks[close + 1] -= 1
        }
        var vars: [String] = []
        var functions: [String] = []
        var seen = Set<String>()
        func add(_ name: String, to list: inout [String]) {
            guard !notSeeded.contains(name), !name.hasPrefix("__yuedu"), !name.contains("\\"),
                  seen.insert(name).inserted else { return }
            list.append(name)
        }
        var insideFunction = 0
        var depth = 0
        for index in tokens.indices {
            insideFunction += marks[index]
            let token = tokens[index]
            if token.kind == .punct {
                if ["(", "[", "{"].contains(token.text) { depth += 1 }
                if [")", "]", "}"].contains(token.text) { depth -= 1 }
                continue
            }
            guard token.kind == .name, insideFunction == 0, !isMember(index, in: tokens) else { continue }
            if token.text == "var" {
                declaredNames(after: index, in: tokens, partners: partners, patterns: false)
                    .forEach { add($0, to: &vars) }
            } else if token.text == "function", depth == 0, declaresFunction(at: index, in: tokens) {
                var cursor = index + 1
                if cursor < tokens.count, tokens[cursor].text == "*" { cursor += 1 }
                if cursor < tokens.count, tokens[cursor].kind == .name { add(tokens[cursor].text, to: &functions) }
            }
        }
        return (vars, functions)
    }

    /// The `{` at `index` opens a function's body: an arrow's, or one after a parameter list
    /// that no `if`/`for`/`while`/`switch`/`catch`/`with` heads — a function's or a method's.
    /// A call followed by a block on the next line reads as one too, which only leaves that
    /// block's names out.
    private static func opensFunctionBody(_ index: Int, in tokens: [Token], partners: [Int: Int]) -> Bool {
        guard tokens[index].kind == .punct, tokens[index].text == "{", index > 0 else { return false }
        let before = tokens[index - 1]
        guard before.kind == .punct else { return false }
        if before.text == "=>" { return true }
        guard before.text == ")", let open = partners[index - 1], open > 0 else { return false }
        let head = tokens[open - 1]
        switch head.kind {
        case .name: return !["if", "for", "while", "switch", "catch", "with"].contains(head.text)
        case .string: return true
        case .punct: return head.text == "*" || head.text == "]"
        case .number, .template, .regex: return false
        }
    }

    /// The `function` at `index` starts a declaration: it begins a statement, after `;`, a
    /// `}`, or a line break after a complete statement, or as the code's first token.
    private static func declaresFunction(at index: Int, in tokens: [Token]) -> Bool {
        guard index > 0 else { return true }
        let previous = tokens[index - 1]
        if previous.kind == .punct, previous.text == ";" || previous.text == "}" { return true }
        return tokens[index].newlineBefore && endsOperand(previous)
    }

    // MARK: - Names a script starts with

    /// The names the script's function starts with a copy of: every name it declares with
    /// `var` (patterns included), and every name it assigns without declaring — with `=` or a
    /// compound operator, `++`/`--`, as a `for…in`/`for…of` target or in a destructuring
    /// assignment. A name declared anywhere in the script with `let`, `const`, `class` or
    /// `function` is never one: a `var` beside a `let` of that name is a SyntaxError, and the
    /// copy's initializer would replace a hoisted function. A name in a nested function is
    /// included too, which only makes an unused variable.
    static func seededNames(in source: String) -> [String] {
        guard let tokens = LegadoCompletionValue.tokens(source) else { return [] }
        return seededNames(in: tokens)
    }

    private static func seededNames(in tokens: [Token]) -> [String] {
        let partners = matchingBrackets(tokens)
        var names: [String] = []
        var seen = Set<String>()
        var declared = Set<String>()
        func add(_ name: String) {
            guard !notSeeded.contains(name), !name.hasPrefix("__yuedu") else { return }
            if seen.insert(name).inserted { names.append(name) }
        }
        for index in tokens.indices {
            let token = tokens[index]
            if token.kind == .punct, token.text == "=", index > 0 {
                destructuredTargets(before: index, in: tokens, partners: partners).forEach(add)
                continue
            }
            guard token.kind == .name, !isMember(index, in: tokens) else { continue }
            switch token.text {
            case "var":
                declaredNames(after: index, in: tokens, partners: partners).forEach(add)
            case "let", "const":
                guard let next = following(index, in: tokens),
                      next.kind == .name || next.text == "[" || next.text == "{" else { break }
                declared.formUnion(declaredNames(after: index, in: tokens, partners: partners))
            case "function", "class":
                var cursor = index + 1
                if cursor < tokens.count, tokens[cursor].text == "*" { cursor += 1 }
                if cursor < tokens.count, tokens[cursor].kind == .name { declared.insert(tokens[cursor].text) }
            default:
                if isAssigned(index, in: tokens) { add(token.text) }
            }
        }
        return names.filter { !declared.contains($0) }
    }

    typealias Token = LegadoCompletionValue.Token

    private static let assignmentOperators: Set<String> = [
        "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=",
        "&&=", "||=", "??=",
    ]

    /// Words a sloppy-mode `var` cannot declare, and names no script means to shadow. The
    /// strict-mode reserved words (`package`, `public`, …) are names here: 1331's scripts
    /// declare `var package`.
    private static let notSeeded: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
        "instanceof", "new", "return", "super", "switch", "this", "throw", "try", "typeof",
        "var", "void", "while", "with", "yield", "let", "enum", "await", "null", "true", "false",
        "arguments", "eval", "undefined", "NaN", "Infinity",
    ]

    private static func following(_ index: Int, in tokens: [Token]) -> Token? {
        index + 1 < tokens.count ? tokens[index + 1] : nil
    }

    private static func isMember(_ index: Int, in tokens: [Token]) -> Bool {
        index > 0 && tokens[index - 1].kind == .punct
            && (tokens[index - 1].text == "." || tokens[index - 1].text == "?.")
    }

    /// The name at `index` is assigned: an assignment operator follows it, `++`/`--` is
    /// applied to it, or it is the target of `for (name in …)` / `for (name of …)`.
    private static func isAssigned(_ index: Int, in tokens: [Token]) -> Bool {
        if let next = following(index, in: tokens), next.kind == .punct {
            if assignmentOperators.contains(next.text) { return true }
            if (next.text == "++" || next.text == "--"), !next.newlineBefore { return true }
        }
        if index > 0, tokens[index - 1].kind == .punct,
           tokens[index - 1].text == "++" || tokens[index - 1].text == "--",
           !tokens[index].newlineBefore {
            return true
        }
        if index > 1, tokens[index - 1].text == "(", tokens[index - 2].kind == .name,
           tokens[index - 2].text == "for", let next = following(index, in: tokens),
           next.kind == .name, next.text == "in" || next.text == "of" {
            return true
        }
        return false
    }

    /// The names a `var`/`let`/`const` at `keyword` declares: each declarator's name, or every
    /// name inside its pattern (none with `patterns: false`). The list ends at a `;`, a
    /// bracket that closes past it, the `in`/`of` of a `for` head, or a line break that
    /// automatic semicolon insertion ends it at.
    private static func declaredNames(
        after keyword: Int, in tokens: [Token], partners: [Int: Int], patterns: Bool = true
    ) -> [String] {
        var names: [String] = []
        var cursor = keyword + 1
        var depth = 0
        var expectsBinding = true
        while cursor < tokens.count {
            let token = tokens[cursor]
            if depth == 0 {
                if token.kind == .punct, [";", ")", "]", "}"].contains(token.text) { break }
                if !expectsBinding {
                    if token.kind == .name, token.text == "in" || token.text == "of" { break }
                    if token.newlineBefore, endsOperand(tokens[cursor - 1]), startsStatement(token) { break }
                    if token.text == "," { expectsBinding = true; cursor += 1; continue }
                } else {
                    if token.kind == .name {
                        names.append(token.text)
                        expectsBinding = false
                        cursor += 1
                        continue
                    }
                    if token.text == "{" || token.text == "[", let close = partners[cursor] {
                        if patterns { names += tokens[(cursor + 1)..<close].filter { $0.kind == .name }.map(\.text) }
                        expectsBinding = false
                        cursor = close + 1
                        continue
                    }
                    break
                }
            }
            if token.kind == .punct {
                if ["(", "[", "{"].contains(token.text) { depth += 1 }
                if [")", "]", "}"].contains(token.text) { depth -= 1 }
            }
            cursor += 1
        }
        return names
    }

    /// The names a destructuring assignment `[a, b] = …` / `({a, b: c} = …)` assigns, when
    /// the `=` at `index` closes such a pattern. A member target (`arr[i] = …`) is none.
    private static func destructuredTargets(before index: Int, in tokens: [Token], partners: [Int: Int]) -> [String] {
        let close = index - 1
        guard tokens[close].kind == .punct, tokens[close].text == "]" || tokens[close].text == "}",
              let open = partners[close], open < close else { return [] }
        let before = open > 0 ? tokens[open - 1] : nil
        let isObject = tokens[open].text == "{"
        if let before {
            let starts: Set<String> = isObject ? ["(", ",", "="] : ["(", ",", "=", ";", "{", "}"]
            guard before.kind == .punct, starts.contains(before.text) else { return [] }
        }
        var names: [String] = []
        for cursor in (open + 1)..<close where tokens[cursor].kind == .name && !isMember(cursor, in: tokens) {
            // An object pattern's key (`{key: target}`) is not assigned.
            if isObject, let next = following(cursor, in: tokens), next.text == ":" { continue }
            names.append(tokens[cursor].text)
        }
        return names
    }

    private static let continuingNames: Set<String> = [
        "typeof", "void", "delete", "new", "in", "instanceof", "of", "await", "yield",
    ]

    private static func endsOperand(_ token: Token) -> Bool {
        switch token.kind {
        case .name: return !continuingNames.contains(token.text)
        case .number, .string, .template, .regex: return true
        case .punct: return [")", "]", "}", "++", "--"].contains(token.text)
        }
    }

    /// A token that, on a new line after a complete operand, starts the next statement.
    private static func startsStatement(_ token: Token) -> Bool {
        switch token.kind {
        case .name: return token.text != "in" && token.text != "instanceof" && token.text != "of"
        case .number, .string, .regex: return true
        case .template, .punct: return false
        }
    }

    /// Each bracket's partner, both ways.
    private static func matchingBrackets(_ tokens: [Token]) -> [Int: Int] {
        var partners: [Int: Int] = [:]
        var opens: [Int] = []
        for (index, token) in tokens.enumerated() where token.kind == .punct {
            if ["(", "[", "{"].contains(token.text) { opens.append(index) }
            if [")", "]", "}"].contains(token.text), let open = opens.popLast() {
                partners[open] = index
                partners[index] = open
            }
        }
        return partners
    }

    // MARK: - Text

    private static func stringLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Parses without running, in a context of its own: the engine's context belongs to its
    /// queue, and a payload is checked once per script, wherever it is first built.
    private final class SyntaxCheck: @unchecked Sendable {
        static let shared = SyntaxCheck()
        private let lock = NSLock()
        private var context: JSGlobalContextRef?

        func parses(_ script: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if context == nil { context = JSGlobalContextCreate(nil) }
            let text = JSStringCreateWithCFString(script as CFString)
            defer { JSStringRelease(text) }
            return JSCheckScriptSyntax(context, text, nil, 1, nil)
        }
    }
}
