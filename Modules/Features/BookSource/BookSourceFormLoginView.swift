import SwiftUI
import UIKit
import JavaScriptCore

// MARK: - BookSourceFormLoginView
// Handles book sources whose `loginUi` JSON defines form fields (text/password/select/button).
// After the user fills in credentials and taps "Confirm", the loginUrl JS is executed
// with those credentials stored via LoginManager — mirroring Legado's SourceLoginDialog.

struct BookSourceFormLoginView: View {
    let source: BookSource
    let onDismiss: () -> Void

    @MainActor private static weak var currentToastAlert: UIAlertController?

    private let gs = GlobalSettings.shared
    @State private var fields: [LoginUIField] = []
    @State private var values: [String: String] = [:]
    // Dynamic loginUi is evaluated asynchronously. Start in the same loading state
    // as Legado so the first render never presents an empty form as if it were ready.
    @State private var isLoading = true
    @State private var showFanqieLogin = false
    @State private var showLog = false
    @State private var canRetryLoginUi = false
    /// What a menu button's run reported when the source itself said nothing.
    /// Alert only, never the inline error Section: that Section sits below the whole
    /// form, which on a long source menu is far off-screen — the button still read
    /// as dead even once it had something to say.
    @State private var menuAlert: MenuActionAlert? = nil

