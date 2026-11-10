import Foundation
import JavaScriptCore

/// `java` inside an AnalyzeUrl's own scripts: its `@js:` / `<js>` / `{{…}}` URL scripts, its
/// `js` option, and the source's `loginCheckJs` on its response.
///
/// Legado evaluates those with `AnalyzeUrl.evalJS`, which binds `java = this` — an AnalyzeUrl,
/// which is also every `JsExtensions` method. Sources read and change the request through it:
///
/// - 刚够小说网 (1330 #314, 1331 #141, 1329 #133) reads its 访问验证 cookie with
///   `java.ajax(java.url)` in the `js` option, sets it with `java.headerMap.put('Cookie', …)`
///   and returns `java.url`.
/// - 一笔阁 and 顶点小说 (1330 #129, #455) answer the same check in `loginCheckJs` with
///   `java.connect(source.key + java.ruleUrl)`; 新版笔趣阁 (1330 #682, 1329 #270), 禁漫天堂,
///   哔哩漫画 and 漫画屋 read `java.ruleUrl` there too.
/// - 爱尚小说网 (1330 #382, 1329 #159) and 起点中文 (1331 #370) redo the request after
///   refreshing a cookie: `java.initUrl(); result = java.getStrResponse()`. Linpx, 兽人小说站 and
///   蓝批 end their check with `java.getStrResponse(null, null)`.
///
/// Before 11-07 `java` was the bare bridge in all of these: `java.ruleUrl` was `undefined` (一笔阁
/// requested `m.yibige.orgundefined`) and `java.headerMap.put` threw.
///
/// The engine binds this view on top of the bridge for one evaluation (`__yueduAnalyzeUrlJava`):
/// a member this view has comes from it, everything else from the bridge.
@objc protocol LegadoAnalyzeUrlScriptExport: JSExport {
    /// The absolute URL, before the query is split off (Legado `AnalyzeUrl.url`).
    var url: String { get }
    /// The rule URL after its scripts and templates, options included (`AnalyzeUrl.ruleUrl`).
    var ruleUrl: String { get }
    var urlNoQuery: String { get }
    var type: String? { get }
    var baseUrl: String { get }
    /// The request's headers, live: a put here is in the request this AnalyzeUrl sends.
    var headerMap: LegadoHeaderMap { get }
    /// The request as it now stands, sent again (`AnalyzeUrl.getStrResponse`). The arguments
    /// are Legado's WebView `jsStr` / `sourceRegex`; the request here goes over HTTP.
    func getStrResponse(_ jsStr: JSValue, _ sourceRegex: JSValue) -> LegadoStrResponse?
    /// `java.initUrl()`: the rule URL read again from the start (`AnalyzeUrl.initUrl`), its
    /// scripts and templates run again, so a cookie a check just refreshed is in the request it
    /// builds. Exported under another name: JavaScriptCore takes a selector that starts with
    /// `init` for an initializer and leaves it off the prototype (`java.initUrl` was
    /// `undefined`), so `__yueduAnalyzeUrlJava` answers `initUrl` with this.
    func reinitUrl()
}

final class LegadoAnalyzeUrlScriptView: NSObject, LegadoAnalyzeUrlScriptExport {
    struct State {
        var url: String
        var ruleUrl: String
        var urlNoQuery: String
        var type: String?
        var baseUrl: String
    }

    private let state: () -> State
    private let reinitialize: (() -> Void)?
    let headerMap: LegadoHeaderMap
    /// Sends the request as it now stands. Installed by whoever sends this AnalyzeUrl's request
    /// (`ModernParserBridge`), which owns the transport and the source's authentication; nil
    /// answers `getStrResponse()` with `null`.
    var execute: (() -> LegadoStrResponse?)?

    init(
        state: @escaping () -> State,
        headers: LegadoHeaderMap,
        reinitialize: (() -> Void)?
    ) {
        self.state = state
        self.headerMap = headers
        self.reinitialize = reinitialize
    }

