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
    private let jsQueue = DispatchQueue(label: "com.yuedu.jsengine.serial", qos: .userInitiated)
    private let jsQueueKey = DispatchSpecificKey<Void>()

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

    /// Called when JS invokes `java.toast` / `java.longToast`.
    var toastHandler: ((String) -> Void)? {
        didSet { bridge.toastHandler = toastHandler }
    }

    /// Book source object injected as `source` in JS — set this before evaluating rule scripts.
    var bookSource: BookSource? {
        didSet {
            onJSQueue {
                guard let src = bookSource else {
                    sourceBridge = LegadoSourceBridge(
                        bookSourceUrl: "", bookSourceName: "", bookSourceGroup: "",
                        bookSourceComment: "", loginUrl: "", header: "", loginCheckJs: ""
                    )
                    cacheBridge = LegadoCacheBridge(sourceId: "")
                    bridge.sourceHeaders = [:]
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
                bridge.sourceHeaders = parseHeaders(src.header)
            }
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
    }

    // MARK: - Public API

    /// Dispatch work to the JS serial queue, re-entrant-safe.
    /// If already executing on the JS queue (e.g. java.getString → engine.getString → evaluate),
    /// the work runs inline to avoid a deadlock.
    private func onJSQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: jsQueueKey) != nil {
            return work() // already on the JS queue — run inline
        }
        return jsQueue.sync { work() }
    }

    /// Evaluate JavaScript code and return the result as a string.
    /// Returns `nil` on JS error or if the result is `undefined`/`null`.
    func evaluate(_ script: String) -> String? {
        onJSQueue {
            lastError = nil
            guard let value = context.evaluateScript(script) else { return nil }
            return extractString(from: value)
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
        onJSQueue {
            lastError = nil
            setResult(result)
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            guard let value = context.evaluateScript(script) else { return nil }
            return extractString(from: value)
        }
    }

    /// Evaluate with multiple bindings injected into the context before execution.
    func evaluate(_ script: String, bindings: [String: Any]) -> String? {
        onJSQueue {
            lastError = nil
            for (key, value) in bindings {
                context.setObject(value, forKeyedSubscript: key as NSString)
            }
            guard let val = context.evaluateScript(script) else { return nil }
            return extractString(from: val)
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

    /// Reset the context — clears all JS variables and re-injects the bridge.
    func reset() {
        onJSQueue {
            let ctx = JSContext()!
            self.context = ctx
            configureContext(ctx)
            lastError = nil
        }
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

        // Inject `source` as a full bridge object (Legado-compatible)
        injectSourceObject(into: ctx)

        // Inject `cache` bridge object (persistent + memory key-value store)
        ctx.setObject(cacheBridge, forKeyedSubscript: "cache" as NSString)

        // Inject mutable book/chapter bridge objects used by Legado rule JS.
        ctx.setObject(bookBridge, forKeyedSubscript: "book" as NSString)
        ctx.setObject(chapterBridge, forKeyedSubscript: "chapter" as NSString)

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

    /// Parse a Legado header string (JSON object or "Key: Value\nKey2: Value2") into a dictionary.
    func parseHeaders(_ headerStr: String) -> [String: String] {
        let trimmed = headerStr.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Extract a usable String from a JSValue, returning nil for undefined/null/error.
    private func extractString(from value: JSValue) -> String? {
        if lastError != nil { return nil }
        if value.isUndefined || value.isNull { return nil }

        // Arrays and objects → JSON string
        if value.isArray || value.isObject {
            if let data = try? JSONSerialization.data(
                withJSONObject: value.toObject() as Any, options: []
            ), let json = String(data: data, encoding: .utf8) {
                return json
            }
        }

        return value.toString()
    }
}
