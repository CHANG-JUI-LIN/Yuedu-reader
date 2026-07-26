import Foundation
import JavaScriptCore

// MARK: - JSExport Protocol

/// JS-callable interface for Legado's `source.*` bridge object.
/// Mirrors Legado's `BaseSource` API: variable storage, login info/headers, metadata.
///
/// On Android, `source` IS the `BookSource` object — Rhino's Java interop lets source JS read
/// *any* field of its own source, including the nested rule groups (`source.ruleContent.content`).
/// Sources rely on that: 番茄酱's remote `to.js` refuses to run unless
/// `java.md5Encode(source.bookSourceComment + source.concurrentRate + source.ruleContent.content)`
/// matches a baked-in digest (an anti-tamper gate). Exposing only a handful of fields made
/// `source.ruleContent` undefined, so the gate threw and every chapter came back as
/// "请求失败: …". Keep this list mirroring `BookSource`.
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
    func login() -> String
    func put(_ key: String, _ value: String)
    func get(_ key: String) -> String
    func evalJS(_ js: String) -> String
    func getKey() -> String

    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var key: String { get }
    var bookSourceGroup: String { get }
    var bookSourceComment: String { get }
    var bookSourceType: Int { get }
    var bookUrlPattern: String { get }
    var customOrder: Int { get }
    var enabled: Bool { get }
    var enabledExplore: Bool { get }
    var enabledCookieJar: Bool { get }
    var enabledReview: Bool { get }
    var searchUrl: String { get }
    var exploreUrl: String { get }
    var exploreScreen: String { get }
    var concurrentRate: String { get }
    var loginUrl: String { get }
    var loginUi: String { get }
    var loginCheckJs: String { get }
    var header: String { get }
    var respondTime: Int64 { get }
    var lastUpdateTime: Int64 { get }
    var weight: Int { get }
    var variableComment: String { get }
    var coverDecodeJs: String { get }
    var jsLib: String { get }
    var ruleSearch: NSDictionary { get }
    var ruleExplore: NSDictionary { get }
    var ruleBookInfo: NSDictionary { get }
    var ruleToc: NSDictionary { get }
    var ruleContent: NSDictionary { get }
    var ruleReview: NSDictionary { get }
}

// MARK: - Bridge Implementation

@objc class LegadoSourceBridge: NSObject, LegadoSourceBridgeExport {

    // MARK: Static book source metadata (populated from BookSource)

    @objc let bookSourceUrl: String
    @objc let bookSourceName: String
    @objc let bookSourceGroup: String
    @objc let bookSourceComment: String
    @objc let bookSourceType: Int
    @objc let bookUrlPattern: String
    @objc let customOrder: Int
    @objc let enabled: Bool
    @objc let enabledExplore: Bool
    @objc let enabledCookieJar: Bool
    @objc let enabledReview: Bool
    @objc let searchUrl: String
    @objc let exploreUrl: String
    @objc let exploreScreen: String
    @objc let concurrentRate: String
    @objc let loginUrl: String
    @objc let loginUi: String
    @objc let loginCheckJs: String
    @objc let header: String
    @objc let respondTime: Int64
    @objc let lastUpdateTime: Int64
    @objc let weight: Int
    @objc let variableComment: String
    @objc let coverDecodeJs: String
    @objc let jsLib: String
    @objc let ruleSearch: NSDictionary
    @objc let ruleExplore: NSDictionary
    @objc let ruleBookInfo: NSDictionary
    @objc let ruleToc: NSDictionary
    @objc let ruleContent: NSDictionary
    @objc let ruleReview: NSDictionary

    @objc var key: String { bookSourceUrl }

    /// Legado `BaseSource.getKey()` — the source's identity, `bookSourceUrl` for a
    /// book source. Exporting only the `key` *property* was not enough: Rhino sees
    /// the Kotlin method, so sources call `source.getKey()`, and on JavaScriptCore
    /// that was `undefined` → `TypeError: source.getKey is not a function`. 洋柿子
    /// resolves its API host with it (`getHostList` → `src.getKey()`), inside a
    /// `try {} catch {}` that discards the error, so the host list came out empty
    /// and the 發現頁 fell through to 「洋柿子发现页加载失败」 with no clue why.
    @objc func getKey() -> String { key }

    // MARK: Degates / Handlers (wired externally)

    /// Returns the full variable JSON string (Legado convention).
    var getVariableHandler: (() -> String?)?

    /// Stores the full variable JSON string.
    var setVariableHandler: ((String?) -> Void)?

    /// Reads one entry from Legado's source-scoped key-value store.
    var getKeyValueHandler: ((String) -> String?)?

    /// Stores one entry in Legado's source-scoped key-value store.
    var putKeyValueHandler: ((String, String) -> Void)?

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

