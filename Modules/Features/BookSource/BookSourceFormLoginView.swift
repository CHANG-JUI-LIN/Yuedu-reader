import SwiftUI
import UIKit

// MARK: - BookSourceFormLoginView
// Handles book sources whose `loginUi` JSON defines form fields (text/password/button).
// After the user fills in credentials and taps "Confirm", the loginUrl JS is executed
// with those credentials stored via LoginManager — mirroring Legado's SourceLoginDialog.

struct BookSourceFormLoginView: View {
    let source: BookSource
    let onDismiss: () -> Void

    @MainActor private static weak var currentToastAlert: UIAlertController?

    private let gs = GlobalSettings.shared
    @State private var fields: [LoginUIField] = []
    @State private var values: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var showFanqieLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("請填入登入資訊"))) {
                    ForEach(fields) { field in
                        switch field.type {
                        case .text:
                            HStack {
                                Text(field.name).foregroundColor(DSColor.textSecondary)
                                Spacer()
                                TextField(field.name, text: binding(for: field.name))
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        case .password:
                            HStack {
                                Text(field.name).foregroundColor(DSColor.textSecondary)
                                Spacer()
                                SecureField(field.name, text: binding(for: field.name))
                                    .multilineTextAlignment(.trailing)
                            }
                        case .button:
                            Button(field.name) {
                                handleButton(field: field)
                            }
                            .foregroundColor(DSColor.accent)
                        }
                    }
                }

                if Self.supportsFanqieLogin(source: source) {
                    Section {
                        Button {
                            showFanqieLogin = true
                        } label: {
                            Label(localized("番茄登入"), systemImage: "network")
                        }
                        .foregroundColor(DSColor.accent)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                if let suc = successMessage {
                    Section {
                        Label(suc, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }
            .disabled(isLoading)
            .navigationTitle(source.bookSourceName.isEmpty ? localized("書源登入") : source.bookSourceName)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                if !fields.contains(where: { $0.type == .button }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Button {
                                doLogin()
                            } label: {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .onAppear { loadUI() }
        .sheet(isPresented: $showFanqieLogin) {
            JsBridgeBrowserView(urlString: "https://fanqienovel.com", title: localized("番茄登入")) { _ in
                showFanqieLogin = false
            }
        }
    }

    // MARK: - Setup

    private func loadUI() {
        let rawUi = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some sources (e.g. 起点) define `loginUi` as JS (`@js:` / `<js>…</js>`) that
        // builds the form by calling a jsLib helper like `Menu()`. Evaluate it first,
        // then parse the JSON it returns. Plain JSON-array loginUi takes the fast path.
        if rawUi.hasPrefix("@js:") || rawUi.hasPrefix("<js>") {
            isLoading = true
            let src = source
            Task.detached(priority: .userInitiated) {
                let json = Self.evaluateJsLoginUi(source: src)
                let parsed = LoginUIField.parse(from: json)
                let stored = LoginManager.shared.getLoginInfo(sourceUrl: src.bookSourceUrl)
                await MainActor.run {
                    self.fields = parsed
                    if let stored { self.values = stored }
                    self.isLoading = false
                }
            }
            return
        }

        fields = LoginUIField.parse(from: source.loginUi)
        // Pre-fill with stored credentials
        if let stored = LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) {
            values = stored
        }
    }

    /// Evaluate a JS-based `loginUi` (with jsLib + source runtime wired) and return
    /// the JSON form definition it produces (via `result = JSON.stringify(...)`).
    nonisolated private static func evaluateJsLoginUi(source: BookSource) -> String {
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureLegadoRuntime(engine, source: source)
        engine.toastHandler = { msg in
            Task { @MainActor in BookSourceFormLoginView.presentToastAlert(message: msg) }
        }

        let raw = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsBody = LoginManager.shared.extractLoginJs(raw) ?? raw
        // Run the body (which assigns `result`), then return `result`.
        let wrapped = """
        \(jsBody)
        ;(typeof result !== 'undefined' && result !== null ? result : '')
        """
        return engine.evaluate(wrapped, bindings: ["baseUrl": source.bookSourceUrl]) ?? ""
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }

    static func supportsFanqieLogin(source: BookSource) -> Bool {
        [
            source.loginUi,
            source.loginUrl,
            source.jsLib,
            source.ruleToc.chapterUrl,
            source.ruleContent.content,
        ].contains { $0.contains("fanqienovel.com") || $0.contains("getFqToken") }
    }

    // MARK: - Login Action

    private func doLogin() {
        guard !isLoading else { return }
        errorMessage = nil
        successMessage = nil

        // Validate: collect non-button field values
        let credentials = fields
            .filter { $0.type != .button }
            .reduce(into: [String: String]()) { dict, field in
                dict[field.name] = values[field.name] ?? ""
            }

        if credentials.isEmpty {
            // No credentials needed — just execute loginUrl JS directly
            runLoginJS(credentials: [:])
            return
        }

        // Store credentials then run login JS
        LoginManager.shared.storeLoginInfo(
            sourceUrl: source.bookSourceUrl, info: credentials
        )
        runLoginJS(credentials: credentials)
    }

    private func handleButton(field: LoginUIField) {
        guard let action = field.action, !action.isEmpty else { return }
        // If it's a URL, open in browser; if JS, run it
        if action.hasPrefix("http://") || action.hasPrefix("https://") {
            if let url = URL(string: action) {
                UIApplication.shared.open(url)
            }
        } else {
            // JS button action
            let currentCredentials = fields
                .filter { $0.type != .button }
                .reduce(into: [String: String]()) { dict, f in
                    dict[f.name] = values[f.name] ?? ""
                }
            runButtonJS(action: action, credentials: currentCredentials)
        }
    }

    // MARK: - JS Execution

    private func runLoginJS(credentials: [String: String]) {
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLogin.isEmpty else {
            errorMessage = localized("書源未設定 loginUrl")
            return
        }

        isLoading = true
        Task.detached(priority: .userInitiated) {
            let engine = JSCoreEngine()
            engine.bookSource = source
            Self.configureLegadoRuntime(engine, source: source)

            // Wire browser pop-up for java.startBrowser / java.startBrowserAwait
            engine.browserPresentHandler = { url, title, completion in
                DispatchQueue.main.async {
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        completion(nil); return
                    }
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) { body in
                            topVC.dismiss(animated: true) {
                                completion(body)
                            }
                        }
                    )
                    topVC.present(hostVC, animated: true)
                }
            }

            // Wire java.toast / java.longToast — shows a UIAlertController auto-dismiss
            engine.toastHandler = { msg in
                Task { @MainActor in
                    BookSourceFormLoginView.presentToastAlert(message: msg)
                }
            }

            // Wire CF challenge: present CloudflareChallengeView and call done() when cookies are ready
            engine.cloudflareChallengeHandler = { url, done in
                Task { @MainActor in
                    _ = try? await CloudflareChallengePresenter.present(url: url)
                    done()
                }
            }
            let bindings: [String: Any] = [
                "result": credentials,
                "baseUrl": source.bookSourceUrl
            ]

            // Extract JS body from loginUrl (strip @js: / <js>…</js>)
            let js = LoginManager.shared.extractLoginJs(rawLogin) ?? rawLogin
            let wrappedJS = """
            \(js)
            if (typeof login === 'function') {
                login.apply(this);
            }
            """

            let result = engine.evaluate(wrappedJS, bindings: bindings)

            // If JS returned a header JSON, persist it
            if let resultStr = result,
               !resultStr.isEmpty,
               let data = resultStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                LoginManager.shared.storeLoginHeaders(
                    sourceUrl: source.bookSourceUrl, headers: dict
                )
            } else {
                // Try reading putLoginHeader result from LoginManager (JS may have called java.put)
                let _ = LoginManager.shared.getLoginHeader(sourceUrl: source.bookSourceUrl)
            }

            await MainActor.run {
                isLoading = false
                if let err = engine.lastError, !err.isEmpty {
                    errorMessage = err
                } else {
                    successMessage = localized("登入成功")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onDismiss() }
                }
            }
        }
    }

    private func runButtonJS(action: String, credentials: [String: String]) {
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginJS = LoginManager.shared.extractLoginJs(rawLogin) ?? ""
        let combined = "\(loginJS)\n\(action)"

        Task.detached(priority: .userInitiated) {
            let engine = JSCoreEngine()
            engine.bookSource = source
            Self.configureLegadoRuntime(engine, source: source)

            engine.browserPresentHandler = { url, title, completion in
                DispatchQueue.main.async {
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        completion(nil); return
                    }
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) { body in
                            topVC.dismiss(animated: true) {
                                completion(body)
                            }
                        }
                    )
                    topVC.present(hostVC, animated: true)
                }
            }
            engine.toastHandler = { msg in
                Task { @MainActor in
                    BookSourceFormLoginView.presentToastAlert(message: msg)
                }
            }
            engine.cloudflareChallengeHandler = { url, done in
                Task { @MainActor in
                    _ = try? await CloudflareChallengePresenter.present(url: url)
                    done()
                }
            }

            let bindings: [String: Any] = [
                "result": credentials,
                "baseUrl": source.bookSourceUrl
            ]
            _ = engine.evaluate(combined, bindings: bindings)
        }
    }

    nonisolated private static func configureLegadoRuntime(_ engine: JSCoreEngine, source: BookSource) {
        let sourceUrl = source.bookSourceUrl
        let runtimeStore = BookSourceRuntimeStateStore.shared
        let ruleData = BookSourceRuleData(source: source)

        engine.sourceBridge.getVariableHandler = {
            runtimeStore.sourceVariableJSON(for: sourceUrl) ?? ""
        }
        engine.sourceBridge.setVariableHandler = { jsonString in
            runtimeStore.setSourceVariableJSON(jsonString, for: sourceUrl)
        }
        engine.sourceBridge.getLoginInfoHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl).flatMap { info in
                guard let data = try? JSONSerialization.data(withJSONObject: info) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
        engine.sourceBridge.getLoginInfoMapHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
        }
        engine.sourceBridge.putLoginInfoHandler = { info in
            guard let data = info.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceUrl, info: dict)
        }
        engine.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.putLoginHeaderHandler = { header in
            guard let data = header.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            LoginManager.shared.storeLoginHeaders(sourceUrl: sourceUrl, headers: dict)
        }
        engine.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.getHeaderMapHandler = {
            var headers = source.parsedHeaders
            if let loginHeaders = LoginManager.shared.getLoginHeaderMap(sourceUrl: sourceUrl) {
                headers.merge(loginHeaders) { _, new in new }
            }
            return headers
        }
        engine.sourceBridge.evalJSHandler = { js in
            engine.evaluate(js) ?? ""
        }
        engine.analyzeUrlHandler = { urlStr in
            let analyzeUrl = AnalyzeUrl(
                ruleUrl: urlStr,
                baseUrl: source.bookSourceUrl,
                source: ruleData,
                jsEvaluator: { js, bindings in engine.evaluate(js, bindings: bindings) }
            )
            if analyzeUrl.isDataUri {
                guard let decoded = analyzeUrl.decodeDataUri() else { return "" }
                if analyzeUrl.type?.isEmpty == false {
                    return decoded.data.map { String(format: "%02x", $0) }.joined()
                }
                return String(data: decoded.data, encoding: .utf8) ?? ""
            }
            guard var request = analyzeUrl.toURLRequest() else { return "" }
            for (key, value) in source.parsedHeaders where request.value(forHTTPHeaderField: key) == nil {
                request.setValue(value, forHTTPHeaderField: key)
            }
            LoginManager.shared.applyLoginHeaders(to: &request, sourceUrl: sourceUrl)
            let semaphore = DispatchSemaphore(value: 0)
            var body = ""
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data {
                    body = String(data: data, encoding: .utf8) ?? ""
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 30)
            return body
        }
        if !source.jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        }
    }

    // MARK: - UIKit Helpers

    /// Returns the topmost presented UIViewController for presenting modal sheets from background tasks.
    @MainActor
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let p = top.presentedViewController { top = p }
        return top
    }

    @MainActor
    static func presentToastAlert(message: String) {
        let showNewAlert = {
            guard let presenter = topViewControllerForToast() else { return }
            showToastAlert(message: message, from: presenter)
        }

        if let currentToastAlert, currentToastAlert.presentingViewController != nil {
            currentToastAlert.dismiss(animated: false) {
                Task { @MainActor in
                    self.currentToastAlert = nil
                    showNewAlert()
                }
            }
        } else {
            currentToastAlert = nil
            showNewAlert()
        }
    }

    @MainActor
    private static func showToastAlert(message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        currentToastAlert = alert
        presenter.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            if currentToastAlert === alert {
                currentToastAlert = nil
            }
        }
    }

    @MainActor
    private static func topViewControllerForToast() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            if presented is UIAlertController {
                break
            }
            top = presented
        }
        return top
    }
}

// MARK: - LoginUIField model

struct LoginUIField: Identifiable {
    let id = UUID()
    let name: String
    let type: FieldType
    let action: String?

    enum FieldType: String { case text, password, button }

    static func parse(from json: String) -> [LoginUIField] {
        // Legado's loginUi is frequently authored as a JS object literal
        // (single-quoted keys, trailing commas) that strict JSON rejects;
        // LoginManager.lenientJSONArray normalizes those before decoding.
        guard let array = LoginManager.lenientJSONArray(json) else { return [] }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let typeStr = dict["type"] as? String ?? "text"
            let type = FieldType(rawValue: typeStr) ?? .text
            let action = dict["action"] as? String
            return LoginUIField(name: name, type: type, action: action)
        }
    }
}
