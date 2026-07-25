import Foundation
import JavaScriptCore

/// JavaScript execution engine wrapping JavaScriptCore.
/// Provides Legado-compatible `java.*` bridge functions so book source
/// rules written for Legado's Rhino engine run on iOS.
///
/// Usage:
/// ```
/// let engine = JSCoreEngine()
/// engine.getData = { key in storage[key] }
/// engine.putData = { key, val in storage[key] = val }
/// let html = engine.evaluate("java.ajax(url)", result: previousResult)
/// ```
class JSCoreEngine {

    private var context: JSContext
    private let bridge: LegadoJSBridge
    private let cookieBridge = LegadoCookieBridge()
    /// SwiftSoup backing for the `org.jsoup.*` polyfill.
    private let jsoupBridge = LegadoJsoupBridge()

    /// Bridge for `source.*` — replaces the plain dictionary with a full Legado-compatible object.
    private(set) var sourceBridge: LegadoSourceBridge
    /// Bridge for `cache.*` — persistent + memory key-value store.
    private(set) var cacheBridge: LegadoCacheBridge
    /// Bridge for Legado's mutable `book` object.
    private(set) var bookBridge: LegadoBookBridge
    /// Bridge for Legado's mutable `chapter` object.
    private(set) var chapterBridge: LegadoChapterBridge

    // Serial queue owns the JSContext — all evaluations run on this thread.
    // Using a dedicated queue instead of NSLock eliminates the deadlock that
    // NSLock causes when JS calls java.ajax() (semaphore) while the lock is held.
    private var jsQueue = DispatchQueue(label: "com.yuedu.jsengine.serial", qos: .userInitiated)
    private let jsQueueKey = DispatchSpecificKey<Void>()

    /// JS evaluation timeout. If a script takes longer than this, the engine is
    /// reset and the evaluation returns nil. Guards against infinite loops in
    /// book-source rule JS that would otherwise permanently block the serial
    /// queue and freeze the calling Task (common on iOS 17).
    private static let jsTimeout: TimeInterval = 30

    /// Last JavaScript error message (nil if no error on last evaluation).
    private(set) var lastError: String?

    // MARK: - Delegates

    /// Retrieve a stored variable by key (wired to RuleDataInterface).
    var getData: ((String) -> String?)? {
        didSet { bridge.getData = getData }
    }

    /// Store a variable by key (wired to RuleDataInterface).
    var putData: ((String, String) -> Void)? {
        didSet { bridge.putData = putData }
    }

    /// Handle network requests originating from `java.ajax` / `java.connect`.
    var networkHandler: ((URLRequest) -> String?)? {
        didSet { bridge.networkHandler = networkHandler }
    }

    /// Handle AnalyzeUrl parsing for `java.ajax` URLs with ,{json} options.
    var analyzeUrlHandler: ((String) -> String?)? {
        didSet { bridge.analyzeUrlHandler = analyzeUrlHandler }
    }

    /// Handle `java.getString(ruleStr)` — connected to ModernRuleEngine later.
    var getStringHandler: ((String) -> String?)? {
        didSet { bridge.getStringHandler = getStringHandler }
    }

    /// Handle `java.getStringList(ruleStr)` — connected to ModernRuleEngine later.
    var getStringListHandler: ((String) -> [String]?)? {
        didSet { bridge.getStringListHandler = getStringListHandler }
    }

    /// Handle `java.setContent(content, baseUrl)` — updates engine content and result.
    var setContentHandler: ((Any?, String?) -> Void)? {
        didSet { bridge.setContentHandler = setContentHandler }
    }

    /// Handle `java.getElements(ruleStr)` — extracts elements from stored content.
    var getElementsHandler: ((String) -> [Any]?)? {
        didSet { bridge.getElementsHandler = getElementsHandler }
    }

    /// Handle `java.getString(ruleStr)` against previously stored setContent content.
    var getStringWithContentHandler: ((String, Any?) -> String?)? {
        didSet { bridge.getStringWithContentHandler = getStringWithContentHandler }
    }

    /// Called when JS invokes `java.startBrowser` / `java.startBrowserAwait`.
    /// Set this before evaluating login JS to enable interactive browser pop-ups.
    var browserPresentHandler: ((String, String, @escaping (String?) -> Void) -> Void)? {
        didSet { bridge.browserPresentHandler = browserPresentHandler }
    }

    /// Called when JS network requests hit a Cloudflare challenge.
    /// Presents the CF bypass UI on the main thread and calls `done` when CF cookies are obtained.
    /// Same DispatchSemaphore pattern as browserPresentHandler.
    var cloudflareChallengeHandler: ((URL, @escaping () -> Void) -> Void)? {
        didSet { bridge.cloudflareChallengeHandler = cloudflareChallengeHandler }
    }

    /// Called when JS invokes `java.reLoginView()` — re-render the source's custom login menu.
    var reLoginViewHandler: (() -> Void)? {
        didSet { bridge.reLoginViewHandler = reLoginViewHandler }
    }

    /// Called when JS invokes `java.upLoginData(map)` — persist source-menu setting values.
    var upLoginDataHandler: ((JSValue) -> Void)? {
        didSet { bridge.upLoginDataHandler = upLoginDataHandler }
    }

    /// Called when JS invokes `java.toast` / `java.longToast`.
    var toastHandler: ((String) -> Void)? {
        didSet { bridge.toastHandler = toastHandler }
    }

    /// Called when JS invokes `java.setResponseBase64(data, mimeType)` — captures
    /// base64-decoded audio data from TTS `loginCheckJs` response processing.
    var responseBase64Handler: ((Data, String) -> Void)? {
        didSet { bridge.setResponseBase64Handler = responseBase64Handler }
    }

