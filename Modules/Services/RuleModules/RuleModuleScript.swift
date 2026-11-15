import CryptoKit
import Foundation
import JavaScriptCore
import os

// A module's JavaScript (format 3.0.2, `javascript: true`; maintainer, 2026-11-15: 「跑 js 也行」,
// then 受限 JS over the 來源配置 runtime). A site's comments are asked with a signed request and
// answered encrypted often enough that rules alone read few of them.
//
// The script computes; it never connects. Its context is a bare `JSContext` (JavaScriptCore
// gives one no network, timer or file) with `java`, an object of the pure functions below under
// the names a 來源配置's script calls them by, so one ports with small edits. Every request is
// still `RuleModuleClient.send`'s, so the module's `hosts` hold whatever the script does: a
// request script only writes the address, the headers and the body that `send` then checks.
//
// The 來源配置 runtime (`JSCoreEngine`, `LegadoJSBridge`) is not used: it reaches the network at
// nine request sites, a raw socket and a headless web view, and reads cookies and the device's
// identity, none of which `hosts` could bound.

/// One module's script context, kept for the module's every rule and request (one per module
/// version: the context is the cost, as `BookSourceSession` found for a 來源配置).
final class RuleModuleScriptRuntime: Sendable {
    /// Wall-clock time one script may take. Short: a rule's script runs where its page is read.
    static let timeout: TimeInterval = 2
    static let maxScriptLength = 100 * 1024

    /// Every function `java` has. `ModuleScriptAndCommentsTests` reads the context's own list against it.
    static let functions: [String] = [
        "log", "md5Encode", "md5Encode16", "digestHex", "HMacHex", "HMacBase64",
        "base64Encode", "base64Decode", "base64DecodeStr", "hexEncodeToString", "hexDecodeToString",
        "aesEncodeToBase64String", "aesBase64DecodeToString", "aesEncodeToString", "aesDecodeToString",
        "randomUUID", "encodeURI",
    ]

    private struct State {
        var context: JSConfined<JSContext>?
        /// A script ran past `timeout`. Its thread cannot be stopped (JavaScriptCore has no public
        /// way), so it still holds the context: the module's scripts answer nothing until the app
        /// starts again, and one module leaves one such thread at most.
        var hasRunAway = false
    }

    let moduleID: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// One script at a time: the context has one set of globals.
    private let turn = NSLock()

    init(moduleID: String) {
        self.moduleID = moduleID
    }

    // MARK: - Runtimes

    private static let runtimes = OSAllocatedUnfairLock<[String: RuleModuleScriptRuntime]>(initialState: [:])

    /// The module's runtime, nil for a module that does not declare `javascript`.
    static func runtime(for module: RuleModule) -> RuleModuleScriptRuntime? {
        guard module.javascript == true else { return nil }
        let key = "\(module.id)\u{1F}\(module.version)"
        return runtimes.withLock { held in
            if let found = held[key] { return found }
            // An update replaces the module's earlier version's.
            held = held.filter { !$0.key.hasPrefix("\(module.id)\u{1F}") }
            let made = RuleModuleScriptRuntime(moduleID: module.id)
            held[key] = made
            return made
        }
    }

    /// A rule engine whose `@js:` and `<js>` steps run in `runtime`; a bare one without it.
    static func engine(_ runtime: RuleModuleScriptRuntime?) -> ModernRuleEngine {
        let engine = ModernRuleEngine()
        guard let runtime else { return engine }
        engine.jsEvaluator = { [weak engine] script, result in
            runtime.evaluate(script, bindings: ["result": Self.scriptValue(result), "baseUrl": engine?.baseUrl ?? ""])
        }
        return engine
    }

