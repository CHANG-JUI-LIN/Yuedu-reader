import Foundation

/// A TTS source's login menu scripts: its `loginUrl` functions, the buttons that call them,
/// and the dynamic `viewName` labels — one engine that keeps `loginUrl` loaded for all of them.
///
/// Every call runs on `SourceScriptThread`, as Legado's `SourceLoginDialog` runs them on its IO
/// dispatcher. A button can open a page with `java.startBrowserAwait` and wait for the reader,
/// and the page is presented on the main thread: a script evaluated from the main thread held
/// the very thread the page needed, so the form froze for the engine's 30 s timeout, the engine
/// was reset under the page, and whatever the reader did there was lost.
final class TTSLoginScript: @unchecked Sendable {
    private let source: ImportedTTSSource
    /// A script stored new login info (`source.putLoginInfo`) — the form shows it at once.
    /// Called on the script's thread.
    private let onLoginInfo: @Sendable ([String: String]) -> Void
    private let lock = NSLock()
    private var engine: JSCoreEngine?

    init(source: ImportedTTSSource, onLoginInfo: @escaping @Sendable ([String: String]) -> Void) {
        self.source = source
        self.onLoginInfo = onLoginInfo
    }

    /// Runs a button's `action`: an `@js:` / `<js>` script, or a plain call into the functions
    /// `loginUrl` declared. `values` is the form as it stands, the script's `result`, as Legado's
    /// `SourceLoginDialog.handleButtonClick` binds `getLoginData(rowUis)`.
    func run(action: String, values: [String: String]) async {
        await SourceScriptThread.run { self.evaluate(action: action, values: values) }
    }

    /// The fields' dynamic `viewName` labels keyed by field name. A field whose expression
    /// yields nothing keeps its name.
    func labels(for fields: [LoginField], values: [String: String]) async -> [String: String] {
        await SourceScriptThread.run { self.resolveLabels(for: fields, values: values) }
    }

    private func evaluate(action: String, values: [String: String]) {
        let script: String
        if action.hasPrefix("@js:") {
            script = String(action.dropFirst(4))
        } else if action.hasPrefix("<js>") {
            script = String(action.dropFirst(4).dropLast(5))
        } else {
            script = action
        }
        let engine = loadedEngine()
        _ = engine.evaluate(
            script, result: JSCoreEngine.JavaMap(values), bindings: ["baseUrl": source.urlTemplate]
        )
        if let error = engine.lastError {
            AppLogger.error("[TTS] 語音源登入按鈕 JS 執行失敗", context: [
                "source": source.name,
                "error": error
            ])
        }
    }

    private func resolveLabels(for fields: [LoginField], values: [String: String]) -> [String: String] {
        let engine = loadedEngine()
        var labels: [String: String] = [:]
        for field in fields where field.hasDynamicViewName {
            guard let expression = field.viewName, !expression.isEmpty else { continue }
            let value = engine.evaluate(
                expression,
                result: JSCoreEngine.JavaMap(values),
                bindings: ["baseUrl": source.urlTemplate]
            )
            if let value, !value.isEmpty, value != "undefined", value != "null" {
                labels[field.name] = value
            } else {
                labels[field.name] = field.name
            }
        }
        return labels
    }

    /// The engine with the source's `loginUrl` evaluated, built on first use. A call that
    /// arrives meanwhile waits for it: every button and label needs those functions.
    private func loadedEngine() -> JSCoreEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine { return engine }
        let made = makeEngine()
        engine = made
        return made
    }

    private func makeEngine() -> JSCoreEngine {
        let e = JSCoreEngine()
        let sourceId = source.id
        let onLoginInfo = onLoginInfo
        e.sourceBridge.getLoginInfoMapHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
        }
        e.sourceBridge.putLoginInfoHandler = { info in
            if let d = info.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: dict)
                onLoginInfo(dict)
            }
        }
        e.sourceBridge.putLoginHeaderHandler = { header in
            if let d = header.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                LoginManager.shared.storeLoginHeaders(sourceUrl: sourceId, headers: dict)
            } else {
                var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
                info["__tts_header"] = header
                LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
            }
        }
        e.sourceBridge.getLoginHeaderHandler = {
            if let info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId),
               let state = info["__tts_header"] { return state }
            return LoginManager.shared.getLoginHeader(sourceUrl: sourceId)
        }
        e.sourceBridge.getVariableHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId)?["__tts_variable"]
        }
        e.sourceBridge.setVariableHandler = { val in
            var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
            info["__tts_variable"] = val ?? ""
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
        }
        e.sourceBridge.getKeyValueHandler = { key in
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId)?[key]
        }
        e.sourceBridge.putKeyValueHandler = { key, value in
            var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
            info[key] = value
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
        }
        e.sourceBridge.getHeaderMapHandler = {
            LoginManager.shared.getLoginHeaders(sourceUrl: sourceId)
        }
        e.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceId)
        }
        e.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceId)
        }
        // Evaluate loginUrl JS first so functions (set, next, Style, etc.) are available to the
        // loginUi button rows — this IS the explicit login action, which is the one place Legado
        // runs `loginUrl`. But only when it is actually a script: 纳米AI TTS declares
        // `loginUrl: "https://bot.n.cn/"`, and a bare URL fed to JavaScriptCore parses as the
        // label `https:` followed by the comment `//bot.n.cn/` and then EOF —
        // `SyntaxError: Unexpected end of script`, once per open, silently discarded.
        if let loginJs = source.loginUrl.flatMap(LoginManager.shared.extractLoginJs),
           !loginJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = e.evaluate(loginJs, result: nil, bindings: [:])
            if let error = e.lastError {
                AppLogger.error("[TTS] 語音源 loginUrl JS 執行失敗", context: [
                    "source": source.name,
                    "error": error
                ])
            }
        }
        return e
    }
}
