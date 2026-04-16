// Port of Legado's BaseSource login system.
// Manages book-source authentication: login execution, cookie/header
// persistence, and login-check evaluation.

import Foundation

// MARK: - Login State

/// Represents the authentication state of a book source.
enum LoginState: Equatable {
    case notRequired
    case loggedIn
    case loggedOut
    case failed(String)

    static func == (lhs: LoginState, rhs: LoginState) -> Bool {
        switch (lhs, rhs) {
        case (.notRequired, .notRequired),
             (.loggedIn, .loggedIn),
             (.loggedOut, .loggedOut):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Login Field (Legado RowUi)

/// A single field in a login form, parsed from the source's `loginUi` JSON.
/// Mirrors Legado's `RowUi` data class.
struct LoginField {
    let name: String
    let type: LoginFieldType
    let action: String?

    enum LoginFieldType: String {
        case text     = "text"
        case password = "password"
        case button   = "button"
    }
}

// MARK: - Login Error

enum LoginError: LocalizedError {
    case noLoginUrl
    case invalidLoginUrl(String)
    case networkError(Error)
    case loginFunctionMissing
    case javaScriptError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noLoginUrl:
            return "Book source has no loginUrl configured."
        case .invalidLoginUrl(let url):
            return "Invalid login URL: \(url)"
        case .networkError(let err):
            return "Network error during login: \(err.localizedDescription)"
        case .loginFunctionMissing:
            return "loginUrl JS does not define a login() function."
        case .javaScriptError(let msg):
            return "Login JS error: \(msg)"
        case .httpError(let code):
            return "Login request returned HTTP \(code)."
        }
    }
}

// MARK: - LoginManager

/// Singleton that manages book-source authentication.
///
/// Mirrors Legado's `BaseSource` login helpers:
/// - `getLoginHeader` / `putLoginHeader` / `removeLoginHeader`
/// - `getLoginInfo` / `putLoginInfo`
/// - `login()` — evaluates loginUrl JS
/// - `loginCheckJs` — post-response check evaluated by the caller
///
/// Cookie and header data are persisted via UserDefaults keyed by the
/// source's `bookSourceUrl`.
final class LoginManager {

    static let shared = LoginManager()

    // MARK: - Storage Keys (mirrors Legado CacheManager keys)

    private static let loginHeaderPrefix = "loginHeader_"
    private static let loginInfoPrefix   = "userInfo_"
    private static let suiteName         = "com.yuedu.loginStore"

    /// Dedicated UserDefaults suite so login data is isolated.
    private let defaults: UserDefaults

    /// In-memory cache of login headers keyed by source URL.
    private var headerCache: [String: [String: String]] = [:]

    /// Serial queue for thread-safe access to caches and defaults.
    private let queue = DispatchQueue(label: "com.yuedu.LoginManager", attributes: .concurrent)

    // MARK: - Init

    private init() {
        defaults = UserDefaults(suiteName: LoginManager.suiteName) ?? .standard
        loadAllHeaders()
    }

    // MARK: - Login Check

    /// Whether the source has a `loginUrl` configured (i.e., *could* require login).
    func requiresLogin(source: BookSource) -> Bool {
        return !source.loginUrl.isEmpty
    }

    /// Evaluate the source's `loginCheckJs` against a response body.
    ///
    /// Legado runs `loginCheckJs` after every network response; if it
    /// returns a *modified* response (e.g. with login-redirect handled)
    /// the caller should use that instead.
    ///
    /// - Parameters:
    ///   - source: The book source.
    ///   - responseBody: The raw HTTP response body.
    ///   - jsEngine: A configured `JSCoreEngine`.
    /// - Returns: Possibly-modified response body, or the original if
    ///   no loginCheckJs is configured.
    func evaluateLoginCheck(
        source: BookSource,
        responseBody: String,
        jsEngine: JSCoreEngine
    ) -> String {
        let checkJs = source.loginCheckJs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !checkJs.isEmpty else { return responseBody }

        let bindings: [String: Any] = [
            "result": responseBody,
            "baseUrl": source.bookSourceUrl,
            "source": sourceBindings(for: source)
        ]
        if let modified = jsEngine.evaluate(checkJs, bindings: bindings) {
            return modified
        }
        return responseBody
    }

    // MARK: - Login Execution

    /// Execute the source's login procedure.
    ///
    /// Legado's `login()` extracts JS from `loginUrl` (stripping the
    /// `@js:` or `<js>…</js>` wrapper), appends a call to a user-
    /// defined `login()` function, and evaluates the whole thing.
    ///
    /// For simple-URL sources the loginUrl is fetched directly via
    /// URLSession; for JS-based sources the JS engine handles everything.
    func login(
        source: BookSource,
        credentials: [String: String] = [:],
        jsEngine: JSCoreEngine
    ) async throws -> LoginState {
        let raw = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .notRequired }

