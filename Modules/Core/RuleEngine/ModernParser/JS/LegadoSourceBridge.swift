import Foundation
import JavaScriptCore

// MARK: - JSExport Protocol

/// JS-callable interface for Legado's `source.*` bridge object.
/// Mirrors Legado's `BaseSource` API: variable storage, login info/headers, metadata.
@objc protocol LegadoSourceBridgeExport: JSExport {
    func getVariable() -> String
    func setVariable(_ variable: String?)
    func getLoginInfo() -> String?
    func putLoginInfo(_ info: String)
    func getLoginInfoMap() -> JSValue
    func removeLoginInfo()
    func putLoginHeader(_ header: String)
    func getLoginHeader() -> String?
    func removeLoginHeader()
    func getHeaderMap() -> JSValue
    func loginUi() -> String
    func login() -> String
    func put(_ key: String, _ value: String)
    func get(_ key: String) -> String
    func evalJS(_ js: String) -> String

    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var key: String { get }
    var bookSourceGroup: String { get }
    var bookSourceComment: String { get }
    var loginUrl: String { get }
    var header: String { get }
    var loginCheckJs: String { get }
}

// MARK: - Bridge Implementation

@objc class LegadoSourceBridge: NSObject, LegadoSourceBridgeExport {

    // MARK: Static book source metadata (populated from BookSource)

    @objc let bookSourceUrl: String
    @objc let bookSourceName: String
    @objc let bookSourceGroup: String
    @objc let bookSourceComment: String
    @objc let loginUrl: String
    @objc let header: String
    @objc let loginCheckJs: String

    @objc var key: String { bookSourceUrl }

    // MARK: Degates / Handlers (wired externally)

    /// Returns the full variable JSON string (Legado convention).
    var getVariableHandler: (() -> String?)?

    /// Stores the full variable JSON string.
    var setVariableHandler: ((String?) -> Void)?

    /// Returns login info as a JSON string (or nil).
    var getLoginInfoHandler: (() -> String?)?

    /// Stores login info JSON string.
    var putLoginInfoHandler: ((String) -> Void)?

    /// Returns login info as a parsed map (for `getLoginInfoMap()`).
    var getLoginInfoMapHandler: (() -> [String: Any])?

    /// Clears login info.
    var removeLoginInfoHandler: (() -> Void)?

    /// Stores login header JSON string.
    var putLoginHeaderHandler: ((String) -> Void)?

    /// Returns the stored login header JSON string (or nil).
    var getLoginHeaderHandler: (() -> String?)?

    /// Clears login headers.
    var removeLoginHeaderHandler: (() -> Void)?

    /// Returns merged source+login header map.
    var getHeaderMapHandler: (() -> [String: String])?

    /// Executes the login flow and returns result string.
    var loginHandler: (() -> String)?

    /// JS evaluator for `source.evalJS(js)`.
    var evalJSHandler: ((String) -> String)?

    // MARK: Simple key-value store (in-memory, mirrors Legado's variableStore)

    private var variableStore: [String: String] = [:]

    // MARK: Init