    /// A view of a request that was not built by an AnalyzeUrl — a stage's first request on the
    /// native path (`BookSourceFetcher.fetchStagePage`) — for its `loginCheckJs`. Its headers
    /// start as the request's; `makeRequest` rebuilds the request with them as they then are.
    /// `initUrl()` has nothing to read again: the native path renders the rule URL before the
    /// request exists, and that rendering is what `ruleUrl` holds.
    static func snapshot(
        of request: URLRequest, ruleUrl: String, baseUrl: String
    ) -> (view: LegadoAnalyzeUrlScriptView, makeRequest: () -> URLRequest) {
        let headers = LegadoHeaderMap(request.allHTTPHeaderFields ?? [:])
        let url = request.url?.absoluteString ?? ""
        // An AnalyzeUrl's base once its URL is read (`AnalyzeUrl.analyzeUrl`).
        let base = AnalyzeUrl.legadoBaseUrl(of: url) ?? baseUrl
        let view = LegadoAnalyzeUrlScriptView(
            state: {
                State(
                    url: url,
                    ruleUrl: ruleUrl,
                    urlNoQuery: url.components(separatedBy: "?").first ?? url,
                    type: nil,
                    baseUrl: base
                )
            },
            headers: headers,
            reinitialize: nil
        )
        let makeRequest = { [headers] () -> URLRequest in
            var rebuilt = request
            rebuilt.allHTTPHeaderFields = headers.values
            return rebuilt
        }
        return (view, makeRequest)
    }

    var url: String { state().url }
    var ruleUrl: String { state().ruleUrl }
    var urlNoQuery: String { state().urlNoQuery }
    var type: String? { state().type }
    var baseUrl: String { state().baseUrl }

    func getStrResponse(_ jsStr: JSValue, _ sourceRegex: JSValue) -> LegadoStrResponse? {
        execute?()
    }

    func reinitUrl() {
        reinitialize?()
    }
}

@objc protocol LegadoHeaderMapExport: JSExport {
    /// Java `Map.put`: the value it replaced, `null` when there was none. A `null` value takes
    /// the header out (a request cannot carry a null header). `get` and `remove` are `null`
    /// for a missing key, as Java's (`LegadoJavaNull`); Swift callers use the `String?` twins.
    @objc(put::) func jsPut(_ key: String, _ value: JSValue) -> JSValue
    @objc(get:) func jsGet(_ key: String) -> JSValue
    @objc(remove:) func jsRemove(_ key: String) -> JSValue
    func containsKey(_ key: String) -> Bool
    func size() -> Int
    func isEmpty() -> Bool
    func keySet() -> [String]
    func putAll(_ map: JSValue)
    func clear()
    func toString() -> String
}

/// Legado `AnalyzeUrl.headerMap` (a `HashMap<String, String>`) as a script reaches it. Reads and
/// writes go to the request's own headers, so what a script puts is what is sent.
final class LegadoHeaderMap: NSObject, LegadoHeaderMapExport {
    private let read: () -> [String: String]
    private let write: ([String: String]) -> Void

    init(read: @escaping () -> [String: String], write: @escaping ([String: String]) -> Void) {
        self.read = read
        self.write = write
    }

    /// A map that holds its own headers, starting as `initial`.
    convenience init(_ initial: [String: String]) {
        let box = Box(initial)
        self.init(read: { box.headers }, write: { box.headers = $0 })
    }

    private final class Box {
        var headers: [String: String]
        init(_ headers: [String: String]) { self.headers = headers }
    }

    var values: [String: String] { read() }

    func put(_ key: String, _ value: JSValue) -> String? {
        var headers = read()
        let previous = headers[key]
        if value.isNull || value.isUndefined {
            headers.removeValue(forKey: key)
        } else {
            headers[key] = value.toString()
        }
        write(headers)
        return previous
    }

    func get(_ key: String) -> String? { read()[key] }

    @objc(put::) func jsPut(_ key: String, _ value: JSValue) -> JSValue {
        LegadoJavaNull.value(put(key, value))
    }
    @objc(get:) func jsGet(_ key: String) -> JSValue { LegadoJavaNull.value(get(key)) }
    @objc(remove:) func jsRemove(_ key: String) -> JSValue { LegadoJavaNull.value(remove(key)) }

    func remove(_ key: String) -> String? {
        var headers = read()
        let previous = headers.removeValue(forKey: key)
        write(headers)
        return previous
    }

    func containsKey(_ key: String) -> Bool { read()[key] != nil }
    func size() -> Int { read().count }
    func isEmpty() -> Bool { read().isEmpty }
    func keySet() -> [String] { Array(read().keys) }

    func putAll(_ map: JSValue) {
        guard map.isObject, let entries = map.toDictionary() else { return }
        var headers = read()
        for (key, value) in entries {
            guard let key = key as? String else { continue }
            if value is NSNull {
                headers.removeValue(forKey: key)
            } else {
                headers[key] = "\(value)"
            }
        }
        write(headers)
    }

    func clear() { write([:]) }

    /// Java's `AbstractMap.toString`: `{Key=Value, …}`.
    func toString() -> String {
        "{" + read().map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
    }
}
