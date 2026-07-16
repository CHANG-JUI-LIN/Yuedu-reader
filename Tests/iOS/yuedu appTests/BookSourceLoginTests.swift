import Foundation
import Testing
@testable import yuedu_app

// MARK: - BookSourceLoginTests
// 光遇聚合書源登入相關測試：
//   1. 書源 JSON 解碼（loginUrl、loginUi 等欄位）
//   2. LoginUIField.parse() 正確解析 text/password/button
//   3. LoginManager.extractLoginJs() 從 JS loginUrl 提取
//   4. 按鈕動作對應（login(true) 觸發實際 API 登入）

@Suite("BookSourceLogin", .serialized)
struct BookSourceLoginTests {

    // MARK: - 光遇聚合書源 JSON 解碼

    @Test("光遇聚合書源解碼：loginUrl、loginUi、jsLib 欄位")
    func decodeGuangYuSource() throws {
        // 僅包含此測試需要的核心欄位；完整 JSON 由 BookSourceLocalFixtureTests 覆蓋
        let sample: [String: Any] = [
            "bookSourceName": "光遇聚合(26.5.30)",
            "bookSourceUrl": "光遇聚合",
            "bookSourceGroup": "聚合,番茄,七猫,塔读",
            "loginUrl": """
            function login(flag) {
                if (flag == undefined) {
                    result = JSON.parse(source.getLoginInfo())
                } else {
                    source.putLoginInfo(JSON.stringify(result));
                }
                let email = result["邮箱"];
                let pwd = result["密码"];
                if (!email || !pwd) { return false; }
                return true;
            }
            """,
            "loginUi": """
            [
                {"name":"邮箱","type":"text"},
                {"name":"密码","type":"password"},
                {"name":"登录账号","type":"button","action":"login(true)"},
                {"name":"注册账号","type":"button","action":"register()"}
            ]
            """,
            "jsLib": "function getToken() { return ''; }",
        ]
        let data = try JSONSerialization.data(withJSONObject: sample)
        let source = try JSONDecoder().decode(BookSource.self, from: data)

        #expect(source.bookSourceName == "光遇聚合(26.5.30)")
        #expect(!source.loginUrl.isEmpty)
        #expect(source.loginUrl.contains("function login(flag)"))
        #expect(!source.loginUi.isEmpty)
        #expect(!source.jsLib.isEmpty)
    }

    @Test("光遇聚合書源 loginUrl 被 extractLoginJs 識別為 JS")
    func loginUrlIsJS() {
        let loginUrl = """
        function login(flag) {
            if (flag == undefined) {
                result = JSON.parse(source.getLoginInfo());
            } else {
                source.putLoginInfo(JSON.stringify(result));
            }
            return true;
        }
        """
        let extracted = LoginManager.shared.extractLoginJs(loginUrl)
        #expect(extracted != nil)
        #expect(extracted!.contains("function login(flag)"))
    }

    @Test("https URL 不被 extractLoginJs 視為 JS")
    func plainUrlIsNotJS() {
        let loginUrl = "https://example.com/login"
        let extracted = LoginManager.shared.extractLoginJs(loginUrl)
        #expect(extracted == nil)
    }

    // MARK: - LoginUIField.parse() 按鈕解析

    @Test("LoginUIField.parse() 正確解析 text / password / button 欄位")
    func parseLoginUiFields() {
        let json = """
        [
            {"name":"邮箱","type":"text"},
            {"name":"密码","type":"password"},
            {"name":"登录账号","type":"button","action":"login(true)"},
            {"name":"注册账号","type":"button","action":"register()"}
        ]
        """
        let fields = LoginUIField.parse(from: json)

        #expect(fields.count == 4)

        let textField = fields[0]
        #expect(textField.name == "邮箱")
        #expect(textField.type == .text)
        #expect(textField.action == nil)

        let passwordField = fields[1]
        #expect(passwordField.name == "密码")
        #expect(passwordField.type == .password)
        #expect(passwordField.action == nil)

        let loginButton = fields[2]
        #expect(loginButton.name == "登录账号")
        #expect(loginButton.type == .button)
        #expect(loginButton.action == "login(true)")

        let registerButton = fields[3]
        #expect(registerButton.name == "注册账号")
        #expect(registerButton.type == .button)
        #expect(registerButton.action == "register()")
    }