        // Store credential info so JS can access it via source.getLoginInfo()
        if !credentials.isEmpty {
            storeLoginInfo(sourceUrl: source.bookSourceUrl, info: credentials)
        }

        let loginJs = extractLoginJs(raw)

        if let loginJs = loginJs {
            // JS-based login (Legado convention)
            return try executeJsLogin(
                source: source,
                loginJs: loginJs,
                jsEngine: jsEngine
            )
        } else {
            // Simple URL login — substitute credentials and fetch
            return try await executeUrlLogin(
                source: source,
                rawUrl: raw,
                credentials: credentials
            )
        }
    }

    // MARK: - JS Login

    /// Execute a JS-based login.
    ///
    /// Mirrors Legado `BaseSource.login()`:
    /// ```kotlin
    /// val js = "$loginJs\nif(typeof login=='function'){ login.apply(this); }"
    /// evalJS(js)
    /// ```
    private func executeJsLogin(
        source: BookSource,
        loginJs: String,
        jsEngine: JSCoreEngine
    ) throws -> LoginState {
        let wrappedJs = """
        \(loginJs)
        if (typeof login === 'function') {
            login.apply(this);
        } else {
            throw('Function login not implements!!!');
        }
        """

        let bindings: [String: Any] = [
            "baseUrl": source.bookSourceUrl,
            "source": sourceBindings(for: source)
        ]

        let result = jsEngine.evaluate(wrappedJs, bindings: bindings)

        if let err = jsEngine.lastError {
            if err.contains("Function login not implements") {
                throw LoginError.loginFunctionMissing
            }
            throw LoginError.javaScriptError(err)
        }

        // If the JS set a login header we consider it successful.
        if let resultStr = result, !resultStr.isEmpty {
            // Attempt to store it as login header (Legado convention).
            if let data = resultStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                storeLoginHeaders(sourceUrl: source.bookSourceUrl, headers: dict)
            }
        }