    /// Book source object injected as `source` in JS — set this before evaluating rule scripts.
    var bookSource: BookSource? {
        didSet {
            onJSQueue {
                resolvedHeaderCache = nil
                guard let src = bookSource else {
                    sourceBridge = LegadoSourceBridge(
                        bookSourceUrl: "", bookSourceName: "", bookSourceGroup: "",
                        bookSourceComment: "", loginUrl: "", header: "", loginCheckJs: ""
                    )
                    cacheBridge = LegadoCacheBridge(sourceId: "")
                    bridge.requestTimeoutSeconds = 8
                    injectSourceObject(into: context)
                    context.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)
                    return
                }
                let prevHandlers = sourceBridge.getVariableHandler
                sourceBridge = LegadoSourceBridge.from(src)
                sourceBridge.getVariableHandler = prevHandlers
                cacheBridge = LegadoCacheBridge(sourceId: src.bookSourceUrl)
                injectSourceObject(into: context)
                context.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)
                bridge.requestTimeoutSeconds = Self.clampedRequestTimeoutSeconds(src.respondTime)
            }
        }
    }

    // MARK: - Resolved source headers

    private var resolvedHeaderCache: [String: String]?
    private var isResolvingHeaders = false

    /// The source's `header` rule resolved to request headers (Legado
    /// `getHeaderMap()`): plain JSON, or a `@js:` / `<js>` rule evaluated here.
    ///
    /// Resolved on first use — not when the source is attached — so a rule that
    /// calls `jsLib` helpers sees them. Cached because a JS rule would otherwise
    /// re-run for every `java.get`/`java.ajax` (段評 fires hundreds), and guarded
    /// against re-entry because a header rule may itself issue a request.
    func resolvedSourceHeaders() -> [String: String] {
        onJSQueue { [self] () -> [String: String] in
            if let resolvedHeaderCache { return resolvedHeaderCache }
            guard !isResolvingHeaders, let header = bookSource?.header else { return [:] }
            isResolvingHeaders = true
            let headers = parseHeaders(header)
            isResolvingHeaders = false
            resolvedHeaderCache = headers
            return headers
        }
    }

    /// Called when JS evaluation fails, with the error message and the script that caused it.
    var errorHandler: ((String, String) -> Void)?

    // MARK: - Initializer

    init() {
        let ctx = JSContext()!
        self.context = ctx
        self.bridge = LegadoJSBridge()
        self.sourceBridge = LegadoSourceBridge(
            bookSourceUrl: "", bookSourceName: "", bookSourceGroup: "",
            bookSourceComment: "", loginUrl: "", header: "", loginCheckJs: ""
        )
        self.cacheBridge = LegadoCacheBridge(sourceId: "")
        self.bookBridge = LegadoBookBridge()
        self.chapterBridge = LegadoChapterBridge()

        jsQueue.setSpecific(key: jsQueueKey, value: ())
        configureContext(ctx)

        // `java.get`/`java.post`/`java.ajax` inside rule JS ask for the source's
        // headers per request; resolve them lazily so a `@js:` rule runs after
        // jsLib is in place (and only once — see `resolvedSourceHeaders`).
        bridge.sourceHeadersProvider = { [weak self] in
            self?.resolvedSourceHeaders() ?? [:]
        }
    }

    private static func clampedRequestTimeoutSeconds(_ respondTimeMilliseconds: Int64) -> TimeInterval {
        guard respondTimeMilliseconds > 0 else { return 8 }
        let seconds = Double(respondTimeMilliseconds) / 1000.0
        return min(30, max(8, seconds))
    }

    // MARK: - Public API

    // Lock protecting `jsQueue` swap during timeout recovery.
    private let queueLock = NSLock()

    /// Read the current jsQueue under lock (safe to call from any thread).
    private var safeJsQueue: DispatchQueue {
        queueLock.lock()
        let q = jsQueue
        queueLock.unlock()
        return q
    }

    /// Dispatch work to the JS serial queue, re-entrant-safe.
    /// If already executing on the JS queue (e.g. java.getString → engine.getString → evaluate),
    /// the work runs inline to avoid a deadlock.
    private func onJSQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: jsQueueKey) != nil {
            return work() // already on the JS queue — run inline
        }
        return safeJsQueue.sync { work() }
    }

    /// Like `onJSQueue` but with a timeout. Returns `.timedOut` when the JS
    /// evaluation takes longer than `Self.jsTimeout` seconds. On timeout the
    /// engine is reset so subsequent evaluations can proceed.
    private enum JSTimeoutResult<T> {
        case completed(T)
        case timedOut
    }

    private func onJSQueueWithTimeout<T>(_ work: @escaping () -> T) -> JSTimeoutResult<T> {
        if DispatchQueue.getSpecific(key: jsQueueKey) != nil {
            return .completed(work())
        }

        var result: T? = nil
        let group = DispatchGroup()
        let queue = safeJsQueue

        group.enter()
        queue.async { [weak self] in
            // Only guard against the engine being torn down; `self` itself is unused
            // because `work` is a self-contained closure.
            guard self != nil else { group.leave(); return }
            result = work()
            group.leave()
        }

        if group.wait(timeout: .now() + Self.jsTimeout) == .timedOut {
            resetEngine()
            return .timedOut
        }

        return .completed(result!)
    }

    // MARK: - JS network attribution
    //
    // Forwards to the java bridge's accumulator so a caller (ModernParserBridge) can measure
    // how much of a parse was spent blocked on `java.*` network (段評 review fetches) vs JS CPU.
    func resetJSNetworkMs() { bridge.resetNetworkMs() }
    func takeJSNetworkMs() -> Double { bridge.takeNetworkMs() }

    /// Evaluate JavaScript code and return the result as a string.
    /// Returns `nil` on JS error, timeout, or if the result is `undefined`/`null`.
    func evaluate(_ script: String) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            guard let value = context.evaluateScript(script) else { return nil }
            return extractString(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Evaluate with a `result` variable pre-set (Legado convention:
    /// the previous rule step's output is available as `result` in JS).
    func evaluate(_ script: String, result: String?) -> String? {
        evaluate(script, result: result as Any?, bindings: [:])
    }

    /// Evaluate with an arbitrary `result` value and extra bindings. JSON strings
    /// are exposed to JS as objects so rules can use `result.book_id` after
    /// a `$.data` extraction, matching Legado's dynamic result semantics.
    func evaluate(_ script: String, result: Any?, bindings: [String: Any] = [:]) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            setResult(result)
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            let prepared = Self.prepareSourceJS(script)
            guard let value = context.evaluateScript(prepared) else { return nil }
            return extractString(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Legado rule JS sometimes both reads the injected `result` global AND later
    /// redeclares it with `let result = …` / `const result = …` in the same scope —
    /// e.g. 起点's chapterList reads `result` (the page body) up top, then builds the
    /// filtered chapter list into `let result = []`. Under JavaScriptCore's ES6 rules
    /// the `let` hoists into a Temporal Dead Zone, so the *earlier* read throws
    /// "Cannot access 'result' before initialization" and the whole rule aborts
    /// (symptom: empty TOC/content). Rhino (Legado on Android) has no TDZ here.
    /// Rewriting the redeclaration to `var result` hoists without a TDZ and reuses the
    /// injected global — verified to make 起点's 453-chapter TOC parse. Only the exact
    /// `result` identifier is touched (not `resultList`, etc.).
    private static let resultRedeclPattern = try! NSRegularExpression(
        pattern: #"\b(?:let|const)(\s+result\b)"#
    )
    private static func neutralizeResultRedeclaration(_ script: String) -> String {
        guard script.contains("result") else { return script }
        let range = NSRange(script.startIndex..., in: script)
        return resultRedeclPattern.stringByReplacingMatches(
            in: script, range: range, withTemplate: "var$1"
        )
    }

    /// JavaScriptCore (iOS) rejects an arrow function whose sole parameter is an array-destructuring
    /// pattern written WITHOUT wrapping parens — `list.map([a,b]=>…)` — throwing
    /// "SyntaxError: Unexpected token '=>'", which aborts the WHOLE script (symptom: empty 发现页 /
    /// search for 番茄-family sources). Rhino (Legado on Android) accepts the bare form, so sources
    /// authored there ship it. Re-insert the required parens: `[a,b]=>` → `([a,b])=>`. Only a flat
    /// `[…]` (no nested brackets/newlines) sitting in argument position (`(`/`,` before it) and
    /// immediately followed by `=>` is matched, so real array literals are untouched; idempotent.
    private static let destructuringArrowPattern = try! NSRegularExpression(
        pattern: #"([(,]\s*)\[([^\[\]\n]+)\](\s*=>)"#
    )
    private static func neutralizeDestructuringArrowParams(_ script: String) -> String {
        guard script.contains("=>") else { return script }
        let range = NSRange(script.startIndex..., in: script)
        return destructuringArrowPattern.stringByReplacingMatches(
            in: script, range: range, withTemplate: "$1([$2])$3"
        )
    }

    /// Normalizes Android/Rhino-isms that JavaScriptCore rejects, so source rule JS authored for
    /// Legado-on-Android compiles on iOS. Applied to every rule-JS evaluation path.
    private static func prepareSourceJS(_ script: String) -> String {
        neutralizeDestructuringArrowParams(neutralizeResultRedeclaration(script))
    }

    /// Evaluate with multiple bindings injected into the context before execution.
    func evaluate(_ script: String, bindings: [String: Any]) -> String? {
        switch onJSQueueWithTimeout({ [self] () -> String? in
            lastError = nil
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            guard let val = context.evaluateScript(Self.prepareSourceJS(script)) else { return nil }
            return extractString(from: val)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    /// Evaluate a rule snippet in a block scope so `let`/`const` declarations
    /// from one Legado rule segment do not leak into later segments.
    func evaluateIsolated(_ script: String, result: Any?, bindings: [String: Any] = [:]) -> String? {
        evaluate("{\n\(script)\n}", result: result, bindings: bindings)
    }

    func evaluateIsolated(_ script: String, bindings: [String: Any]) -> String? {
        evaluate("{\n\(script)\n}", bindings: bindings)
    }

    /// Evaluate a script whose result is BYTES (Legado image-decode convention:
    /// `result` holds the raw bytes, the script returns decoded bytes). The
    /// input bytes are exposed as a JS number array (0–255); the return value
    /// may be a number array (Java byte semantics tolerated) or a base64 string.
    func evaluateBytes(_ script: String, data: Data, bindings: [String: Any] = [:]) -> Data? {
        let numbers = data.map { NSNumber(value: $0) }
        switch onJSQueueWithTimeout({ [self] () -> Data? in
            lastError = nil
            context.setObject(numbers, forKeyedSubscript: "result" as NSString)
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            let prepared = Self.prepareSourceJS(script)
            guard let value = context.evaluateScript(prepared) else { return nil }
            return Self.extractBytes(from: value)
        }) {
        case .completed(let r): return r
        case .timedOut: return nil
        }
    }

    private static func extractBytes(from value: JSValue) -> Data? {
        if value.isUndefined || value.isNull { return nil }
        if value.isArray {
            guard let numbers = value.toArray() as? [NSNumber] else { return nil }
            var data = Data(capacity: numbers.count)
            for number in numbers {
                // Tolerate Java's signed-byte range (-128…127) alongside 0…255.
                data.append(UInt8(bitPattern: Int8(truncatingIfNeeded: number.intValue)))
            }
            return data.isEmpty ? nil : data
        }
        if value.isString, let string = value.toString() {
            if let decoded = Data(base64Encoded: string), !decoded.isEmpty {
                return decoded
            }
            let utf8 = Data(string.utf8)
            return utf8.isEmpty ? nil : utf8
        }
        return nil
    }

    /// Reset the context — clears all JS variables and re-injects the bridge.
    func reset() {
        onJSQueue {
            let ctx = JSContext()!
            self.context = ctx
            configureContext(ctx)
            lastError = nil
        }
    }

    /// Monotonically increasing generation counter. Incremented on `resetEngine()`.
    /// `ModernParserBridge` uses this to know when to re-evaluate jsLib.
    private(set) var generation: UInt64 = 0

    /// Hard-reset the engine by creating a fresh serial queue and JSContext.
    /// Used after a JS evaluation timeout to break free from a hung script;
    /// the old queue and context are abandoned (they continue running on their
    /// thread but never affect the new engine).
    private func resetEngine() {
        let label = "com.yuedu.jsengine.\(UUID().uuidString.prefix(8))"
        let newQueue = DispatchQueue(label: label, qos: .userInitiated)
        newQueue.setSpecific(key: jsQueueKey, value: ())
        let newContext = JSContext()!
        configureContext(newContext)

        queueLock.lock()
        jsQueue = newQueue
        context = newContext
        generation += 1
        queueLock.unlock()

        lastError = nil
    }

    func setBookBridge(_ bridge: LegadoBookBridge) {
        onJSQueue {
            self.bookBridge = bridge
            context.setObject(bridge, forKeyedSubscript: "book" as NSString)
        }
    }

    func setChapterBridge(_ bridge: LegadoChapterBridge) {
        onJSQueue {
            self.chapterBridge = bridge
            context.setObject(bridge, forKeyedSubscript: "chapter" as NSString)
            injectChapterGlobals(bridge, into: context)
        }
    }

    // MARK: - Private Helpers

    /// Configure a fresh JSContext with the bridge object and helpers.
    private func configureContext(_ ctx: JSContext) {
        // Exception handler
        ctx.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "Unknown JS error"
            self?.lastError = msg
            if msg.contains("eval() is disabled") {
                AppLogger.security("Book source JS attempted to use disabled eval(); blocked", context: ["error": msg])
            }
            // Surface uncaught rule-JS exceptions to the device log (Console) so book
            // source failures (TOC/content not loading, etc.) are diagnosable without
            // the in-app debug engine. Only uncaught exceptions reach this handler.
            AppLogger.parse("Book source rule JS exception", context: [
                "source": self?.bookSource?.bookSourceName ?? "?",
                "error": msg
            ])
            self?.errorHandler?(msg, "js exception")
            #if DEBUG
            print("[JSCoreEngine] JS Error: \(msg)")
            #endif
        }

        // Inject the `java` bridge object
        ctx.setObject(bridge, forKeyedSubscript: "java" as NSString)
        let getCookieBlock: @convention(block) (String, JSValue?) -> String = { [weak bridge] url, keyValue in
            guard let bridge else { return "" }
            let key: String
            if let keyValue, !keyValue.isUndefined, !keyValue.isNull {
                key = keyValue.toString() ?? ""
            } else {
                key = ""
            }
            return key.isEmpty ? bridge.getCookie(url) : bridge.getCookieValue(url, key)
        }
        ctx.setObject(getCookieBlock, forKeyedSubscript: "__yueduGetCookie" as NSString)
        ctx.evaluateScript("java.getCookie = __yueduGetCookie;")

        // Inject the `cookie` bridge object (get/set/remove via HTTPCookieStorage)
        ctx.setObject(cookieBridge, forKeyedSubscript: "cookie" as NSString)

        // SwiftSoup backing for the `org.jsoup.*` polyfill installed below.
        ctx.setObject(jsoupBridge, forKeyedSubscript: "__yueduJsoup" as NSString)

        // Inject `source` as a full bridge object (Legado-compatible)
        injectSourceObject(into: ctx)

        // Inject `cache` bridge object (persistent + memory key-value store)
        ctx.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)

        // Inject mutable book/chapter bridge objects used by Legado rule JS.
        ctx.setObject(bookBridge, forKeyedSubscript: "book" as NSString)
        ctx.setObject(chapterBridge, forKeyedSubscript: "chapter" as NSString)
        injectChapterGlobals(chapterBridge, into: ctx)

        // Inject a top-level `print` that delegates to java.log
        let printBlock: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            print("[JS] \(msg)")
            #endif
        }
        ctx.setObject(printBlock, forKeyedSubscript: "print" as NSString)

        // Note: eval() is intentionally LEFT ENABLED. The sandbox boundary for book
        // source JS is the bridge layer (java.*/source.*/cookie.*): JavaScriptCore code
        // can only reach the network/filesystem through those bridges, and eval()'d code
        // is confined to exactly the same surface as ordinary code. Many legitimate Legado
        // sources require eval — e.g. obfuscated jsLib loaders (`eval(java.importScript(url))`)
        // and explore builders (`eval('sort'+i+'.push(json)')`). Disabling it broke those
        // sources without adding real isolation, so native eval is used.

        // JSON is always natively available in JSContext — this guard is a safety net only.
        // The eval() fallback from the original Legado port has been removed (eval is disabled).
        ctx.evaluateScript("""
            if (typeof JSON === 'undefined') {
                var JSON = {
                    parse: function(s) { return null; },
                    stringify: function(o) { return ''; }
                };
            }
        """)

        // setResult() exposes JSON-string content to JS as an object so rules can do
        // `result.field` after a `$.data` step. But just as many Legado sources call
        // `JSON.parse(result)` expecting a string (e.g. 七猫/书旗 chapterList:
        // `JSON.parse(result).data.lists`). Native JSON.parse would stringify the object
        // to "[object Object]" and throw, killing the whole rule. Make JSON.parse return
        // an already-parsed object as-is; normal string parsing is unaffected.
        ctx.evaluateScript("""
            (function () {
                var __nativeParse = JSON.parse;
                JSON.parse = function (value, reviver) {
                    if (value !== null && typeof value === 'object') { return value; }
                    return __nativeParse(value, reviver);
                };
            })();
        """)

        // Legado helper functions frequently used by complex sources.
        // getArgument(key) reads source-level variables; setArgument(key, val) writes them.
        ctx.evaluateScript("""
            function getArgument(key) { return java.get(key) || ''; }
            function setArgument(key, value) { java.put(key, value); }
        """)

        // java.util.Map compatibility shim.
        // Legado runs on Rhino, where `source.getLoginInfoMap()` / `source.getHeaderMap()`
        // return real `java.util.Map` instances. Source jsLib routinely calls `.get(key)`
        // / `.put(key,val)` / `.containsKey(key)` on them (e.g. `getConfigValue` →
        // `infomap.get(key)`). JavaScriptCore bridges a Swift dictionary to a plain JS
        // object with no such methods, so those calls throw `… is not a function` and
        // abort the whole rule (symptom: book opens but TOC/content silently fail).
        // `__yueduJavaMap` augments a plain object in place with the Map methods as
        // non-enumerable properties, so `obj[key]` / `for..in` / `Object.keys` are
        // unaffected while `.get()` etc. work.
        ctx.evaluateScript("""
            function __yueduJavaMap(o) {
                o = o || {};
                function def(name, fn) {
                    Object.defineProperty(o, name, { value: fn, enumerable: false, configurable: true });
                }
                def('get', function (k) { var v = o[k]; return v === undefined ? null : v; });
                def('put', function (k, v) { o[k] = v; return v; });
                def('containsKey', function (k) { return Object.prototype.hasOwnProperty.call(o, k); });
                def('remove', function (k) { var v = o[k]; delete o[k]; return v === undefined ? null : v; });
                def('size', function () { return Object.keys(o).length; });
                def('isEmpty', function () { return Object.keys(o).length === 0; });
                def('keySet', function () { return Object.keys(o); });
                def('values', function () { return Object.keys(o).map(function (k) { return o[k]; }); });
                // LYC sources persist filter metadata through infoMap.save().
                // Their map is process-local here, so saving is intentionally a no-op.
                def('save', function () { return o; });
                return o;
            }
        """)

        // Luo-Ya-Cheng (洛雅橙/lyc) mod compatibility shim.
        // This must be installed after `__yueduJavaMap`: LYC explore scripts call
        // `infoMap.save()` while assembling their filter rows.
        //
        // `Set` doubles as LYC's key-value setter AND JavaScript's built-in Set
        // constructor. A plain `function Set(key, value)` shadowed the builtin, so any
        // source rule constructing `new Set()` (e.g. 企点 chapterList de-dups volume
        // names this way when 显示卷名 is on) got a method-less object, threw
        // "addedVolumes.has is not a function", and the whole TOC parse aborted
        // (symptom: 目录为空). Worse, the constructor call leaked a
        // `source.put(undefined, undefined)` into the variable store. Keep both callers
        // working: `new Set(...)` / bare `Set()` delegate to the native constructor,
        // while LYC's `Set(key, value)` call form still writes through `source.put`.
        ctx.evaluateScript("""
            function csh() {
                if (typeof source === 'undefined') return;
                var d = {
                    sort: '全部',
                    size: '30',
                    isfinish: 'all',
                    orderBy: 'newest',
                    fmale: '男频',
                    fxy: '0',
                    img: '1',
                    dp: '1',
                    jj: '0',
                    api: '1',
                    lock: '0',
                    zdy: '',
                };
                for (var k in d) {
                    if (!source.get(k)) source.put(k, d[k]);
                }
            }
            function Get(key) {
                if (typeof source !== 'undefined') return source.get(key) || '';
                return '';
            }
            (function (global) {
                var NativeSet = global.Set;
                function lycSet(key, value) {
                    if (new.target || arguments.length === 0) {
                        return arguments.length ? new NativeSet(key) : new NativeSet();
                    }
                    if (typeof source !== 'undefined') source.put(key, value);
                }
                lycSet.prototype = NativeSet.prototype;
                global.Set = lycSet;
            })(this);
            var infoMap = __yueduJavaMap({});
            function createFilter(sort, size, isfinish, orderBy, fmale) {
                // The source's jsLib may replace this fallback with its filter builder.
            }
        """)

        // Java crypto interop shim (Rhino `Packages.*` / `JavaImporter`).
        // Some Legado sources decrypt chapter content with RAW Java crypto, e.g.:
        //   var ji = new JavaImporter(); ji.importPackage(Packages.javax.crypto, ...);
        //   with (ji) { Cipher.getInstance("AES/CBC/PKCS5Padding").doFinal(...) }
        // None of that exists in JavaScriptCore. This shim provides just enough of the
        // `javax.crypto` / `java.util` surface (Cipher, SecretKeySpec, IvParameterSpec,
        // Base64, Arrays) backed by the native `java.aes*Hex` bridge, plus a tolerant
        // `Packages` proxy so merely importing an unsupported package never throws.
        ctx.evaluateScript("""
            (function () {
                function bytesToHex(bytes) {
                    var s = '';
                    for (var i = 0; i < bytes.length; i++) {
                        var h = (bytes[i] & 0xff).toString(16);
                        if (h.length < 2) h = '0' + h;
                        s += h;
                    }
                    return s;
                }
                var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
                function b64ToBytes(str) {
                    str = String(str).replace(/[^A-Za-z0-9+/]/g, ''); // drop '=' padding + whitespace
                    var bytes = [], i = 0;
                    while (i < str.length) {
                        var n = str.length - i; // chars left in this (possibly partial) quartet
                        var e1 = B64.indexOf(str.charAt(i));
                        var e2 = (n > 1) ? B64.indexOf(str.charAt(i + 1)) : -1;
                        var e3 = (n > 2) ? B64.indexOf(str.charAt(i + 2)) : -1;
                        var e4 = (n > 3) ? B64.indexOf(str.charAt(i + 3)) : -1;
                        if (e2 >= 0) bytes.push(((e1 << 2) | (e2 >> 4)) & 0xff);
                        if (e3 >= 0) bytes.push((((e2 & 15) << 4) | (e3 >> 2)) & 0xff);
                        if (e4 >= 0) bytes.push((((e3 & 3) << 6) | e4) & 0xff);
                        i += 4;
                    }
                    return bytes;
                }
                if (typeof String.prototype.getBytes !== 'function') {
                    Object.defineProperty(String.prototype, 'getBytes', {
                        value: function () {
                            var s = String(this), bytes = [];
                            for (var i = 0; i < s.length; i++) {
                                var c = s.charCodeAt(i);
                                if (c < 0x80) { bytes.push(c); }
                                else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
                                else if (c >= 0xd800 && c <= 0xdbff) {
                                    var c2 = s.charCodeAt(++i);
                                    var cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
                                    bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
                                } else { bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
                            }
                            return bytes;
                        }, enumerable: false, configurable: true, writable: true
                    });
                }
                function toByteArray(x) {
                    if (x == null) return [];
                    if (typeof x === 'string') return x.getBytes();
                    if (x.__bytes) return x.__bytes;
                    return x;
                }
                function SecretKeySpec(keyBytes, alg) { return { __bytes: toByteArray(keyBytes), __alg: alg }; }
                function IvParameterSpec(ivBytes) { return { __bytes: toByteArray(ivBytes) }; }
                var Cipher = {
                    getInstance: function (transformation) {
                        return {
                            __t: transformation, __mode: 0, __key: null, __iv: null,
                            init: function (mode, key, iv) {
                                this.__mode = mode;
                                this.__key = key && (key.__bytes || key);
                                this.__iv = iv && (iv.__bytes || iv);
                            },
                            doFinal: function (dataBytes) {
                                var keyHex = bytesToHex(this.__key || []);
                                var ivHex = bytesToHex(this.__iv || []);
                                var dataHex = bytesToHex(toByteArray(dataBytes));
                                var outHex = (this.__mode === 1)
                                    ? java.aesEncryptHex(this.__t, keyHex, ivHex, dataHex)
                                    : java.aesDecryptHex(this.__t, keyHex, ivHex, dataHex);
                                return java.hexDecodeToString(outHex);
                            }
                        };
                    }
                };
                function bytesToB64(bytes) {
                    var out = '', i = 0;
                    for (; i + 2 < bytes.length; i += 3) {
                        var n = ((bytes[i] & 0xff) << 16) | ((bytes[i + 1] & 0xff) << 8) | (bytes[i + 2] & 0xff);
                        out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) + B64.charAt((n >> 6) & 63) + B64.charAt(n & 63);
                    }
                    var rem = bytes.length - i;
                    if (rem === 1) {
                        var n1 = (bytes[i] & 0xff) << 16;
                        out += B64.charAt((n1 >> 18) & 63) + B64.charAt((n1 >> 12) & 63) + '==';
                    } else if (rem === 2) {
                        var n2 = ((bytes[i] & 0xff) << 16) | ((bytes[i + 1] & 0xff) << 8);
                        out += B64.charAt((n2 >> 18) & 63) + B64.charAt((n2 >> 12) & 63) + B64.charAt((n2 >> 6) & 63) + '=';
                    }
                    return out;
                }
                function hexToByteArray(hex) {
                    var out = [];
                    for (var i = 0; i + 1 < hex.length; i += 2) { out.push(parseInt(hex.substr(i, 2), 16)); }
                    return out;
                }
                // hutool SymmetricCrypto shim (Legado `java.createSymmetricCrypto`),
                // backed by the native java.aes*Hex bridge (which handles the AES and
                // DES families — 书山聚合 decrypts chapter text with DES/CBC/PKCS5Padding).
                // Used by imageDecode / coverDecodeJs and content-decryption sources.
                java.createSymmetricCrypto = function (transformation, key, iv) {
                    var t = String(transformation || 'AES');
                    if (t.indexOf('/') < 0) { t = t + '/ECB/PKCS5Padding'; }
                    var keyHex = bytesToHex(toByteArray(key));
                    var ivHex = (iv == null) ? '' : bytesToHex(toByteArray(iv));
                    function dataToHex(data) {
                        if (data == null) return '';
                        if (typeof data === 'string') {
                            var s = data.replace(/\\s+/g, '');
                            if (/^[0-9A-Fa-f]+$/.test(s) && s.length % 2 === 0) return s.toLowerCase();
                            if (/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return bytesToHex(b64ToBytes(s));
                            return bytesToHex(String(data).getBytes());
                        }
                        return bytesToHex(toByteArray(data));
                    }
                    return {
                        decrypt: function (data) { return hexToByteArray(java.aesDecryptHex(t, keyHex, ivHex, dataToHex(data))); },
                        decryptStr: function (data) { return java.hexDecodeToString(java.aesDecryptHex(t, keyHex, ivHex, dataToHex(data))); },
                        encrypt: function (data) { return hexToByteArray(java.aesEncryptHex(t, keyHex, ivHex, dataToHex(data))); },
                        encryptBase64: function (data) { return bytesToB64(hexToByteArray(java.aesEncryptHex(t, keyHex, ivHex, dataToHex(data)))); },
                        encryptHex: function (data) { return java.aesEncryptHex(t, keyHex, ivHex, dataToHex(data)); }
                    };
                };
                // Legado compat.js helpers: aesBase64Decode / aesBase64DecodeToString.
                // Convenience functions that combine Base64 decode + AES decrypt.
                // Comic sources like 全免漫画 (kaimanhua.com) call these directly on
                // chapter content that is Base64-encoded AES ciphertext.
                // Signature: (base64Data, keyStr, transformation, ivStr)
                // keyStr / ivStr are plain strings -> getBytes() -> hex for native bridge.
                java.aesBase64Decode = function (base64Str, keyStr, transformation, ivStr) {
                    var dataBytes = b64ToBytes(String(base64Str || ''));
                    var keyHex = bytesToHex(String(keyStr || '').getBytes());
                    var ivHex = (ivStr == null) ? '' : bytesToHex(String(ivStr).getBytes());
                    var outHex = java.aesDecryptHex(String(transformation || 'AES'), keyHex, ivHex, bytesToHex(dataBytes));
                    return hexToByteArray(outHex);
                };
                java.aesBase64DecodeToString = function (base64Str, keyStr, transformation, ivStr) {
                    var dataBytes = b64ToBytes(String(base64Str || ''));
                    var keyHex = bytesToHex(String(keyStr || '').getBytes());
                    var ivHex = (ivStr == null) ? '' : bytesToHex(String(ivStr).getBytes());
                    var outHex = java.aesDecryptHex(String(transformation || 'AES'), keyHex, ivHex, bytesToHex(dataBytes));
                    return java.hexDecodeToString(outHex);
                };
                var Base64 = {
                    getDecoder: function () { return { decode: function (s) { return b64ToBytes(s); } }; },
                    getEncoder: function () { return { encodeToString: function (bytes) { return bytesToB64(bytes); } }; }
                };
                var Arrays = { copyOfRange: function (arr, from, to) { return Array.prototype.slice.call(arr, from, to); } };
                var members = {
                    'javax.crypto': { Cipher: Cipher },
                    'javax.crypto.spec': { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec },
                    'java.util': { Base64: Base64, Arrays: Arrays }
                };
                function makeNamespace(path) {
                    var mem = members[path] || {};
                    var target = function () {};
                    target.__members = mem;
                    for (var k in mem) { target[k] = mem[k]; }
                    return new Proxy(target, {
                        get: function (t, prop) {
                            if (typeof prop !== 'string') { return t[prop]; }
                            if (prop === '__members') { return mem; }
                            if (prop in t) { return t[prop]; }
                            return makeNamespace(path ? path + '.' + prop : prop);
                        },
                        apply: function () { return undefined; },
                        // `new Packages.java.util.HashMap()` etc. — source login/menu JS builds
                        // Java collections to hand back through java.upLoginData(map). Return a
                        // usable map/list instead of a bare {} (which has no .put → would throw).
                        construct: function (t, args) {
                            var name = path.split('.').pop();
                            if (name === 'HashMap' || name === 'LinkedHashMap' ||
                                name === 'TreeMap' || name === 'Hashtable' || name === 'Properties') {
                                return (typeof __yueduJavaMap === 'function') ? __yueduJavaMap({}) : {};
                            }
                            if (name === 'ArrayList' || name === 'LinkedList' || name === 'Vector') {
                                return [];
                            }
                            return {};
                        }
                    });
                }
                this.Packages = makeNamespace('');
                function JavaImporter() {
                    var self = {};
                    self.importPackage = function () {
                        for (var i = 0; i < arguments.length; i++) {
                            var mem = arguments[i] && arguments[i].__members;
                            if (mem) { for (var k in mem) { self[k] = mem[k]; } }
                        }
                    };
                    self.importClass = self.importPackage;
                    return self;
                }
                this.JavaImporter = JavaImporter;
            })();
        """)

        // org.jsoup.Jsoup polyfill.
        // Legado Android uses Rhino with full Java interop, so book sources can call
        // `org.jsoup.Jsoup.connect(url).execute().body()` directly. JavaScriptCore has
        // no Java interop, so `org` is undefined → "undefined is not an object" crashes
        // obfuscated content scripts (e.g. 番茄酱's remote `to.js`). This polyfill delegates
        // HTTP to the existing `java.ajax` (GET) / `java.post` (POST) bridges. Response
        // headers are not available through `java.ajax` (it returns body only), so
        // `headers().get(name)` returns null — sources that rely on ETag caching fall
        // back to their catch block, which is the existing behaviour.
        ctx.evaluateScript("""
            (function () {
                function Connection(url) {
                    this._url = String(url || '');
                    this._method = 'GET';
                    this._headers = {};
                    this._data = {};
                    this._timeout = 10000;
                    this._ua = '';
                    this._referrer = '';
                    this._body = null;
                }
                var P = Connection.prototype;
                P.method = function (m) { this._method = (typeof m === 'string') ? m : (m && m.name) || 'GET'; return this; };
                P.header = function (k, v) { this._headers[k] = String(v); return this; };
                P.headers = function (h) { if (h) for (var k in h) this._headers[k] = String(h[k]); return this; };
                P.data = function (k, v) {
                    if (arguments.length === 1 && typeof k === 'object') { for (var key in k) this._data[key] = String(k[key]); }
                    else { this._data[k] = String(v); }
                    return this;
                };
                P.requestBody = function (b) { this._body = (arguments.length === 0) ? null : String(b); return this; };
                P.cookie = function (k, v) { return this; };
                P.ignoreContentType = function (b) { return this; };
                P.timeout = function (ms) { this._timeout = parseInt(ms) || 10000; return this; };
                P.userAgent = function (ua) { this._ua = String(ua); return this; };
                P.referrer = function (r) { this._referrer = String(r); return this; };
                P.followRedirects = function (b) { return this; };
                P.sslSocketFactory = function () { return this; };
                P.execute = function () { return new Response(this._fetch(), this._url); };
                P.get = function () { this._method = 'GET'; return JsoupParse(this._fetch(), this._url); };
                P.post = function () { this._method = 'POST'; return JsoupParse(this._fetch(), this._url); };
                P._fetch = function () {
                    var url = this._url, pairs = [], hasData = false;
                    for (var k in this._data) { hasData = true; pairs.push(encodeURIComponent(k) + '=' + encodeURIComponent(this._data[k])); }
                    var dataStr = pairs.join('&');
                    if (this._method === 'POST' || this._method === 'PUT') {
                        var body = this._body || dataStr;
                        var hdrs = this._headers;
                        if (dataStr && !this._body && !hdrs['Content-Type']) hdrs['Content-Type'] = 'application/x-www-form-urlencoded';
                        var r = java.post(url, body, hdrs);
                        return (r && typeof r.body === 'function') ? r.body() : String(r || '');
                    }
                    if (hasData) url += (url.indexOf('?') < 0 ? '?' : '&') + dataStr;
                    return java.ajax(url);
                };
                function Response(body, url) { this._body = body || ''; this._url = url; }
                var RP = Response.prototype;
                RP.body = function () { return this._body; };
                RP.text = function () { return this._body; };
                RP.html = function () { return this._body; };
                RP.header = function (n) { return null; };
                RP.get = function (n) { return null; };
                RP.headers = function () { return { get: function () { return null; }, has: function () { return false; }, size: function () { return 0; } }; };
                RP.statusCode = function () { return 200; };
                RP.contentType = function () { return 'text/html'; };
                RP.url = function () { return this._url; };
                RP.parse = function () { return JsoupParse(this._body, this._url); };
                RP.statusMessage = function () { return 'OK'; };

                // `_n` is a native SwiftSoup node (`__yueduJsoup`). JavaScriptCore owns its
                // lifetime, so a selected element stays valid for as long as JS holds it —
                // serialising back to a string between calls would mangle fragments the HTML
                // parser is context-sensitive about (`<body>`, `<td>`, `<li>`, …).
                // Mutating methods stay no-ops: the document is shared via JsoupDocumentCache.
                function Element(node, baseUrl) { this._n = node || null; this._baseUrl = baseUrl || ''; }
                function wrap(list, baseUrl) {
                    var out = [];
                    if (list) for (var i = 0; i < list.length; i++) out.push(new Element(list[i], baseUrl));
                    return new Elements(out);
                }
                var EP = Element.prototype;
                EP.html = function () { return this._n ? this._n.html() : ''; };
                EP.text = function () { return this._n ? this._n.text() : ''; };
                EP.ownText = function () { return this._n ? this._n.ownText() : ''; };
                EP.outerHtml = function () { return this._n ? this._n.outerHtml() : ''; };
                EP.toString = function () { return this.outerHtml(); };
                EP.attr = function (k, v) { if (arguments.length === 2) { return this; } return this._n ? this._n.attr(String(k)) : ''; };
                EP.select = function (q) { return wrap(this._n ? this._n.select(String(q)) : [], this._baseUrl); };
                EP.first = function () { return null; };
                EP.last = function () { return null; };
                EP.children = function () { return wrap(this._n ? this._n.children() : [], this._baseUrl); };
                EP.child = function (i) { return this.children().get(i); };
                EP.parent = function () { var p = this._n ? this._n.parent() : null; return p ? new Element(p, this._baseUrl) : null; };
                EP.nextElementSibling = function () { return null; };
                EP.previousElementSibling = function () { return null; };
                EP.appendChild = function (el) { return this; };
                EP.prependChild = function (el) { return this; };
                EP.remove = function () { return this; };
                EP.tagName = function () { return (this._n ? this._n.tagName() : '') || 'div'; };
                EP.nodeName = function () { return this.tagName(); };
                EP.id = function () { return this._n ? this._n.id() : ''; };
                EP.className = function () { return this._n ? this._n.className() : ''; };
                EP.hasClass = function (c) { return (' ' + this.className() + ' ').indexOf(' ' + c + ' ') >= 0; };
                EP.getElements = function () { return this.select('*'); };
                EP.getAllElements = function () { return this.select('*'); };
                EP.getElementById = function (id) { return this.select('#' + id).first(); };
                EP.getElementsByClass = function (c) { return this.select('.' + c); };
                EP.getElementsByTag = function (t) { return this.select(String(t)); };
                EP.getElementsByAttribute = function (a) { return this.select('[' + a + ']'); };
                EP.getElementsByAttributeValue = function (a, v) { return this.select('[' + a + '="' + v + '"]'); };
                EP.getElementsByAttributeValueContaining = function (a, v) { return this.select('[' + a + '*="' + v + '"]'); };
                EP.absUrl = function (k) { return this.attr(k); };
                EP.baseUri = function () { return this._baseUrl; };
                EP.parentNode = function () { return this.parent(); };
                EP.wholeText = function () { return this.text(); };
                EP.data = function () { return ''; };
                EP.val = function () { return this.attr('value'); };
                EP.textNode = function () { return this.text(); };
                EP.hasAttr = function (k) { return this._n ? this._n.hasAttr(String(k)) : false; };
                EP.removeAttr = function () { return this; };

                function Elements(arr) { this._arr = arr || []; }
                var ESP = Elements.prototype;
                ESP.size = function () { return this._arr.length; };
                ESP.size2 = function () { return this._arr.length; };
                Object.defineProperty(ESP, 'length', { get: function () { return this._arr.length; }, configurable: true });
                ESP.get = function (i) { return this._arr[i] || null; };
                ESP.first = function () { return this._arr[0] || null; };
                ESP.last = function () { return this._arr[this._arr.length - 1] || null; };
                ESP.text = function () { return this._arr.map(function (e) { return e.text(); }).join(''); };
                ESP.html = function () { return this._arr.map(function (e) { return e.html(); }).join(''); };
                ESP.each = function (fn) { this._arr.forEach(fn); return this; };
                ESP.forEach = function (fn) { this._arr.forEach(fn); return this; };
                ESP.attr = function () { return this._arr[0] ? this._arr[0].attr.apply(this._arr[0], arguments) : ''; };
                ESP.hasAttr = function (k) { return this._arr.some(function (e) { return e.hasAttr(k); }); };
                ESP.select = function (q) {
                    var out = [];
                    this._arr.forEach(function (e) { e.select(q).each(function (m) { out.push(m); }); });
                    return new Elements(out);
                };
                ESP.outerHtml = function () { return this._arr.map(function (e) { return e.outerHtml(); }).join(''); };
                ESP.toString = function () { return this.outerHtml(); };
                ESP.not = function () { return this; };
                ESP.eq = function (i) { return new Elements([this._arr[i]]); };
                ESP.is = function () { return false; };
                ESP.empty = function () { return this._arr.length === 0; };
                ESP.iterator = function () { return this._arr[Symbol.iterator](); };
                ESP[Symbol.iterator] = function () { return this._arr[Symbol.iterator](); };

                function Document(node, baseUrl) { Element.call(this, node, baseUrl); }
                Document.prototype = Object.create(Element.prototype);
                Document.prototype.constructor = Document;
                Document.prototype.body = function () { var b = this._n ? this._n.body() : null; return new Element(b, this._baseUrl); };
                Document.prototype.head = function () { return this.select('head').first() || new Element(null, this._baseUrl); };
                Document.prototype.title = function () { return this._n ? this._n.title() : ''; };
                Document.prototype.setBaseUri = function () { return this; };
                Document.prototype.outputSettings = function () { return this; };

                function JsoupParse(html, baseUrl) {
                    return new Document(__yueduJsoup.parse(html == null ? '' : String(html), baseUrl), baseUrl);
                }

                var Method = { GET: 'GET', POST: 'POST', HEAD: 'HEAD', PUT: 'PUT', DELETE: 'DELETE', OPTIONS: 'OPTIONS', PATCH: 'PATCH', TRACE: 'TRACE' };

                this.org = {
                    jsoup: {
                        Jsoup: { connect: function (url) { return new Connection(url); }, parse: function (h, b) { return JsoupParse(h, b); }, parseBodyFragment: function (h, b) { return JsoupParse(h, b); }, clean: function (h) { return h; } },
                        Connection: { Method: Method, Response: Response, KeyVal: { create: function (k, v) { return { key: function () { return k; }, value: function () { return v; } }; } } },
                        nodes: { Document: Document, Element: Element, TextNode: Element },
                        safety: { Clean: { clean: function (h) { return h; } } },
                        select: { Selector: { select: function (q, root) { return root ? root.select(q) : new Elements([]); } } },
                        parser: { Parser: { parse: function (h, b) { return JsoupParse(h, b); } } },
                        helper: { HttpConnection: { connect: function (url) { return new Connection(url); } } }
                    }
                };
            })();
        """)
    }

    /// Some Legado/Rhino source scripts read current-chapter fields as bare globals
    /// (`title`, `url`, `index`) instead of going through `chapter.title`.
    /// JavaScriptCore does not synthesize those globals from the exported `chapter` object,
    /// so keep them explicitly mirrored whenever the chapter bridge changes.
    private func injectChapterGlobals(_ bridge: LegadoChapterBridge, into ctx: JSContext) {
        ctx.setObject(bridge.title, forKeyedSubscript: "title" as NSString)
        ctx.setObject(bridge.title, forKeyedSubscript: "chapterTitle" as NSString)
        ctx.setObject(bridge.url, forKeyedSubscript: "url" as NSString)
        ctx.setObject(bridge.url, forKeyedSubscript: "chapterUrl" as NSString)
        ctx.setObject(bridge.index, forKeyedSubscript: "index" as NSString)
        ctx.setObject(bridge.index, forKeyedSubscript: "chapterIndex" as NSString)
        ctx.setObject(bridge.order, forKeyedSubscript: "order" as NSString)
        ctx.setObject(bridge.order, forKeyedSubscript: "chapterOrder" as NSString)
        ctx.setObject(bridge.isVip(), forKeyedSubscript: "isVip" as NSString)
    }

    /// Inject `source` as a Legado-compatible bridge object with methods and properties.
    private func injectSourceObject(into ctx: JSContext) {
        ctx.setObject(sourceBridge, forKeyedSubscript: "source" as NSString)
    }

    private func setResult(_ result: Any?) {
        guard let result else {
            context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)
            return
        }
        if let string = result as? String,
           let jsonObject = Self.jsonObjectIfPossible(from: string) {
            context.setObject(jsonObject, forKeyedSubscript: "result" as NSString)
            return
        }
        context.setObject(result, forKeyedSubscript: "result" as NSString)
    }

    private static func jsonObjectIfPossible(from string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// Parse a Legado header string (JSON object, `@js:`/`<js>` rule, or
    /// "Key: Value\nKey2: Value2") into a dictionary.
    ///
    /// Mirrors `BaseSource.getHeaderMap()`: a header rule may be JS that *builds*
    /// the map (书山聚合 emits `java.getWebViewUA()` plus a constant API token that
    /// its server requires on every endpoint). Evaluating it here is what makes
    /// those headers reach the request at all.
    func parseHeaders(_ headerStr: String) -> [String: String] {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if let script = Self.headerJSScript(trimmed) {
            let evaluated = (evaluate(script) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !evaluated.isEmpty, let data = evaluated.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                // A JS header rule that fails must yield nothing: the line-format
                // fallback below would otherwise mine the *script text* for colons
                // and emit junk headers such as `"User-Agent": java.getWebViewUA(),`.
                AppLogger.parse("header JS produced no header map", context: [
                    "rule": String(trimmed.prefix(120)),
                    "result": String(evaluated.prefix(120)),
                    "jsError": lastError ?? "-"
                ])
                return [:]
            }
            return json
        }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return json
        }
        // Fallback: "Key: Value" line format
        var result: [String: String] = [:]
        trimmed.components(separatedBy: "\n").forEach { line in
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    /// The JS body of a `@js:` / `<js>…</js>` header rule, or nil for a plain header.
    static func headerJSScript(_ headerStr: String) -> String? {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.lowercased().hasPrefix("<js>"),
           let close = trimmed.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<close.lowerBound])
        }
        return nil
    }

    /// Extract a usable String from a JSValue, returning nil for undefined/null/error.
    private func extractString(from value: JSValue) -> String? {
        if lastError != nil { return nil }
        if value.isUndefined || value.isNull { return nil }

        // Arrays and objects → JSON string.
        // Uses JavaScriptCore's own JSON.stringify instead of NSJSONSerialization,
        // because NSJSONSerialization raises an *uncatchable* ObjC exception
        // (NSInvalidArgumentException) for values that JS bridges as non-JSON-safe
        // objects (Map, Set, Proxy, functions with custom toJSON, etc.).
        // JSON.stringify returns `undefined` for unserialisable values, which we
        // fall through from gracefully.
        if value.isArray || value.isObject {
            guard let ctx = value.context else { return value.toString() }
            ctx.setObject(value, forKeyedSubscript: "__yuedu_jsonify" as NSString)
            let jsonVal = ctx.evaluateScript("JSON.stringify(__yuedu_jsonify)")
            ctx.evaluateScript("delete __yuedu_jsonify")
            if let jsonVal,
               !jsonVal.isUndefined, !jsonVal.isNull,
               let json = jsonVal.toString(), !json.isEmpty {
                return json
            }
        }

        return value.toString()
    }
}