    @Test("LoginUIField.parse() 正確解析 select 欄位與選項")
    func parseSelectLoginUiField() throws {
        let json = """
        [
            {"name":"气泡字号","type":"select","chars":["小","中","大"],"default":"中"},
            {"name":"气泡选择","type":"select","chars":["默认","圆角"],"default":"圆角"}
        ]
        """
        let fields = LoginUIField.parse(from: json)

        #expect(fields.count == 2)
        #expect(fields[0].type == .select)
        #expect(fields[0].options == ["小", "中", "大"])
        #expect(fields[0].defaultValue == "中")
        #expect(fields[1].type == .select)
        #expect(fields[1].options == ["默认", "圆角"])
        #expect(fields[1].defaultValue == "圆角")

        let loginFields = LoginManager.shared.parseLoginUi(json)
        let size = try #require(loginFields.first)
        #expect(size.type == .select)
        #expect(size.options == ["小", "中", "大"])
        #expect(size.defaultValue == "中")
    }

    @Test("LoginUIField.parse() 空 JSON 回傳空陣列")
    func parseEmptyLoginUi() {
        let fields = LoginUIField.parse(from: "")
        #expect(fields.isEmpty)
    }

    @Test("LoginUIField.parse() 容忍單引號 JS 物件字面量（大灰狼聚合源）")
    func parseSingleQuotedLoginUi() {
        // 大灰狼/光遇等聚合源的 loginUi 後半段以 JS 物件字面量撰寫（單引號 key/value），
        // 嚴格 JSONSerialization 會整個解析失敗導致表單空白。寬鬆解析須能還原全部欄位。
        let json = """
        [{
            "name": "邮箱",
            "type": "text"
        }, {
            'name': '密码',
            'type': 'password'
        }, {
            'action': "set_source('番茄')",
            'name': '番茄',
            'type': 'button'
        }, {
            'action': "login(true)",
            'name': '登录书源',
            'type': 'button',
        }]
        """
        let fields = LoginUIField.parse(from: json)
        #expect(fields.count == 4)
        #expect(fields[0].name == "邮箱")
        #expect(fields[1].type == .password)
        #expect(fields[2].action == "set_source('番茄')")
        // 含 button 欄位 → 表單會以「完成」取代會誤觸 bare login() 的「確認」。
        #expect(fields.contains { $0.type == .button })
    }

    @Test("LoginUIField.parse() 容忍尾逗號")
    func parseTrailingCommaLoginUi() {
        let json = """
        [
            {"name":"邮箱","type":"text"},
            {"name":"登录","type":"button","action":"login(true)"},
        ]
        """
        let fields = LoginUIField.parse(from: json)
        #expect(fields.count == 2)
    }

    @Test("LoginUIField.parse() 只有 text 欄位、無按鈕")
    func parseTextOnly() {
        let json = """
        [{"name":"用户名","type":"text"},{"name":"密码","type":"password"}]
        """
        let fields = LoginUIField.parse(from: json)
        #expect(fields.count == 2)
        #expect(!fields.contains(where: { $0.type == .button }))
    }

    // MARK: - login(true) 語意：flag 參數觸發登入

    @Test("書源 loginUi 登入按鈕的 action 是 login(true) 而非無參數 login()")
    func loginButtonActionIsLoginTrue() throws {
        let json = """
        [
            {"name":"邮箱","type":"text"},
            {"name":"密码","type":"password"},
            {"name":"登录账号","type":"button","action":"login(true)"}
        ]
        """
        let fields = LoginUIField.parse(from: json)
        let buttons = fields.filter { $0.type == .button }
        #expect(buttons.count == 1)

        let loginAction = try #require(buttons.first?.action)
        // `login(true)` 傳入 flag，代表使用者主動點擊登入按鈕
        // 與 toolbar 預設「確認」(login() 無參數) 不同
        #expect(loginAction == "login(true)")
    }

