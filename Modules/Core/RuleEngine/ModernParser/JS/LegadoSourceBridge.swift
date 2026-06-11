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
    func getLoginInfoMap() -> [String: Any]
    func removeLoginInfo()
    func putLoginHeader(_ header: String)
    func removeLoginHeader()
    func getHeaderMap() -> [String: String]
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

    func getLoginInfoMap() -> [String: Any] {
        return getLoginInfoMapHandler?() ?? [:]
    }

    func removeLoginInfo() {
        removeLoginInfoHandler?()
    }

    // MARK: Login Header

    func putLoginHeader(_ header: String) {
        putLoginHeaderHandler?(header)
    }

    func removeLoginHeader() {
        removeLoginHeaderHandler?()
    }

    func getHeaderMap() -> [String: String] {
        return getHeaderMapHandler?() ?? [:]
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
        let currentJson = getVariableHandler?() ?? "{}"
        if let data = currentJson.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var mutableDict = dict
            mutableDict[key] = value
            if let newData = try? JSONSerialization.data(withJSONObject: mutableDict),
               let newJson = String(data: newData, encoding: .utf8) {
                setVariableHandler?(newJson)
            }
        }
    }

    func get(_ key: String) -> String {
        let currentJson = getVariableHandler?() ?? "{}"
        if let data = currentJson.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = dict[key] {
            return Self.stringify(value)
        }
        return variableStore[key] ?? ""
    }

    // MARK: JS Evaluation

    func evalJS(_ js: String) -> String {
        return evalJSHandler?(js) ?? ""
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
