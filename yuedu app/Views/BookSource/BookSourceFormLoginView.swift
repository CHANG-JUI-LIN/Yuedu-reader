import SwiftUI
import UIKit

// MARK: - BookSourceFormLoginView
// Handles book sources whose `loginUi` JSON defines form fields (text/password/button).
// After the user fills in credentials and taps "確認", the loginUrl JS is executed
// with those credentials stored via LoginManager — mirroring Legado's SourceLoginDialog.

struct BookSourceFormLoginView: View {
    let source: BookSource
    let onDismiss: () -> Void

    private let gs = GlobalSettings.shared
    @State private var fields: [LoginUIField] = []
    @State private var values: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(gs.t("請填入登入資訊"))) {
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
            .navigationTitle(source.bookSourceName.isEmpty ? gs.t("書源登入") : source.bookSourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("取消")) { onDismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button(gs.t("確認")) { doLogin() }
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { loadUI() }
    }

    // MARK: - Setup

    private func loadUI() {
        fields = LoginUIField.parse(from: source.loginUi)
        // Pre-fill with stored credentials
        if let stored = LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) {
            values = stored
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
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
            errorMessage = gs.t("書源未設定 loginUrl")
            return
        }

        isLoading = true
        Task.detached(priority: .userInitiated) {
            let engine = JSCoreEngine()
            engine.bookSource = source

            // Wire browser pop-up for java.startBrowser / java.startBrowserAwait
            engine.browserPresentHandler = { url, title, done in
                DispatchQueue.main.async {
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        done(); return
                    }
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) {
                            topVC.dismiss(animated: true, completion: done)
                        }
                    )
                    topVC.present(hostVC, animated: true)
                }
            }

            // Wire java.toast / java.longToast — shows a UIAlertController auto-dismiss
            engine.toastHandler = { msg in
                guard let topVC = BookSourceFormLoginView.topViewController() else { return }
                let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                topVC.present(alert, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { alert.dismiss(animated: true) }
            }

            // Wire CF challenge: present CloudflareChallengeView and call done() when cookies are ready
            engine.cloudflareChallengeHandler = { url, done in
                Task { @MainActor in
                    _ = try? await CloudflareChallengePresenter.present(url: url)
                    done()
                }
            }
            let bindings: [String: Any] = [
                "result": "",
                "baseUrl": source.bookSourceUrl,
                "source": [
                    "bookSourceUrl": source.bookSourceUrl,
                    "bookSourceName": source.bookSourceName,
                    "loginUrl": source.loginUrl,
                    "loginInfo": credentials
                ]
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
                    successMessage = gs.t("登入成功")
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

            engine.browserPresentHandler = { url, title, done in
                DispatchQueue.main.async {
                    guard let topVC = BookSourceFormLoginView.topViewController() else {
                        done(); return
                    }
                    let hostVC = UIHostingController(
                        rootView: JsBridgeBrowserView(urlString: url, title: title) {
                            topVC.dismiss(animated: true, completion: done)
                        }
                    )
                    topVC.present(hostVC, animated: true)
                }
            }
            engine.toastHandler = { msg in
                guard let topVC = BookSourceFormLoginView.topViewController() else { return }
                let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                topVC.present(alert, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { alert.dismiss(animated: true) }
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
}

// MARK: - LoginUIField model

struct LoginUIField: Identifiable {
    let id = UUID()
    let name: String
    let type: FieldType
    let action: String?

    enum FieldType: String { case text, password, button }

    static func parse(from json: String) -> [LoginUIField] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let typeStr = dict["type"] as? String ?? "text"
            let type = FieldType(rawValue: typeStr) ?? .text
            let action = dict["action"] as? String
            return LoginUIField(name: name, type: type, action: action)
        }
    }
}