    init(bookSourceUrl: String,
         bookSourceName: String,
         bookSourceGroup: String,
         bookSourceComment: String,
         loginUrl: String,
         header: String,
         loginCheckJs: String) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceGroup = bookSourceGroup
        self.bookSourceComment = bookSourceComment
        self.loginUrl = loginUrl
        self.header = header
        self.loginCheckJs = loginCheckJs
        super.init()
    }

    // MARK: Source Variables

    func getVariable() -> String {
        return getVariableHandler?() ?? ""
    }

    func setVariable(_ variable: String?) {
        setVariableHandler?(variable)
    }

    // MARK: Login Info

    func getLoginInfo() -> String? {
        return getLoginInfoHandler?()
    }

    func putLoginInfo(_ info: String) {
        putLoginInfoHandler?(info)
    }

    func getLoginInfoMap() -> JSValue {
        return Self.javaMapValue(getLoginInfoMapHandler?() ?? [:])
    }

    func removeLoginInfo() {
        removeLoginInfoHandler?()
    }

    // MARK: Login Header

    func putLoginHeader(_ header: String) {
        putLoginHeaderHandler?(header)
    }

    func getLoginHeader() -> String? {
        return getLoginHeaderHandler?()
    }

    func removeLoginHeader() {
        removeLoginHeaderHandler?()
    }

    func getHeaderMap() -> JSValue {
        return Self.javaMapValue((getHeaderMapHandler?() ?? [:]) as [String: Any])
    }

    // MARK: Login UI / Execution

    func loginUi() -> String {
        return "" // loginUi is a static property; JS accesses it as source.loginUi
    }

    func login() -> String {
        return loginHandler?() ?? ""
    }

    // MARK: Key-Value Store

    func put(_ key: String, _ value: String) {
        // Start from the existing variable JSON, but tolerate an empty/missing/invalid value —
        // the getVariable handler returns "" (not nil) when nothing is stored yet, which would
        // otherwise make the JSON parse fail and silently DROP the write (breaking first-time
        // `source.put`, e.g. 起点's menuTag / token / para).
        let currentJson = getVariableHandler?() ?? ""
        var mutableDict: [String: Any] = [:]
        if let data = currentJson.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            mutableDict = dict
        }
        // JSCore stringifies JS `undefined`/`null` arguments to the literal strings
        // "undefined"/"null" for a `String`-typed JSExport param (Rhino would store null /
        // remove the key). Storing them poisons truthy checks: e.g. 起点 does
        // `source.put("token", undefined)`, then `source.get("token")` returns the truthy
        // "undefined", so `if (!token)` never re-fetches a real token and every content
        // request comes back empty. Normalize to "" (Legado's effective behaviour).
        let normalized = Self.normalizeStored(value)
        mutableDict[key] = normalized
        variableStore[key] = normalized
        if let newData = try? JSONSerialization.data(withJSONObject: mutableDict),
           let newJson = String(data: newData, encoding: .utf8) {
            setVariableHandler?(newJson)
        }
    }

    func get(_ key: String) -> String {
        let currentJson = getVariableHandler?() ?? "{}"
        if let data = currentJson.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = dict[key] {
            // Self-heal any already-poisoned "undefined"/"null" stored before the put fix.
            return Self.normalizeStored(Self.stringify(value))
        }
        return Self.normalizeStored(variableStore[key] ?? "")
    }

    /// Treat the JS-stringified `undefined`/`null` placeholders as empty so source truthy
    /// checks (`if (!token)`) behave the way they do on Rhino.
    private static func normalizeStored(_ value: String) -> String {
        (value == "undefined" || value == "null") ? "" : value
    }

    // MARK: JS Evaluation

    func evalJS(_ js: String) -> String {
        return evalJSHandler?(js) ?? ""
    }

    /// Wrap a Swift dictionary in a JS object that behaves like a `java.util.Map`
    /// (supports `.get`/`.put`/`.containsKey`/… that Legado source jsLib calls) while
    /// keeping plain `obj[key]` access. On Rhino these bridge methods return real
    /// `java.util.Map` instances; JavaScriptCore would otherwise hand JS a plain object
    /// with no such methods, so `.get(key)` would throw and abort the rule.
    /// See `__yueduJavaMap` injected by `JSCoreEngine.configureContext`.
    private static func javaMapValue(_ dict: [String: Any]) -> JSValue {
        let ctx = JSContext.current() ?? JSContext()!
        let object = JSValue(object: dict, in: ctx) ?? JSValue(newObjectIn: ctx)
        guard let object else { return JSValue(undefinedIn: ctx) }
        guard let wrapper = ctx.objectForKeyedSubscript("__yueduJavaMap"),
              !wrapper.isUndefined, !wrapper.isNull,
              let wrapped = wrapper.call(withArguments: [object]) else {
            return object
        }
        return wrapped
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if value is NSNull { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(value)"
    }
}

// MARK: - Factory

extension LegadoSourceBridge {
    /// Create a bridge populated from a BookSource.
    static func from(_ source: BookSource) -> LegadoSourceBridge {
        return LegadoSourceBridge(
            bookSourceUrl: source.bookSourceUrl,
            bookSourceName: source.bookSourceName,
            bookSourceGroup: source.bookSourceGroup,
            bookSourceComment: source.bookSourceComment,
            loginUrl: source.loginUrl,
            header: source.header,
            loginCheckJs: source.loginCheckJs
        )
    }
}
