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
    private let lock = NSLock()
    private let bridge: LegadoJSBridge
    private let cookieBridge = LegadoCookieBridge()

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

    /// Handle `java.getString(ruleStr)` — connected to ModernRuleEngine later.
    var getStringHandler: ((String) -> String?)? {
        didSet { bridge.getStringHandler = getStringHandler }
    }

    /// Handle `java.getStringList(ruleStr)` — connected to ModernRuleEngine later.
    var getStringListHandler: ((String) -> [String]?)? {
        didSet { bridge.getStringListHandler = getStringListHandler }
    }

    /// Book source object injected as `source` in JS — set this before evaluating rule scripts.
    var bookSource: BookSource? {
        didSet {
            lock.lock()
            defer { lock.unlock() }
            injectSourceObject(into: context)
            bridge.sourceHeaders = parseHeaders(bookSource?.header ?? "")
        }
    }

    // MARK: - Initializer

    init() {
        let ctx = JSContext()!
        self.context = ctx
        self.bridge = LegadoJSBridge()

        configureContext(ctx)
    }

    // MARK: - Public API

    /// Evaluate JavaScript code and return the result as a string.
    /// Returns `nil` on JS error or if the result is `undefined`/`null`.
    func evaluate(_ script: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        lastError = nil

        guard let value = context.evaluateScript(script) else { return nil }
        return extractString(from: value)
    }

    /// Evaluate with a `result` variable pre-set (Legado convention:
    /// the previous rule step's output is available as `result` in JS).
    func evaluate(_ script: String, result: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        lastError = nil

        if let result = result {
            context.setObject(result, forKeyedSubscript: "result" as NSString)
        } else {
            context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)
        }

        guard let value = context.evaluateScript(script) else { return nil }
        return extractString(from: value)
    }

    /// Evaluate with multiple bindings injected into the context before execution.
    func evaluate(_ script: String, bindings: [String: Any]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        lastError = nil

        for (key, value) in bindings {
            context.setObject(value, forKeyedSubscript: key as NSString)
        }

        guard let val = context.evaluateScript(script) else { return nil }
        return extractString(from: val)
    }

    /// Reset the context — clears all JS variables and re-injects the bridge.
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        let ctx = JSContext()!
        self.context = ctx
        configureContext(ctx)
        lastError = nil
    }

    // MARK: - Private Helpers

    /// Configure a fresh JSContext with the bridge object and helpers.
    private func configureContext(_ ctx: JSContext) {
        // Exception handler
        ctx.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "Unknown JS error"
            self?.lastError = msg
            #if DEBUG
            print("[JSCoreEngine] JS Error: \(msg)")
            #endif
        }

        // Inject the `java` bridge object
        ctx.setObject(bridge, forKeyedSubscript: "java" as NSString)

        // Inject the `cookie` bridge object (get/set/remove via HTTPCookieStorage)
        ctx.setObject(cookieBridge, forKeyedSubscript: "cookie" as NSString)

        // Inject `source` object (may be nil at configure time; bookSource didSet re-injects)
        injectSourceObject(into: ctx)

        // Inject a top-level `print` that delegates to java.log
        let printBlock: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            print("[JS] \(msg)")
            #endif
        }
        ctx.setObject(printBlock, forKeyedSubscript: "print" as NSString)

        // JSON polyfill safety — JSContext already has JSON, but ensure it exists
        ctx.evaluateScript("""
            if (typeof JSON === 'undefined') {
                var JSON = { parse: function(s){return eval('('+s+')');}, stringify: function(o){return ''} };
            }
        """)
    }

    /// Inject `source` as a plain JS object derived from BookSource properties.
    private func injectSourceObject(into ctx: JSContext) {
        guard let src = bookSource else {
            ctx.setObject([:] as [String: Any], forKeyedSubscript: "source" as NSString)
            return
        }
        var obj: [String: Any] = [
            "bookSourceUrl": src.bookSourceUrl,
            "bookSourceName": src.bookSourceName,
            "bookSourceGroup": src.bookSourceGroup ?? "",
            "bookSourceComment": src.bookSourceComment ?? "",
            "loginUrl": src.loginUrl,
            "loginUi": src.loginUi,
            "loginCheckJs": src.loginCheckJs,
            "header": src.header,
        ]
        if !src.variableComment.isEmpty { obj["variableComment"] = src.variableComment }
        ctx.setObject(obj, forKeyedSubscript: "source" as NSString)
    }

    /// Parse a Legado header string (JSON object or "Key: Value\nKey2: Value2") into a dictionary.
    private func parseHeaders(_ headerStr: String) -> [String: String] {
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