    /// What a rule step hands its script: text as it is, JSON as its object, anything else
    /// (an HTML element) as its text.
    private static func scriptValue(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let text as String: return text
        // A rule's text result, as the engine hands it to a script (`JSCoreEngine.ScriptString`).
        case let text as JSCoreEngine.ScriptString: return text.value
        case let object as [String: Any]: return object
        case let list as [Any]: return list
        case let number as NSNumber: return number
        case let value?: return "\(value)"
        }
    }

    // MARK: - Request script

    /// A request as its `script` may rewrite it.
    struct Request: Equatable, Sendable {
        var url: String
        var method: String
        var body: String?
        var headers: [String: String]
    }

    /// `request` after the module's `script` ran with it as the global `request` and the
    /// templates' values as `values`: the object the script returns, else `request` as it left
    /// it. Throws when the script fails or names no address: an unsigned request would only be
    /// refused by the site, as a failure with no cause in the log.
    func rewrite(_ request: Request, by script: String, values: [String: String]) throws -> Request {
        var object: [String: Any] = ["url": request.url, "method": request.method, "headers": request.headers]
        if let body = request.body { object["body"] = body }
        guard let text = evaluate(script, bindings: ["request": object, "values": values], fallbackGlobal: "request"),
              let data = text.data(using: .utf8),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = answer["url"] as? String, !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SourceFailure(kind: .parse, underlying: RuleModuleScriptError.requestScriptFailed(module: moduleID))
        }
        var headers: [String: String] = [:]
        for (name, value) in answer["headers"] as? [String: Any] ?? [:] {
            headers[name] = (value as? String) ?? "\(value)"
        }
        let body: String? = (answer["body"] as? String) ?? (answer["body"] is NSNull || answer["body"] == nil ? nil : "\(answer["body"]!)")
        return Request(url: url, method: ((answer["method"] as? String) ?? request.method).uppercased(), body: body, headers: headers)
    }

    // MARK: - Evaluation

    /// The script's value as text: a string as it is, an object or array as JSON (which a list
    /// rule reads back as its items), a number or boolean as written. Nil for `null`,
    /// `undefined`, an exception, a script too long, or a module whose script ran away. With
    /// `fallbackGlobal`, a value that is no object is replaced by that global's.
    func evaluate(_ script: String, bindings: [String: Any], fallbackGlobal: String? = nil) -> String? {
        guard script.count <= Self.maxScriptLength else {
            AppLogger.error("Module script too long", context: ["module": moduleID, "length": script.count], level: .warning)
            return nil
        }
        turn.lock()
        defer { turn.unlock() }
        let (hasRunAway, held) = state.withLock { ($0.hasRunAway, $0.context) }
        guard !hasRunAway else { return nil }
        // The context and the bindings are used on the script's thread only until it delivers.
        let input = JSConfined(bindings)
        let moduleID = moduleID, state = state
        let result = BlockingResult<String?>()
        Thread.detachNewThread {
            // Every JavaScriptCore value of the context is made and released here, in this pool:
            // releasing one takes the context's lock, which a script that runs away never gives
            // back. One made on the caller's thread hung it at its next autorelease pool pop
            // (`ModuleScriptAndCommentsTests.runaway`, sampled 2026-11-15: `-[JSValue dealloc]` under
            // `objc_autoreleasePoolPop` on the main thread).
            autoreleasepool {
                let context = held?.value ?? Self.makeContext(moduleID: moduleID)
                if held == nil {
                    let made = JSConfined(context)
                    state.withLock { if !$0.hasRunAway { $0.context = made } }
                }
                for (name, value) in input.value { context.setObject(value, forKeyedSubscript: name as NSString) }
                context.exception = nil
                var value = context.evaluateScript(script)
                if let exception = context.exception {
                    AppLogger.error("Module script threw", context: ["module": moduleID, "exception": "\(exception)"], level: .warning)
                    context.exception = nil
                    result.deliver(nil)
                    return
                }
                // A script that ends on an assignment (`request.url += …`) has that value, not an
                // object: what it left in the global is what it means.
                if let fallbackGlobal, !(value?.isObject ?? false) {
                    value = context.objectForKeyedSubscript(fallbackGlobal)
                }
                result.deliver(Self.text(of: value, in: context))
            }
        }
        guard let delivered = result.wait(timeout: .now() + Self.timeout) else {
            state.withLock { $0.hasRunAway = true; $0.context = nil }
            AppLogger.error("Module script ran past its time; the module's scripts are off until the app restarts",
                            context: ["module": moduleID, "seconds": Self.timeout], level: .error)
            return nil
        }
        return delivered
    }

    private static func text(of value: JSValue?, in context: JSContext) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isObject {
            let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            return json.flatMap { $0.isString ? $0.toString() : nil }
        }
        return value.toString()
    }

    /// The names of `java`'s own properties and of the globals a script could reach the outside
    /// by, as the context has them: what the allowlist test reads.
    func surface() -> (java: [String], hasNetworkGlobals: Bool) {
        let names = evaluate("Object.keys(java).sort()", bindings: [:])
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let reachable = evaluate(
            "['fetch','XMLHttpRequest','WebSocket','setTimeout','setInterval','require','importScripts','Packages','cookie','source','cache']"
                + ".filter(function(n){return typeof this[n] !== 'undefined'}, this).join(',')", bindings: [:]) ?? "?"
        return (names, !reachable.isEmpty)
    }

    // MARK: - The context

    private static func makeContext(moduleID: String) -> JSContext {
        let context = JSContext()!
        context.name = "module:\(moduleID)"
        let java = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: Any) { java.setObject(block, forKeyedSubscript: name as NSString) }

        set("log", { (message: String) in
            AppLogger.network("module script", context: ["module": moduleID, "message": String(message.prefix(500))])
        } as @convention(block) (String) -> Void)
        set("md5Encode", { hex(Insecure.MD5.hash(data: Data($0.utf8))) } as @convention(block) (String) -> String)
        set("md5Encode16", { text in
            let full = hex(Insecure.MD5.hash(data: Data(text.utf8)))
            return String(full.dropFirst(8).prefix(16))
        } as @convention(block) (String) -> String)
        set("digestHex", { text, algorithm in digest(Data(text.utf8), algorithm).map(hex) } as @convention(block) (String, String) -> String?)
        set("HMacHex", { text, algorithm, key in
            hmac(Data(text.utf8), algorithm, key: Data(key.utf8)).map(hex)
        } as @convention(block) (String, String, String) -> String?)
        set("HMacBase64", { text, algorithm, key in
            hmac(Data(text.utf8), algorithm, key: Data(key.utf8))?.base64EncodedString()
        } as @convention(block) (String, String, String) -> String?)
        set("base64Encode", { Data($0.utf8).base64EncodedString() } as @convention(block) (String) -> String)
        let decode: @convention(block) (String) -> String? = { text in
            LegadoBase64.androidDecode(text).flatMap { String(data: $0, encoding: .utf8) }
        }
        set("base64Decode", decode)
        set("base64DecodeStr", decode)
        set("hexEncodeToString", { hex(Data($0.utf8)) } as @convention(block) (String) -> String)
        set("hexDecodeToString", { bytes(hex: $0).flatMap { String(data: Data($0), encoding: .utf8) } } as @convention(block) (String) -> String?)
        // A cipher by its Java transformation (`AES/CBC/PKCS5Padding`, DES and 3DES too), the key
        // and the IV as text, as a 來源配置's script names them.
        func crypt(_ encrypt: Bool, _ data: [UInt8], _ key: String, _ transformation: String, _ iv: String) -> [UInt8]? {
            do {
                return try LegadoSymmetricCipher.crypt(encrypt: encrypt, transformation: transformation, key: Array(key.utf8),
                                                       iv: Array(iv.utf8), data: data)
            } catch {
                AppLogger.error("Module script cipher failed", error: error, context: ["module": moduleID, "transformation": transformation],
                                level: .warning)
                return nil
            }
        }
        set("aesEncodeToBase64String", { text, key, transformation, iv in
            crypt(true, Array(text.utf8), key, transformation, iv).map { Data($0).base64EncodedString() }
        } as @convention(block) (String, String, String, String) -> String?)
        set("aesBase64DecodeToString", { text, key, transformation, iv in
            LegadoBase64.androidDecode(text).flatMap { crypt(false, Array($0), key, transformation, iv) }
                .flatMap { String(data: Data($0), encoding: .utf8) }
        } as @convention(block) (String, String, String, String) -> String?)
        set("aesEncodeToString", { text, key, transformation, iv in
            crypt(true, Array(text.utf8), key, transformation, iv).map { hex(Data($0)) }
        } as @convention(block) (String, String, String, String) -> String?)
        set("aesDecodeToString", { text, key, transformation, iv in
            bytes(hex: text).flatMap { crypt(false, $0, key, transformation, iv) }.flatMap { String(data: Data($0), encoding: .utf8) }
        } as @convention(block) (String, String, String, String) -> String?)
        set("randomUUID", { UUID().uuidString.lowercased() } as @convention(block) () -> String)
        set("encodeURI", { text in
            text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/"))) ?? text
        } as @convention(block) (String) -> String)

        context.setObject(java, forKeyedSubscript: "java" as NSString)
        // `eval` and `Function` off, `console` and `btoa`/`atob` over `java`.
        JSSandbox.configure(context)
        // The sandbox's handler only prints in a debug build; `evaluate` reads the exception itself.
        context.exceptionHandler = { context, exception in context?.exception = exception }
        return context
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(hex text: String) -> [UInt8]? {
        let digits = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// `MD5`, `SHA-1`, `SHA-256`, `SHA-384`, `SHA-512`, with or without the dash.
    private static func digest(_ data: Data, _ algorithm: String) -> [UInt8]? {
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": Array(Insecure.MD5.hash(data: data))
        case "SHA1": Array(Insecure.SHA1.hash(data: data))
        case "SHA256": Array(SHA256.hash(data: data))
        case "SHA384": Array(SHA384.hash(data: data))
        case "SHA512": Array(SHA512.hash(data: data))
        default: nil
        }
    }

    /// `HmacMD5`, `HmacSHA1`, `HmacSHA256`, `HmacSHA384`, `HmacSHA512`.
    private static func hmac(_ data: Data, _ algorithm: String, key: Data) -> Data? {
        let key = SymmetricKey(data: key)
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "HMAC", with: "") {
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
        case "SHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case "SHA256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case "SHA384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: key))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        default: return nil
        }
    }
}

enum RuleModuleScriptError: Error, Equatable {
    case requestScriptFailed(module: String)
}

extension RuleModule {
    /// The module's script runtime, nil unless it declares `javascript`.
    var scripts: RuleModuleScriptRuntime? { RuleModuleScriptRuntime.runtime(for: self) }

    /// A rule engine for the module's rules: with its scripts when it declares `javascript`.
    func ruleEngine() -> ModernRuleEngine { RuleModuleScriptRuntime.engine(scripts) }
}