    struct MenuActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var dismissesView = false
    }

    var body: some View {
        NavigationStack {
            // Form with the original SwiftUI row components (TextField/SecureField
            // trailing rows, Picker, Toggle, Button), laid out stacked full-width —
            // Legado's login dialog starts the fields directly, without a section header.
            Form {
                Section {
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
                        case .select:
                            selectRow(field: field)
                        case .toggle:
                            toggleRow(field: field)
                        case .button:
                            Button(field.name) {
                                handleButton(field: field)
                            }
                            .foregroundColor(DSColor.accent)
                        }
                    }
                }
                .interfaceSectionSurface()

                if Self.supportsFanqieLogin(source: source) {
                    Section {
                        Button {
                            showFanqieLogin = true
                        } label: {
                            Label(localized("番茄登入"), systemImage: "network")
                        }
                        .foregroundColor(DSColor.accent)
                    }
                    .interfaceSectionSurface()
                }
            }
            .disabled(isLoading)
            .navigationTitle(loginTitle)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
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
                            .accessibilityLabel(localized("完成"))
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            persistCurrentFormValues()
                            onDismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(localized("完成"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showLoginHeader()
                        } label: {
                            Label(localized("查看登录头"), systemImage: "key.horizontal")
                        }
                        Button {
                            deleteLoginHeader()
                        } label: {
                            Label(localized("删除登录头"), systemImage: "trash")
                        }
                        Divider()
                        Button {
                            showLog = true
                        } label: {
                            Label(localized("日志"), systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(localized("更多"))
                }
            }
        }
        .onAppear { loadUI() }
        .sheet(isPresented: $showLog) {
            BookSourceDebugView()
        }
        .alert(
            menuAlert?.title ?? "",
            isPresented: Binding(
                get: { menuAlert != nil },
                set: { if !$0 { menuAlert = nil } }
            ),
            presenting: menuAlert
        ) { _ in
            if canRetryLoginUi {
                Button(localized("重試")) {
                    menuAlert = nil
                    canRetryLoginUi = false
                    loadUI()
                }
            }
            Button(localized("好"), role: .cancel) {
                let dismissesView = menuAlert?.dismissesView == true
                menuAlert = nil
                canRetryLoginUi = false
                if dismissesView { onDismiss() }
            }
        } message: { alert in
            Text(alert.detail)
        }
        .sheet(isPresented: $showFanqieLogin) {
            JsBridgeBrowserView(urlString: "https://fanqienovel.com", title: localized("番茄登入")) { _ in
                showFanqieLogin = false
            }
        }
    }

    /// Legado's `login_source` title format: 「登入：源名稱」.
    private var loginTitle: String {
        let name = source.bookSourceName.isEmpty ? localized("書源登入") : source.bookSourceName
        return String(format: localized("登入：%@"), name)
    }

    // MARK: - Rows

    @ViewBuilder
    private func selectRow(field: LoginUIField) -> some View {
        HStack {
            Text(field.name).foregroundColor(DSColor.textSecondary)
            Spacer()
            if field.options.isEmpty {
                TextField(field.name, text: binding(for: field.name))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                Picker(field.name, selection: selectionBinding(for: field)) {
                    ForEach(options(for: field), id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(DSColor.accent)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(field: LoginUIField) -> some View {
        if let chars = LoginToggleChars(options: field.options) {
            Toggle(isOn: toggleBinding(for: field, chars: chars)) {
                Text(field.name).foregroundColor(DSColor.textSecondary)
            }
            .tint(DSColor.accent)
        } else {
            // `chars` that isn't a two-state pair can't be a switch —
            // show the choices instead of guessing which one means on.
            selectRow(field: field)
        }
    }

    // MARK: - 更多 menu (Legado menu_show_login_header / menu_del_login_header / menu_log)

    private func showLoginHeader() {
        let header = LoginManager.shared.getLoginHeader(sourceUrl: source.bookSourceUrl)
        menuAlert = MenuActionAlert(
            title: localized("登录头"),
            detail: header?.isEmpty != false
                ? localized("未設置登录头")
                : header ?? localized("未設置登录头")
        )
    }

    private func deleteLoginHeader() {
        LoginManager.shared.removeLoginHeader(sourceUrl: source.bookSourceUrl)
        menuAlert = MenuActionAlert(
            title: localized("完成"),
            detail: localized("已刪除登录头")
        )
    }

    // MARK: - Setup

    private func loadUI() {
        isLoading = true
        canRetryLoginUi = false
        let rawUi = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some sources (e.g. 起点) define `loginUi` as JS (`@js:` / `<js>…</js>`) that
        // builds the form by calling a jsLib helper like `Menu()`. Evaluate it first,
        // then parse the JSON it returns. Plain JSON-array loginUi takes the fast path.
        if rawUi.hasPrefix("@js:") || rawUi.hasPrefix("<js>") {
            isLoading = true
            let src = source
            Task.detached(priority: .userInitiated) {
                let evaluation = Self.evaluateJsLoginUiResult(source: src)
                let parsed = LoginUIField.parseResult(from: evaluation.json)
                let stored = LoginManager.shared.getLoginInfo(sourceUrl: src.bookSourceUrl)
                await MainActor.run {
                    self.fields = parsed ?? []
                    self.values = Self.initialValues(for: parsed ?? [], stored: stored)
                    self.isLoading = false
                    guard parsed == nil else { return }
                    self.canRetryLoginUi = true
                    self.menuAlert = MenuActionAlert(
                        title: localized("書源腳本錯誤"),
                        detail: evaluation.error ?? localized("載入失敗，點按重試")
                    )
                }
            }
            return
        }

        fields = LoginUIField.parse(from: source.loginUi)
        values = Self.initialValues(
            for: fields,
            stored: LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl)
        )
        isLoading = false
    }

    struct LoginUIEvaluationResult: Sendable {
        let json: String
        let error: String?
    }

    /// Evaluate a JS-based `loginUi` (with jsLib + source runtime wired) and return
    /// the JSON form definition produced by its completion value or result assignment.
    nonisolated static func evaluateJsLoginUi(source: BookSource) -> String {
        evaluateJsLoginUiResult(source: source).json
    }

    /// Legado, Sigma, and the MD3 implementation evaluate loginUrl JS before loginUi JS
    /// in the same engine. Dynamic menus commonly call helpers declared by loginUrl, so
    /// evaluating loginUi in isolation produces a blank form after the JS error is swallowed.
    nonisolated static func evaluateJsLoginUiResult(
        source: BookSource
    ) -> LoginUIEvaluationResult {
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureLegadoRuntime(engine, source: source)
        engine.toastHandler = { msg in
            Task { @MainActor in BookSourceFormLoginView.presentToastAlert(message: msg) }
        }

        let raw = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginJS = LoginManager.shared.extractLoginJs(rawLogin) ?? ""
        let jsBody = LoginManager.shared.extractLoginJs(raw) ?? raw
        let storedLoginInfo = LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) ?? [:]
        // Run loginUrl and loginUi in one JS context, mirroring Legado's evalUiJs.
        // `book` and `chapter` are null for a standalone login sheet, as in Legado.
        // Do not append `result` here. Legado returns the loginUi script's completion
        // value; 神魔小說 ends with `JSON.stringify(rows)` while `result` still contains
        // previously stored credentials. Returning `result` would replace the menu JSON
        // with that credentials object and make the form parser report a load failure.
        let wrapped = """
        \(loginJS)
        \(jsBody)
        """
        let out = engine.evaluate(
            wrapped,
            result: storedLoginInfo,
            bindings: [
                "baseUrl": source.bookSourceUrl,
                "book": NSNull(),
                "chapter": NSNull(),
            ]
        ) ?? ""
        let error = engine.lastError
        AppLogger.parse("⟐ menuEval", context: [
            "resultLen": out.count,
            "head": String(out.prefix(120)),
            "hasLoginJs": !loginJS.isEmpty,
            "jsError": error ?? "none",
        ])
        return LoginUIEvaluationResult(json: out, error: error)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }

    private func selectionBinding(for field: LoginUIField) -> Binding<String> {
        Binding(
            get: { selectedValue(for: field) },
            set: { newValue in
                values[field.name] = newValue
                persistCurrentFormValues()
            }
        )
    }

    private func toggleBinding(for field: LoginUIField, chars: LoginToggleChars) -> Binding<Bool> {
        Binding(
            get: { chars.isOn(stored: values[field.name], default: field.defaultValue) },
            set: { newValue in
                values[field.name] = chars.value(isOn: newValue)
                persistCurrentFormValues()
                // A toggle carries the same `action` as a button row and the source
                // expects it to run on every flip: 同人小说网 hangs `commentRefreshTip()`
                // on all 评论 switches to say the change needs a manual refresh.
                // No-ops when the row declares no action.
                handleButton(field: field)
            }
        )
    }

    private func selectedValue(for field: LoginUIField) -> String {
        if let value = values[field.name], !value.isEmpty {
            return value
        }
        if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
            return defaultValue
        }
        return field.options.first ?? ""
    }

    private func options(for field: LoginUIField) -> [String] {
        let selected = selectedValue(for: field)
        guard !selected.isEmpty, !field.options.contains(selected) else {
            return field.options
        }
        return [selected] + field.options
    }

    private static func initialValues(
        for fields: [LoginUIField],
        stored: [String: String]?
    ) -> [String: String] {
        var result = stored ?? [:]
        // `.select` only: a `.toggle`'s declared default must stay out of the stored
        // values (see `LoginToggleChars.isOn`) — seeding it flips 段评开关 off.
        for field in fields where field.type == .select {
            if let current = result[field.name], !current.isEmpty {
                continue
            }
            if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
                result[field.name] = defaultValue
            } else if let first = field.options.first {
                result[field.name] = first
            }
        }
        return result
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

    /// Returns text-like fields that must be filled before running loginUrl.
    /// Selects with declared options already have a usable selection; toggles
    /// and action buttons are not credentials and therefore are optional.
    static func missingRequiredFieldNames(
        fields: [LoginUIField],
        values: [String: String]
    ) -> [String] {
        fields.compactMap { field in
            let requiresValue: Bool
            switch field.type {
            case .text, .password:
                requiresValue = true
            case .select:
                requiresValue = field.options.isEmpty
            case .toggle, .button:
                requiresValue = false
            }
            guard requiresValue,
                  values[field.name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            else { return nil }
            return field.name
        }
    }

    // MARK: - Login Action

    private func doLogin() {
        guard !isLoading else { return }
        menuAlert = nil
        canRetryLoginUi = false

        // Validate: collect non-button field values
        let credentials = currentFormValues()

        let missingFields = Self.missingRequiredFieldNames(fields: fields, values: credentials)
        guard missingFields.isEmpty else {
            menuAlert = MenuActionAlert(
                title: localized("操作失敗"),
                detail: localized("請填入登入資訊")
            )
            return
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
        AppLogger.parse("⟐ menuButton", context: ["name": field.name, "action": field.action ?? "nil"])
        guard let action = field.action, !action.isEmpty else { return }
        // If it's a URL, open in browser; if JS, run it
        if action.hasPrefix("http://") || action.hasPrefix("https://") {
            if let url = URL(string: action) {
                UIApplication.shared.open(url)
            }
        } else {
            // JS button action
            let currentCredentials = currentFormValues()
            if !currentCredentials.isEmpty {
                LoginManager.shared.storeLoginInfo(
                    sourceUrl: source.bookSourceUrl,
                    info: currentCredentials
                )
            }
            runButtonJS(action: action, credentials: currentCredentials)
        }
    }

    private func currentFormValues() -> [String: String] {
        fields
            .filter { $0.type != .button }
            .reduce(into: [String: String]()) { dict, field in
                switch field.type {
                case .select:
                    dict[field.name] = selectedValue(for: field)
                case .text, .password, .toggle:
                    // A toggle reports only what the user actually flipped — resolving
                    // its default here would write it back on the next save.
                    dict[field.name] = values[field.name] ?? ""
                case .button:
                    break
                }
            }
    }

    private func persistCurrentFormValues() {
        let current = currentFormValues()
        guard !current.isEmpty else { return }
        LoginManager.shared.storeLoginInfo(sourceUrl: source.bookSourceUrl, info: current)
    }

    // MARK: - JS Execution

    private func runLoginJS(credentials: [String: String]) {
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLogin.isEmpty else {
            menuAlert = MenuActionAlert(
                title: localized("操作失敗"), detail: localized("書源未設定 loginUrl"))
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
                    // Awaiting JS is blocked until this fires; the box guarantees it does,
                    // including when the sheet is swiped away instead of dismissed by a button.
                    let awaitBox = BrowserAwaitBox(completion)
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        awaitBox.finish(nil); return
                    }
                    // `topVC` weakly: a strong capture would form a presenter ⇄ presented
                    // cycle that outlives dismissal, and the box's deinit is what releases
                    // the JS thread when the sheet goes away without a button tap.
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) { [weak topVC] body in
                            guard let topVC else { awaitBox.finish(body); return }
                            topVC.dismiss(animated: true) {
                                awaitBox.finish(body)
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
                    menuAlert = MenuActionAlert(title: localized("操作失敗"), detail: err)
                } else {
                    menuAlert = MenuActionAlert(
                        title: localized("登入成功"),
                        detail: localized("登入成功"),
                        dismissesView: true
                    )
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
            let spoke = MenuActionSpokeFlag()

            engine.browserPresentHandler = { url, title, completion in
                spoke.fired = true
                DispatchQueue.main.async {
                    // Same contract as in runLoginJS: the awaiting JS thread is released
                    // exactly once, whichever way the browser sheet goes away.
                    let awaitBox = BrowserAwaitBox(completion)
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        awaitBox.finish(nil); return
                    }
                    // `topVC` weakly: a strong capture would form a presenter ⇄ presented
                    // cycle that outlives dismissal, and the box's deinit is what releases
                    // the JS thread when the sheet goes away without a button tap.
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) { [weak topVC] body in
                            guard let topVC else { awaitBox.finish(body); return }
                            topVC.dismiss(animated: true) {
                                awaitBox.finish(body)
                            }
                        }
                    )
                    topVC.present(hostVC, animated: true)
                }
            }
            engine.toastHandler = { msg in
                spoke.fired = true
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
            // `changeMenu(tag)` does `source.put("menuTag", tag); java.reLoginView()`. Re-evaluate
            // the menu JS (which now reads the new menuTag) and refresh the displayed buttons so
            // multi-page source menus (起点's 评论设置 → 段评开关) can actually navigate.
            engine.reLoginViewHandler = {
                AppLogger.parse("⟐ reLoginView FIRED", context: [:])
                let evaluation = Self.evaluateJsLoginUiResult(source: source)
                // Keep the current menu if a source's refresh script fails; replacing it
                // with an empty array would hide the only actionable controls.
                guard let parsed = LoginUIField.parseResult(from: evaluation.json) else {
                    AppLogger.parse("⟐ reLoginView failed", context: [
                        "error": evaluation.error ?? "invalid loginUi JSON"
                    ])
                    return
                }
                AppLogger.parse("⟐ reLoginView", context: [
                    "newFields": parsed.count,
                    "names": parsed.prefix(8).map { $0.name }.joined(separator: "|")
                ])
                Task { @MainActor in
                    self.fields = parsed
                    self.values = Self.initialValues(
                        for: parsed,
                        stored: LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) ?? self.values
                    )
                }
            }

            let bindings: [String: Any] = [
                "result": credentials,
                "baseUrl": source.bookSourceUrl
            ]
            SourceAPIErrorLog.shared.clear(for: source.bookSourceUrl)
            if source.bookSourceName.contains("书山聚合") {
                let before = engine.evaluate("java.get('yunpara')") ?? "<nil>"
                NSLog(
                    "❖SHUSHAN TRACE❖ stage=menu.before action=%@ yunpara=%@ jsError=%@",
                    action,
                    before.isEmpty ? "<empty>" : before,
                    engine.lastError ?? "none"
                )
            }
            _ = engine.evaluate(combined, bindings: bindings)
            if source.bookSourceName.contains("书山聚合") {
                let actionError = engine.lastError
                let after = engine.evaluate("java.get('yunpara')") ?? "<nil>"
                NSLog(
                    "❖SHUSHAN TRACE❖ stage=menu.after action=%@ yunpara=%@ actionError=%@",
                    action,
                    after.isEmpty ? "<empty>" : after,
                    actionError ?? "none"
                )
            }

            // A menu action that finishes without saying anything is the failure mode
            // this reports: 同人小说网's `registerByInvite()` returns early when its API
            // answers `{"error":…}` (wrong/used 邀请码, rejected device id), so
            // 「邀请码注册Token」 looked like a dead button. Only speak when the source
            // itself stayed silent — its own toast is the better message when it has one.
            guard !spoke.fired else { return }
            let report: MenuActionAlert?
            if let jsError = engine.lastError {
                report = MenuActionAlert(title: localized("書源腳本錯誤"), detail: jsError)
            } else if let failure = SourceAPIErrorLog.shared.last(for: source.bookSourceUrl) {
                report = MenuActionAlert(
                    title: localized("書源伺服器回應失敗"), detail: failure.displayText)
            } else {
                report = nil
            }
            guard let report else { return }
            AppLogger.parse("⟐ menuButton silent", context: [
                "title": report.title, "detail": report.detail
            ])
            Task { @MainActor in self.menuAlert = report }
        }
    }

    /// Whether a menu action produced any user-visible response of its own.
    /// A reference box: the JS runs on the engine's own thread and sets this
    /// through escaping handlers, then `runButtonJS` reads it once JS has finished.
    private final class MenuActionSpokeFlag: @unchecked Sendable {
        var fired = false
    }

    nonisolated private static func configureLegadoRuntime(_ engine: JSCoreEngine, source: BookSource) {
        let sourceUrl = source.bookSourceUrl
        let runtimeStore = BookSourceRuntimeStateStore.shared
        let ruleData = BookSourceRuleData(source: source)

        // Settings actions and chapter parsing use separate JS engines. Persist
        // Legado `java.put/get` state (书山's `yunpara`) at source scope.
        engine.getData = { key in
            runtimeStore.sourceValue(for: sourceUrl, key: key)
        }
        engine.putData = { key, value in
            runtimeStore.setSourceValue(value, for: sourceUrl, key: key)
        }
        engine.sourceBridge.getVariableHandler = {
            runtimeStore.sourceVariableJSON(for: sourceUrl) ?? ""
        }
        engine.sourceBridge.setVariableHandler = { jsonString in
            runtimeStore.setSourceVariableJSON(jsonString, for: sourceUrl)
        }
        engine.sourceBridge.getKeyValueHandler = { key in
            runtimeStore.sourceValue(for: sourceUrl, key: key)
        }
        engine.sourceBridge.putKeyValueHandler = { key, value in
            runtimeStore.setSourceValue(value, for: sourceUrl, key: key)
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
        // Legado semantics: the payload is stored verbatim and only becomes request
        // headers if it is a JSON object. 书山聚合's `login()` stores a bare api_key
        // and reads it straight back via `source.getLoginHeader()` to build `?key=`
        // URLs — synthesising a header name for it clobbers the constant token the
        // source's own `header` rule sends.
        engine.sourceBridge.putLoginHeaderHandler = { header in
            LoginManager.shared.storeLoginHeader(sourceUrl: sourceUrl, raw: header)
        }
        engine.sourceBridge.getLoginHeaderHandler = {
            LoginManager.shared.getLoginHeader(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.getHeaderMapHandler = {
            // This sheet's own engine resolves the (possibly `@js:`) header rule —
            // don't reach for a second engine via `source.parsedHeaders`.
            var headers = engine.resolvedSourceHeaders()
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
                sourceHeader: source.header,
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
            for (key, value) in engine.resolvedSourceHeaders()
            where request.value(forHTTPHeaderField: key) == nil {
                request.setValue(value, forHTTPHeaderField: key)
            }
            LoginManager.shared.applyLoginHeaders(to: &request, sourceUrl: sourceUrl)
            if request.value(forHTTPHeaderField: "Cookie") == nil,
               let reqUrl = request.url?.absoluteString {
                let jar = CookieStore.shared.get(url: reqUrl)
                if !jar.isEmpty {
                    request.setValue(jar, forHTTPHeaderField: "Cookie")
                }
            }
            let semaphore = DispatchSemaphore(value: 0)
            var body = ""
            var statusCode: Int?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                statusCode = (response as? HTTPURLResponse)?.statusCode
                if let data {
                    body = String(data: data, encoding: .utf8) ?? ""
                }
                semaphore.signal()
            }.resume()
            let timedOut = semaphore.wait(timeout: .now() + 30) == .timedOut
            // Menu actions are the one place a source's API failure has no other way
            // to reach the user: the rule JS returns early on a bad reply, so the
            // button just looks dead. `runButtonJS` reports whatever lands here.
            SourceAPIErrorLog.shared.record(
                sourceUrl: sourceUrl, requestUrl: request.url?.absoluteString,
                statusCode: statusCode, body: body, timedOut: timedOut
            )
            return body
        }
        engine.upLoginDataHandler = { mapValue in
            // `java.upLoginData(map)` from a settings menu (起点/光遇 段评颜色·气泡模版). Merge the
            // map's key/values into the source's stored login data so `source.getLoginInfoMap()`
            // (and the jsLib's `getConfigValue`/`Map()`) read them back.
            let raw = mapValue.toDictionary() ?? [:]
            var updates: [String: String] = [:]
            for (key, value) in raw {
                guard let name = key as? String else { continue }
                updates[name] = (value as? String) ?? String(describing: value)
            }
            guard !updates.isEmpty else { return }
            var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
            info.merge(updates) { _, new in new }
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceUrl, info: info)
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
    let options: [String]
    let defaultValue: String?
    enum FieldType: String { case text, password, select, button, toggle }

    static func parse(from json: String) -> [LoginUIField] {
        parseResult(from: json) ?? []
    }

    /// Returns nil when the JS result is not an array. A valid `[]` remains an empty
    /// menu, allowing the caller to distinguish an intentional empty form from failure.
    static func parseResult(from json: String) -> [LoginUIField]? {
        // Legado's loginUi is frequently authored as a JS object literal
        // (single-quoted keys, trailing commas) that strict JSON rejects;
        // LoginManager.lenientJSONArray normalizes those before decoding.
        guard let array = LoginManager.lenientJSONArray(json) else { return nil }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let typeStr = dict["type"] as? String ?? "text"
            let type = FieldType(rawValue: typeStr) ?? .text
            let action = dict["action"] as? String
            return LoginUIField(
                name: name,
                type: type,
                action: action,
                options: stringArray(dict["chars"]),
                defaultValue: stringValue(dict["default"])
            )
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap(stringValue)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let value?:
            return String(describing: value)
        case nil:
            return nil
        }
    }
}

// MARK: - Preview

#Preview("書源登入表單") {
    // Shaped after 同人小说网's menu: text/password rows, a `select` of 模板,
    // the `toggle` switches its jsLib reads back through `qdToggle()`, and buttons.
    let loginUi = """
    [
      {"name":"邀请码","type":"text"},
      {"name":"◎ 气泡二","type":"password"},
      {"name":"◎ 模板","type":"select","chars":["起点","样式一","样式二"],"default":"起点"},
      {"name":"段评开关","type":"toggle","chars":["🔳","✅"],"default":"🔳",
       "action":"commentRefreshTip()"},
      {"name":"章名段评","type":"toggle","chars":["🔳","✅"],"default":"🔳",
       "action":"commentRefreshTip()"},
      {"name":"账号管理","type":"button","action":"_login()"}
    ]
    """
    let source: BookSource = {
        var s = BookSource(
            bookSourceUrl: "https://m.qidian.com#preview",
            bookSourceName: "起點限免（同人小說網）"
        )
        s.loginUi = loginUi
        return s
    }()
    BookSourceFormLoginView(source: source, onDismiss: {})
}