        return .loggedIn
    }

    // MARK: - Simple URL Login

    /// Fetch a loginUrl directly (non-JS path).
    private func executeUrlLogin(
        source: BookSource,
        rawUrl: String,
        credentials: [String: String]
    ) async throws -> LoginState {
        var urlString = rawUrl

        // Replace `{{key}}` placeholders with credential values.
        for (key, value) in credentials {
            urlString = urlString.replacingOccurrences(
                of: "{{\(key)}}",
                with: value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            )
        }

        guard let url = URL(string: urlString) else {
            throw LoginError.invalidLoginUrl(urlString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        // Apply source-level headers.
        if let headerData = source.header.data(using: .utf8),
           let headerDict = try? JSONSerialization.jsonObject(with: headerData) as? [String: String] {
            for (k, v) in headerDict {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed("Non-HTTP response")
        }

        guard (200..<400).contains(http.statusCode) else {
            throw LoginError.httpError(http.statusCode)
        }

        // Capture Set-Cookie from the response.
        let cookies = extractCookies(from: http)
        if !cookies.isEmpty {
            var headers = getLoginHeaders(sourceUrl: source.bookSourceUrl)
            let cookieString = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            headers["Cookie"] = cookieString
            storeLoginHeaders(sourceUrl: source.bookSourceUrl, headers: headers)
        }

        return .loggedIn
    }

    // MARK: - Cookie Extraction

    /// Extract cookies from an HTTP response's `Set-Cookie` headers.
    private func extractCookies(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        guard let headerFields = response.allHeaderFields as? [String: String],
              let url = response.url else { return result }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in cookies {
            result[cookie.name] = cookie.value
        }
        return result
    }

    // MARK: - Login URL JS Extraction (mirrors Legado getLoginJs)

    /// Extract the JS body from a loginUrl string.
    /// Returns `nil` if the loginUrl is a plain URL (not JS).
    func extractLoginJs(_ loginUrl: String) -> String? {
        let trimmed = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("<js>") {
            if let endRange = trimmed.range(of: "</js>", options: .backwards) {
                return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<endRange.lowerBound])
            }
            return String(trimmed.dropFirst(4))
        }
        // If it looks like JS code (contains function definitions / statements)
        // rather than a URL, treat it as JS. Legado does this implicitly.
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") && !trimmed.hasPrefix("/") {
            // Heuristic: contains function keyword or multi-line
            if trimmed.contains("function ") || trimmed.contains("\n") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Login UI Parsing

    /// Parse the source's `loginUi` JSON into an array of `LoginField`.
    ///
    /// Legado format: `[{"name":"用户名","type":"text"},{"name":"密码","type":"password"}]`
    func parseLoginUi(_ loginUiJson: String) -> [LoginField] {
        let trimmed = loginUiJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return [] }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let typeStr = dict["type"] as? String ?? "text"
            let type = LoginField.LoginFieldType(rawValue: typeStr) ?? .text
            let action = dict["action"] as? String
            return LoginField(name: name, type: type, action: action)
        }
    }

    // MARK: - Login Header Management (mirrors Legado BaseSource)

    /// Retrieve stored login headers for a source.
    func getLoginHeaders(sourceUrl: String) -> [String: String] {
        var result: [String: String] = [:]
        queue.sync {
            result = headerCache[sourceUrl] ?? [:]
        }
        return result
    }

    /// Retrieve login headers as a JSON string (Legado `getLoginHeader()`).
    func getLoginHeader(sourceUrl: String) -> String? {
        let headers = getLoginHeaders(sourceUrl: sourceUrl)
        guard !headers.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Retrieve login headers as a map (Legado `getLoginHeaderMap()`).
    func getLoginHeaderMap(sourceUrl: String) -> [String: String]? {
        let headers = getLoginHeaders(sourceUrl: sourceUrl)
        return headers.isEmpty ? nil : headers
    }

    /// Store login headers (Legado `putLoginHeader`).
    func storeLoginHeaders(sourceUrl: String, headers: [String: String]) {
        queue.async(flags: .barrier) { [weak self] in
            self?.headerCache[sourceUrl] = headers
            self?.persistHeaders(sourceUrl: sourceUrl, headers: headers)
        }
    }

    /// Remove all login data for a source (Legado `removeLoginHeader`).
    func clearLogin(sourceUrl: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.headerCache.removeValue(forKey: sourceUrl)
            self?.defaults.removeObject(
                forKey: LoginManager.loginHeaderPrefix + sourceUrl
            )
            // loginInfo is stored in Keychain; also clear any legacy UserDefaults entry
            KeychainHelper.delete(account: LoginManager.loginInfoPrefix + sourceUrl)
            self?.defaults.removeObject(
                forKey: LoginManager.loginInfoPrefix + sourceUrl
            )
        }
    }

    /// Apply stored login headers to a URLRequest.
    func applyLoginHeaders(to request: inout URLRequest, sourceUrl: String) {
        let headers = getLoginHeaders(sourceUrl: sourceUrl)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Login Info (Credential) Storage

    /// Store user-provided login credentials in the **Keychain** (Legado `putLoginInfo`).
    /// Passwords are never stored in UserDefaults — Keychain is the only accepted location
    /// for sensitive data on iOS.
    func storeLoginInfo(sourceUrl: String, info: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(account: LoginManager.loginInfoPrefix + sourceUrl, data: json)
    }

    /// Retrieve stored login credentials (Legado `getLoginInfo`).
    /// Reads from Keychain; migrates legacy UserDefaults data transparently on first access.
    func getLoginInfo(sourceUrl: String) -> [String: String]? {
        let account = LoginManager.loginInfoPrefix + sourceUrl

        // Primary: Keychain
        if let json = KeychainHelper.load(account: account),
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return dict
        }

        // Legacy: UserDefaults (migrate and remove)
        if let json = defaults.string(forKey: account),
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            KeychainHelper.save(account: account, data: json)
            defaults.removeObject(forKey: account)
            return dict
        }

        return nil
    }

    // MARK: - Persistence Helpers

    private func persistHeaders(sourceUrl: String, headers: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: LoginManager.loginHeaderPrefix + sourceUrl)
    }

    private func loadAllHeaders() {
        let dict = defaults.dictionaryRepresentation()
        for (key, value) in dict {
            guard key.hasPrefix(LoginManager.loginHeaderPrefix),
                  let json = value as? String,
                  let data = json.data(using: .utf8),
                  let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { continue }
            let sourceUrl = String(key.dropFirst(LoginManager.loginHeaderPrefix.count))
            headerCache[sourceUrl] = headers
        }
    }

    // MARK: - Source Bindings for JS

    /// Build a lightweight dictionary that JS can access as `source.*`.
    private func sourceBindings(for source: BookSource) -> [String: Any] {
        var bindings: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "loginUrl": source.loginUrl,
            "header": source.header
        ]
        if let info = getLoginInfo(sourceUrl: source.bookSourceUrl) {
            bindings["loginInfo"] = info
        }
        if let headerJson = getLoginHeader(sourceUrl: source.bookSourceUrl) {
            bindings["loginHeader"] = headerJson
        }
        return bindings
    }
}