    init(source: BookSource) {
        bookSourceUrl = source.bookSourceUrl
        bookSourceName = source.bookSourceName
        bookSourceGroup = source.bookSourceGroup
        bookSourceComment = source.bookSourceComment
        bookSourceType = source.bookSourceType
        bookUrlPattern = source.bookUrlPattern
        customOrder = source.customOrder
        enabled = source.enabled
        enabledExplore = source.enabledExplore
        enabledCookieJar = source.enabledCookieJar
        enabledReview = source.enabledReview
        searchUrl = source.searchUrl
        exploreUrl = source.exploreUrl
        exploreScreen = source.exploreScreen
        concurrentRate = source.concurrentRate
        loginUrl = source.loginUrl
        loginUi = source.loginUi
        loginCheckJs = source.loginCheckJs
        header = source.header
        respondTime = source.respondTime
        lastUpdateTime = source.lastUpdateTime
        weight = source.weight
        variableComment = source.variableComment
        coverDecodeJs = source.coverDecodeJs
        jsLib = source.jsLib
        // Keys are Legado's JSON field names, not our Swift property names — source JS
        // addresses them exactly as they appear in the book-source JSON
        // (`ruleBookInfo.init`, not `.initScript`).
        ruleSearch = [
            "checkKeyWord": source.ruleSearch.checkKeyWord,
            "bookList": source.ruleSearch.bookList,
            "name": source.ruleSearch.name,
            "author": source.ruleSearch.author,
            "coverUrl": source.ruleSearch.coverUrl,
            "intro": source.ruleSearch.intro,
            "bookUrl": source.ruleSearch.bookUrl,
            "wordCount": source.ruleSearch.wordCount,
            "lastChapter": source.ruleSearch.lastChapter,
            "updateTime": source.ruleSearch.updateTime,
            "kind": source.ruleSearch.kind,
            "hasMoreRule": source.ruleSearch.hasMoreRule
        ] as NSDictionary
        ruleExplore = [
            "bookList": source.ruleExplore.bookList,
            "name": source.ruleExplore.name,
            "author": source.ruleExplore.author,
            "intro": source.ruleExplore.intro,
            "kind": source.ruleExplore.kind,
            "lastChapter": source.ruleExplore.lastChapter,
            "updateTime": source.ruleExplore.updateTime,
            "bookUrl": source.ruleExplore.bookUrl,
            "coverUrl": source.ruleExplore.coverUrl,
            "wordCount": source.ruleExplore.wordCount,
            "hasMoreRule": source.ruleExplore.hasMoreRule
        ] as NSDictionary
        ruleBookInfo = [
            "init": source.ruleBookInfo.initScript,
            "name": source.ruleBookInfo.name,
            "author": source.ruleBookInfo.author,
            "coverUrl": source.ruleBookInfo.coverUrl,
            "intro": source.ruleBookInfo.intro,
            "kind": source.ruleBookInfo.kind,
            "wordCount": source.ruleBookInfo.wordCount,
            "lastChapter": source.ruleBookInfo.lastChapter,
            "updateTime": source.ruleBookInfo.updateTime,
            "tocUrl": source.ruleBookInfo.tocUrl,
            "canReName": source.ruleBookInfo.canReName,
            "downloadUrls": source.ruleBookInfo.downloadUrls,
            "ttsDice": source.ruleBookInfo.ttsDice
        ] as NSDictionary
        ruleToc = [
            "preUpdateJs": source.ruleToc.preUpdateJs,
            "chapterList": source.ruleToc.chapterList,
            "chapterName": source.ruleToc.chapterName,
            "chapterUrl": source.ruleToc.chapterUrl,
            "formatJs": source.ruleToc.formatJs,
            "isVolume": source.ruleToc.isVolume,
            "isVip": source.ruleToc.isVip,
            "isPay": source.ruleToc.isPay,
            "updateTime": source.ruleToc.updateTime,
            "nextTocUrl": source.ruleToc.nextTocUrl
        ] as NSDictionary
        ruleContent = [
            "content": source.ruleContent.content,
            "title": source.ruleContent.title,
            "nextContentUrl": source.ruleContent.nextContentUrl,
            "webJs": source.ruleContent.webJs,
            "sourceRegex": source.ruleContent.sourceRegex,
            "replaceRegex": source.ruleContent.replaceRegex,
            "imageStyle": source.ruleContent.imageStyle,
            "imageDecode": source.ruleContent.imageDecode,
            "payAction": source.ruleContent.payAction
        ] as NSDictionary
        ruleReview = ["review": source.ruleReview.review] as NSDictionary
        super.init()
    }

    convenience init(bookSourceUrl: String,
                     bookSourceName: String,
                     bookSourceGroup: String,
                     bookSourceComment: String,
                     loginUrl: String,
                     header: String,
                     loginCheckJs: String) {
        var source = BookSource()
        source.bookSourceUrl = bookSourceUrl
        source.bookSourceName = bookSourceName
        source.bookSourceGroup = bookSourceGroup
        source.bookSourceComment = bookSourceComment
        source.loginUrl = loginUrl
        source.header = header
        source.loginCheckJs = loginCheckJs
        self.init(source: source)
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

    func login() -> String {
        return loginHandler?() ?? ""
    }

    // MARK: Key-Value Store

    func put(_ key: String, _ value: String) {
        let currentJson = getVariableHandler?() ?? ""
        let normalized = Self.normalizeStored(value)

        // Older Yuedu sources used getVariable() as a JSON object and expected
        // source.put/get to address that object. Preserve that compatibility only when
        // the variable really is a JSON object. Legado also allows getVariable() to be
        // an opaque token; in that case source.put must use a separate key-value store.
        if let data = currentJson.data(using: .utf8),
           var mutableDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            mutableDict[key] = normalized
            if let newData = try? JSONSerialization.data(withJSONObject: mutableDict),
               let newJson = String(data: newData, encoding: .utf8) {
                setVariableHandler?(newJson)
            }
        } else {
            putKeyValueHandler?(key, normalized)
        }

        variableStore[key] = normalized
    }

    func get(_ key: String) -> String {
        let currentJson = getVariableHandler?() ?? ""
        if let data = currentJson.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = dict[key] {
            return Self.normalizeStored(Self.stringify(value))
        }
        if let value = getKeyValueHandler?(key) {
            return Self.normalizeStored(value)
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
        if let arr = value as? [Any] {
            return arr.map { stringify($0) }.joined(separator: "\n")
        }
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
        return LegadoSourceBridge(source: source)
    }
}