    // MARK: - 有 button 欄位時不需預設「確認」按鈕

    @Test("loginUi 含 button 欄位時，確認按鈕應隱藏")
    func shouldHideConfirmButtonWhenLoginUiHasButtons() {
        let json = """
        [
            {"name":"邮箱","type":"text"},
            {"name":"密码","type":"password"},
            {"name":"登录账号","type":"button","action":"login(true)"}
        ]
        """
        let fields = LoginUIField.parse(from: json)
        let hasButtons = fields.contains(where: { $0.type == .button })
        #expect(hasButtons == true)
    }

    @Test("loginUi 無 button 欄位時，確認按鈕應顯示")
    func shouldShowConfirmButtonWhenLoginUiHasNoButtons() {
        let json = """
        [{"name":"用户名","type":"text"},{"name":"密码","type":"password"}]
        """
        let fields = LoginUIField.parse(from: json)
        let hasButtons = fields.contains(where: { $0.type == .button })
        #expect(hasButtons == false)
    }

    @Test("WebView 導入按鈕解析 yuedu://booksource/importonline")
    func parseWebImportSourceURL() throws {
        let url = try #require(URL(
            string: "yuedu://booksource/importonline?src=https%3A%2F%2Fsy.gyks.cf%2Fdownload%2F%E5%85%89%E9%81%87%E8%81%9A%E5%90%88.json"
        ))
        let sourceURL = try #require(JsBridgeBrowserRepresentable.Coordinator.onlineImportSourceURL(from: url))

        #expect(sourceURL.scheme == "https")
        #expect(sourceURL.host == "sy.gyks.cf")
        #expect(sourceURL.path.contains("光遇聚合.json"))
    }

    @Test("WebView 導入按鈕解析 Legado legado://import/auto")
    func parseLegadoImportDeepLink() throws {
        // 更新書源 頁面的下載按鈕發出的 Legado 導入連結（src 內含二次編碼的中文檔名）。
        let url = try #require(URL(
            string: "legado://import/auto?src=https%3A%2F%2Fqd.doubi.tk%2Fsource%2Fapi%2Fdownload%2F%25E5%25AE%2589%25E5%258D%2593.json%3Fkey%3DKsJR74bFLwC8chgi"
        ))
        let sourceURL = try #require(JsBridgeBrowserRepresentable.Coordinator.onlineImportSourceURL(from: url))

        #expect(sourceURL.scheme == "https")
        #expect(sourceURL.host == "qd.doubi.tk")
        #expect(sourceURL.path.contains("安卓.json"))
        #expect(sourceURL.query == "key=KsJR74bFLwC8chgi")
    }

    @Test("WebView 載入前可取得同域名登入 cookie")
    func browserInitialLoadUsesStoredCookies() throws {
        let url = try #require(URL(string: "https://v1.gyks.cf/user"))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "v1.gyks.cf",
            .path: "/",
            .name: "qttoken",
            .value: "token-for-test",
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }

        let cookies = JsBridgeBrowserRepresentable.Coordinator.cookiesForInitialLoad(url: url)
        #expect(cookies.contains { $0.name == "qttoken" && $0.value == "token-for-test" })
    }

    @Test("包含 fanqienovel 規則的書源顯示番茄登入入口")
    func supportsFanqieLoginWhenRulesNeedSessionId() {
        var source = BookSource()
        source.ruleToc.chapterUrl = "<js>java.getCookie('fanqienovel.com', 'sessionid')</js>"

        #expect(BookSourceFormLoginView.supportsFanqieLogin(source: source))
    }

    @Test("番茄 sessionid 可被 JS cookie bridge 讀取")
    func fanqieSessionCookieReadableByJSBridge() throws {
        let url = "https://fanqienovel.com"
        CookieStore.shared.set(url: url, cookie: "sessionid=session-for-test")
        defer {
            CookieStore.shared.remove(url: url)
        }

        let engine = JSCoreEngine()
        let sessionId = engine.evaluate("java.getCookie('fanqienovel.com', 'sessionid')")
        #expect(sessionId == "session-for-test")
    }

    @Test("JS bridge 環境判斷優先回傳改版")
    func jsBridgeCheckEnvPrefersModernEnvironment() {
        let engine = JSCoreEngine()
        let env = engine.evaluate("""
        function checkEnv() {
            try {
                if (typeof java.reLoginView == 'function') {
                    return "改版";
                }
            } catch (error) {}
            try {
                java.deviceID();
                return "苹果";
            } catch (error) {}
            return "改版";
        }
        checkEnv();
        """)

        #expect(env == "改版")
    }
}

@Suite("GuangYuLiveBookSource", .serialized)
struct GuangYuLiveBookSourceTests {

    @Test("光遇聚合真源：checkEnv 判斷為改版")
    func guangYuFixtureCheckEnvReportsModernEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["YueduLocalBookSourceFixturePath"]
                ?? env["TEST_RUNNER_YueduLocalBookSourceFixturePath"]
        else { return }

        let source = try loadGuangYuSource(fixturePath: fixturePath)
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureRuntime(engine, source: source)

        #expect(engine.evaluate("checkEnv()") == "改版")
    }

    @Test("光遇聚合真源：安全按钮、登录、搜索、详情、目录、正文")
    func guangYuLoginSearchAndRead() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["YueduLocalBookSourceFixturePath"]
                ?? env["TEST_RUNNER_YueduLocalBookSourceFixturePath"],
              let email = env["YueduGuangYuEmail"] ?? env["TEST_RUNNER_YueduGuangYuEmail"],
              let password = env["YueduGuangYuPassword"] ?? env["TEST_RUNNER_YueduGuangYuPassword"],
              !email.isEmpty,
              !password.isEmpty
        else { return }

        let source = try loadGuangYuSource(fixturePath: fixturePath)
        let sourceUrl = source.bookSourceUrl
        let credentials = ["邮箱": email, "密码": password]

        LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: sourceUrl)
        defer {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
            BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: sourceUrl)
            CookieStore.shared.clearAll()
        }

        try await runButtonAction(
            "getCloudSettings(true)",
            source: source,
            credentials: credentials
        )
        let cloudConfig = try #require(BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: sourceUrl))
        #expect(cloudConfig.contains("hosts"))

        try await runButtonAction(
            "ste('小说')",
            source: source,
            credentials: credentials
        )
        try await runButtonAction(
            "setSearchSource()",
            source: source,
            credentials: credentials.merging([
                "搜索来源(支持的平台请前往源变量中查看,多个来源用英文逗号分割)": "全部"
            ]) { _, new in new }
        )
        try await runButtonAction(
            "setFindSource()",
            source: source,
            credentials: credentials.merging([
                "发现页来源(支持的平台请前往源变量中查看)": "全部"
            ]) { _, new in new }
        )

        try await runButtonAction(
            "login(true)",
            source: source,
            credentials: credentials
        )
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl)?["邮箱"] == email)
        let token = try evaluateRuntimeScript("getToken()", source: source, credentials: credentials)
        #expect(token.count > 10)
        let searchProbe = try evaluateRuntimeScript(
            "request('/search?title=斗罗大陆&tab=小说&source=全部&page=1&disabled_sources=0')",
            source: source,
            credentials: credentials
        )
        let searchProbeSummary = summarizeSearchProbe(searchProbe)

        let books = try await BookSourceFetcher.shared.search(query: "斗罗大陆", in: source)
        guard let book = books.first(where: { $0.name.contains("斗罗大陆") }) else {
            throw TestRuntimeError.search(
                filteredCount: books.count,
                rawNames: books.prefix(10).map(\.name),
                tokenLength: token.count,
                probeSummary: searchProbeSummary
            )
        }
        #expect(book.bookUrl.hasPrefix("data:;base64,"))

        let infoPackage = try await BookSourceFetcher.shared.fetchBookInfoPackage(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        #expect(infoPackage.name.contains("斗罗大陆"))
        #expect(infoPackage.tocUrl.hasPrefix("data:;base64,"))

        let tocPackage = try await BookSourceFetcher.shared.fetchTOCPackage(
            tocUrl: infoPackage.tocUrl,
            source: source,
            runtimeVariables: infoPackage.runtimeVariables
        )
        let firstChapter = try #require(tocPackage.chapters.first)
        #expect(!firstChapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(firstChapter.url.hasPrefix("data:;base64,") || firstChapter.url.hasPrefix("http"))

        let bookId = UUID()
        defer {
            BookSourceFetcher.shared.clearAllChapterCache(bookId: bookId)
        }
        let chapterPackage = try await BookSourceFetcher.shared.fetchChapterPackage(
            ref: firstChapter,
            bookId: bookId,
            source: source
        )
        #expect(!chapterPackage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func loadGuangYuSource(fixturePath: String) throws -> BookSource {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        return try #require(
            sources.first { $0.bookSourceName.contains("光遇") || $0.bookSourceUrl.contains("光遇") }
        )
    }

    private func runButtonAction(
        _ action: String,
        source: BookSource,
        credentials: [String: String]
    ) async throws {
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureRuntime(engine, source: source)
        var toasts: [String] = []
        engine.toastHandler = { message in
            toasts.append(message)
        }
        engine.browserPresentHandler = { _, _, completion in
            completion("")
        }

        let loginJS = try #require(LoginManager.shared.extractLoginJs(source.loginUrl))
        _ = engine.evaluate(
            "\(loginJS)\n\(action)",
            bindings: [
                "result": credentials,
                "baseUrl": source.bookSourceUrl
            ]
        )
        if let error = engine.lastError {
            throw TestRuntimeError.js(action: action, error: error, toasts: toasts)
        }
    }

    private func evaluateRuntimeScript(
        _ script: String,
        source: BookSource,
        credentials: [String: String]
    ) throws -> String {
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureRuntime(engine, source: source)
        let result = engine.evaluate(
            script,
            bindings: [
                "result": credentials,
                "baseUrl": source.bookSourceUrl
            ]
        )
        if let error = engine.lastError {
            throw TestRuntimeError.js(action: script, error: error, toasts: [])
        }
        return result ?? ""
    }

    private func summarizeSearchProbe(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "invalid-json length=\(body.count) prefix=\(body.prefix(120))"
        }
        let code = json["code"].map { "\($0)" } ?? "nil"
        let msg = json["msg"].map { "\($0)" } ?? "nil"
        let count: Int
        if let data = json["data"] as? [Any] {
            count = data.count
        } else {
            count = -1
        }
        return "code=\(code), msg=\(msg), dataCount=\(count), length=\(body.count)"
    }

    private func configureRuntime(_ engine: JSCoreEngine, source: BookSource) {
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
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return }
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceUrl, info: dict)
        }
        engine.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.putLoginHeaderHandler = { header in
            guard let data = header.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return }
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
                jsEvaluator: { js, bindings in engine.evaluateIsolated(js, bindings: bindings) }
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

    private enum TestRuntimeError: Error, CustomStringConvertible {
        case js(action: String, error: String, toasts: [String])
        case search(filteredCount: Int, rawNames: [String], tokenLength: Int, probeSummary: String)

        var description: String {
            switch self {
            case let .js(action, error, toasts):
                return "JS action failed: \(action), error: \(error), toasts: \(toasts.joined(separator: " | "))"
            case let .search(filteredCount, rawNames, tokenLength, probeSummary):
                return "Search did not include 斗罗大陆. filteredCount=\(filteredCount), rawNames=\(rawNames.joined(separator: " / ")), tokenLength=\(tokenLength), probe=\(probeSummary)"
            }
        }
    }
}
