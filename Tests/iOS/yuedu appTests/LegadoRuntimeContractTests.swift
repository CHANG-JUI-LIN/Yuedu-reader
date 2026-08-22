import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

@Suite("Legado Rhino Normalizer", .serialized)
struct LegadoRhinoNormalizerTests {
    @Test("normalizes Rhino parameter redeclaration")
    func parameterRedeclaration() throws {
        let input = "function GetUrl(path, params, sourceUrl) { let sourceUrl = 'x'; return sourceUrl; }"
        let normalized = LegadoRhinoNormalizer.normalize(input)
        #expect(normalized.source.contains("var sourceUrl = 'x'"))
        let context = try #require(JSContext())
        _ = context.evaluateScript(normalized.source)
        #expect(context.exception == nil)
        #expect(normalized.edits.contains { $0.originalText == "let" && $0.replacementText == "var" })
    }

    @Test("JSCoreEngine normalizes the no-result path used to load jsLib")
    func jsLibEvaluationPath() {
        let engine = JSCoreEngine()
        let result = engine.evaluate(
            "function GetUrl(sourceUrl) { let sourceUrl = sourceUrl || 'default'; return sourceUrl; } GetUrl('fixture')"
        )

        #expect(result == "fixture")
        #expect(engine.lastError == nil)
    }

    @Test("preserves existing result and destructuring compatibility")
    func existingNormalizations() {
        let input = "let result = 1; pairs.map([a,b] => a + b); const resultList = [];"
        let output = LegadoRhinoNormalizer.normalize(input).source
        #expect(output.contains("var result = 1"))
        #expect(output.contains("pairs.map(([a,b]) =>"))
        #expect(output.contains("const resultList"))
    }

    @Test("does not rewrite non-code or nested function declarations")
    func leavesProtectedTextAlone() {
        let input = #"""
        function outer(sourceUrl) {
          "let sourceUrl"; 'const sourceUrl'; `let sourceUrl ${"const sourceUrl"}`;
          /let sourceUrl/.test('x');
          // let sourceUrl
          /* const sourceUrl */
          function inner() { let sourceUrl = 'nested'; }
          let sourceUrl2 = 'suffix';
          let sourceUrl = 'top';
        }
        """#
        let output = LegadoRhinoNormalizer.normalize(input).source
        #expect(output.contains("\"let sourceUrl\""))
        #expect(output.contains("/let sourceUrl/"))
        #expect(output.contains("function inner() { let sourceUrl = 'nested'; }"))
        #expect(output.contains("let sourceUrl2"))
        #expect(output.contains("var sourceUrl = 'top'"))
    }

    @Test("normalizes a nested function against its own parameters")
    func nestedFunctionOwnScope() {
        let input = "function outer(a) { function inner(value) { let value = 1; } let a = 2; }"
        let output = LegadoRhinoNormalizer.normalize(input).source
        #expect(output.contains("function inner(value) { var value = 1; }"))
        #expect(output.contains("var a = 2"))
    }

    @Test("normalization is idempotent and records UTF-16 locations")
    func idempotentLocations() {
        let input = "第一行\nfunction f(value) {\n  let value = 1;\n}"
        let once = LegadoRhinoNormalizer.normalize(input)
        let twice = LegadoRhinoNormalizer.normalize(once.source)
        #expect(twice.source == once.source)
        #expect(once.edits.first?.original.line == 3)
        #expect(once.edits.first?.original.column == 3)
        #expect(once.edits.first?.normalized.line == 3)
        #expect(once.edits.first?.normalized.column == 3)
    }
}

@Suite("Legado Connection Response", .serialized)
struct LegadoConnectionResponseTests {
    @Test("exposes one Jsoup-shaped response contract")
    func responseMetadata() {
        let requestURL = URL(string: "https://example.com/start")!
        let finalURL = URL(string: "https://example.com/final")!
        let result = LegadoHTTPResult(
            requestURL: requestURL,
            finalURL: finalURL,
            statusCode: 201,
            statusMessage: "Created",
            headers: ["X-Test": "yes", "Content-Type": "text/plain"],
            cookies: ["token": "abc", "session": "xyz"],
            body: "created"
        )
        let response = LegadoStrResponse(result: result)
        #expect(response.body() == "created")
        #expect(response.cookies().get("token") == "abc")
        #expect(response.headers().get("x-test") == "yes")
        #expect(response.statusCode() == 201)
        #expect(response.statusMessage() == "Created")
        #expect(response.url == finalURL.absoluteString)
        #expect(response.urlString() == finalURL.absoluteString)
        #expect(response.isSuccessful())
    }

    @Test("two argument java.get retains response metadata")
    func javaGetResponse() {
        let engine = JSCoreEngine()
        engine.networkHandler = { request in
            LegadoHTTPResult(
                requestURL: request.url!,
                finalURL: URL(string: "https://example.com/redirected")!,
                statusCode: 201,
                statusMessage: "Created",
                headers: ["X-Test": "yes"],
                cookies: ["token": "abc"],
                body: "created"
            )
        }
        let value = engine.evaluate("""
        var response = java.get('https://example.com/token', {});
        [response.body(), response.cookies().get('token'), response.headers().get('X-Test'),
         response.statusCode(), response.statusMessage(), response.url, response.isSuccessful()].join('|');
        """)
        #expect(value == "created|abc|yes|201|Created|https://example.com/redirected|true")
    }

    @Test("one argument java.get remains variable storage")
    func javaGetStorageOverload() {
        let engine = JSCoreEngine()
        var storage: [String: String] = [:]
        var requestCount = 0
        engine.putData = { storage[$0] = $1 }
        engine.getData = { storage[$0] }
        engine.networkHandler = { request in
            requestCount += 1
            return .bodyOnly(request: request, body: "unexpected")
        }
        #expect(engine.evaluate("java.put('key', 'value'); java.get('key')") == "value")
        #expect(requestCount == 0)
    }

    @Test("connect overloads and HEAD retain response metadata")
    func connectAndHeadResponses() {
        let engine = JSCoreEngine()
        var requests: [URLRequest] = []
        engine.networkHandler = { request in
            requests.append(request)
            return LegadoHTTPResult(
                requestURL: request.url!, finalURL: request.url!, statusCode: 204,
                statusMessage: "No Content", headers: ["X-Method": request.httpMethod ?? ""],
                cookies: [:], body: request.value(forHTTPHeaderField: "X-Test") ?? ""
            )
        }

        #expect(engine.evaluate("var r=java.connect('https://example.com/a'); [r.code(),r.message()].join('|')") == "204|No Content")
        #expect(engine.evaluate("java.connect('https://example.com/b', {\"X-Test\":\"yes\"}, 2500).body()") == "yes")
        #expect(engine.evaluate("var r=java.head('https://example.com/c', {\"X-Test\":\"head\"}); [r.code(),r.headers().get('X-Method')].join('|')") == "204|HEAD")
        #expect(engine.evaluate("java.head('https://example.com/d', {}, 1200).code()") == "204")
        #expect(engine.evaluate("java.post('https://example.com/e', 'body', {}, 1300).code()") == "204")
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "HEAD", "HEAD", "POST"])
        #expect(requests[3].timeoutInterval == 1.2)
        #expect(requests[4].timeoutInterval == 1.3)
    }
}

@Suite("Legado Java Interop Runtime", .serialized)
struct LegadoJavaInteropRuntimeTests {
    @Test("Java String supports byte arrays and charsets")
    func javaStringCharsets() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("new Packages.java.lang.String([0xE4,0xB8,0xAD], 'UTF-8').toString()") == "中")
        #expect(engine.evaluate("JSON.stringify('中'.getBytes('UTF-16LE'))") == "[45,78]")
        #expect(engine.evaluate("new Packages.java.lang.String([45,78], 'UTF-16LE').toString()") == "中")
        #expect(engine.evaluate("new Packages.java.lang.String([0,65,0,66], 2, 2, 'UTF-16BE').toString()") == "B")
        #expect(engine.evaluate("JSON.stringify('é'.getBytes('ISO-8859-1'))") == "[233]")
    }

    @Test("Android Base64 flags and Java utilities are observable")
    func base64UUIDArrays() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("Packages.android.util.Base64.encodeToString([255,238], 11)") == "_-4")
        #expect(engine.evaluate("JSON.stringify(Packages.android.util.Base64.decode('_-4', 8))") == "[255,238]")
        #expect(engine.evaluate("JSON.stringify(Packages.java.util.Arrays.copyOfRange([1,2,300],1,3))") == "[2,44]")
        let uuids = engine.evaluate("Packages.java.util.UUID.randomUUID() + '|' + Packages.java.util.UUID.randomUUID()") ?? ""
        let parts = uuids.split(separator: "|")
        #expect(parts.count == 2)
        #expect(parts.first != parts.last)
        #expect(parts.allSatisfy { $0.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil })
    }

    @Test("Cipher returns bytes and Hutool helpers remain available")
    func cipherAndHutool() {
        let engine = JSCoreEngine()
        let script = """
        var C = Packages.javax.crypto.Cipher;
        var c = C.getInstance('AES/CBC/PKCS5Padding');
        c.init(C.ENCRYPT_MODE || 1,
          new Packages.javax.crypto.spec.SecretKeySpec('0123456789abcdef'.getBytes(), 'AES'),
          new Packages.javax.crypto.spec.IvParameterSpec('abcdef9876543210'.getBytes()));
        var encrypted = c.doFinal('hello'.getBytes());
        var d = C.getInstance('AES/CBC/PKCS5Padding');
        d.init(C.DECRYPT_MODE || 2,
          new Packages.javax.crypto.spec.SecretKeySpec('0123456789abcdef'.getBytes(), 'AES'),
          new Packages.javax.crypto.spec.IvParameterSpec('abcdef9876543210'.getBytes()));
        new Packages.java.lang.String(d.doFinal(encrypted), 'UTF-8').toString();
        """
        let decrypted = engine.evaluate(script)
        #expect(engine.lastError == nil)
        #expect(decrypted == "hello")
        #expect(engine.evaluate("var h=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','fedcba9876543210'); h.decryptStr(java.base64DecodeToByteArray(h.encryptBase64('hello aes')))") == "hello aes")
        #expect(engine.evaluate("Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('abc')") == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test("capability registry is authoritative and runtime installation is idempotent")
    func registryAndIdempotence() {
        #expect(LegadoRuntimeCapabilityRegistry.contains("Packages.java.lang.String"))
        #expect(LegadoRuntimeCapabilityRegistry.contains("Packages.java.util.HashMap"))
        #expect(!LegadoRuntimeCapabilityRegistry.contains("Packages.com.example.Missing"))
        let engine = JSCoreEngine()
        #expect(engine.evaluate("new Packages.java.lang.String([65], 'UTF-8').toString()") == "A")
        #expect(engine.evaluate("new Packages.java.util.HashMap().size()") == "0")
    }

    @Test("common java utility APIs match Legado contracts")
    func commonJavaUtilities() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("JSON.stringify(java.strToBytes('中', 'UTF-8'))") == "[228,184,173]")
        #expect(engine.evaluate("java.bytesToStr([228,184,173], 'UTF-8')") == "中")
        #expect(engine.evaluate("JSON.stringify(java.hexDecodeToByteArray('00ff10'))") == "[0,255,16]")
        #expect(engine.evaluate("java.toNumChapter('第十二章 標題')") == "第12章 標題")
        #expect(engine.evaluate("var u=java.toURL('../c?q=%E4%B8%AD','https://example.com/a/b'); [u.host,u.origin,u.pathname,u.searchParams.get('q')].join('|')") == "example.com|https://example.com|/c|中")
        #expect(engine.evaluate("java.digestHex('abc','SHA-256')") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(engine.evaluate("java.digestBase64Str('abc','SHA-256')") == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
        #expect(engine.evaluate("java.HMacHex('The quick brown fox jumps over the lazy dog','HmacSHA256','key')") == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(engine.evaluate("java.HMacHex('The quick brown fox jumps over the lazy dog','HmacSHA224','key')") == "88ff8b54675d39b8f72322e65ff945c52d96379988ada25639747e69")
        let uuid = engine.evaluate("java.randomUUID()") ?? ""
        #expect(uuid.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil)
        #expect(engine.evaluate("var z=Packages.cn.hutool.core.util.ZipUtil.gzip('abc',''); [z[0],z[1],z.length>10].join('|')") == "31|139|true")
    }

    @Test("bounded okhttp3 builder executes through the source network session")
    func okhttpBuilder() {
        let engine = JSCoreEngine()
        var captured: URLRequest?
        engine.networkHandler = { request in
            captured = request
            return LegadoHTTPResult(
                requestURL: request.url!, finalURL: request.url!, statusCode: 200,
                statusMessage: "OK", headers: ["X-Reply": "yes"], cookies: [:],
                body: #"{"ok":true}"#
            )
        }
        let value = engine.evaluate("""
        var importer = new JavaImporter();
        importer.importPackage(Packages.okhttp3);
        with (importer) {
          var media = MediaType.parse('application/json');
          var request = new Request.Builder().url('https://example.com/post')
            .post(RequestBody.create('{\"a\":1}', media)).addHeader('X-Test','ok').build();
          var response = new OkHttpClient().newCall(request).execute();
          [response.body().string(), response.headers().names()[0], response.headers().get('x-reply')].join('|');
        }
        """)
        #expect(value == #"{"ok":true}|X-Reply|yes"#)
        #expect(captured?.httpMethod == "POST")
        #expect(captured?.value(forHTTPHeaderField: "X-Test") == "ok")
        #expect(String(data: captured?.httpBody ?? Data(), encoding: .utf8) == #"{"a":1}"#)
        #expect(captured?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

@Suite("Unsupported Legado API", .serialized)
struct UnsupportedLegadoAPITests {
    @Test("unknown namespaces are lazy but invocation is explicit")
    func lazyTraversalAndCall() {
        var source = BookSource()
        source.bookSourceName = "Contract Source"
        source.bookSourceUrl = "contract-source-id"
        let engine = JSCoreEngine()
        engine.bookSource = source

        #expect(engine.withExecutionStage("jsLib") {
            engine.evaluate("function unused(){ return Packages.com.example.missing; } 'loaded';")
        } == "loaded")

        let result = engine.withExecutionStage("ruleContent.content") {
            engine.evaluate("Packages.com.example.missing.call()")
        }
        #expect(result == nil)
        #expect(engine.lastError?.contains("UnsupportedLegadoAPIError: Packages.com.example.missing.call") == true)
        #expect(engine.lastError?.contains("ruleContent.content") == true)
        #expect(engine.lastError?.contains("Contract Source | contract-source-id") == true)
    }

    @Test("unknown constructor reports its exact API without bindings")
    func unknownConstructorRedaction() {
        var source = BookSource()
        source.bookSourceName = "Safe Source"
        source.bookSourceUrl = "safe-source-id"
        let engine = JSCoreEngine()
        engine.bookSource = source
        let result = engine.withExecutionStage("searchUrl") {
            engine.evaluate(
                "new Packages.com.example.Missing()",
                bindings: [
                    "token": "must-not-appear",
                    "authorization": "Bearer must-not-appear",
                    "responseBody": "private-response-body",
                ]
            )
        }
        #expect(result == nil)
        let error = engine.lastError ?? ""
        #expect(error.contains("Packages.com.example.Missing"))
        #expect(!error.contains("must-not-appear"))
        #expect(!error.contains("private-response-body"))
    }
}

private let legadoSourceLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_LEGADO_SOURCE_LIVE_TESTS"] == "1"

@Suite("Legado Full Source Fixtures", .serialized)
struct LegadoFullSourceFixtureTests {
    private static let qimaoDefaultPath =
        "/Users/zhangruilin/Desktop/Test document/RULE/七猫四合一本地版（同人）.json"
    private static let shuqiDefaultPath =
        "/Users/zhangruilin/Desktop/Test document/RULE/书旗（同人）.json"
    private static let qingtianQidianDefaultPath =
        "/Users/zhangruilin/Desktop/Test document/RULE/晴天起点.json"

    /// `named` picks one source out of a multi-source export by a substring of its name; without
    /// it the first entry wins (which is what the single-source fixtures want).
    private func loadSource(
        environmentKey: String,
        defaultPath: String,
        named: String? = nil
    ) throws -> BookSource {
        let path = ProcessInfo.processInfo.environment[environmentKey] ?? defaultPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if named == nil, let source = try? JSONDecoder().decode(BookSource.self, from: data) {
            return source
        }
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        guard let named else { return try #require(sources.first) }
        return try #require(sources.first { $0.bookSourceName.contains(named) })
    }

    /// 晴天起点 (`🔅企点小说`) builds its 段評/熱評/本章说 markup differently per runtime, and both
    /// probes run against our bridge:
    ///
    /// ```js
    /// let deviceType = '安卓';
    /// try { java.deviceID(); deviceType = '苹果' } catch {}
    /// function paraContent(c) { return deviceType == '苹果' ? paraForiOS(c) : paraForAndroid(c) }
    /// ```
    ///
    /// `paraForiOS` passes `createGod` an ABSOLUTE url (`sb + ident`); `paraForAndroid` passes the
    /// site-relative ident and lets `showCmt` resolve it. `checkEnv()` separately decides whether
    /// the click config lands in `click` (legado-改版) or `js` (everything else). Which pair we get
    /// decides what `reviewTarget(forLegadoAction:)` has to parse, so pin it.
    @Test("晴天起点 resolves to the iOS review branch with a js-keyed click config")
    func qingtianQidianReviewBranch() throws {
        let source = try loadSource(
            environmentKey: "QINGTIAN_QIDIAN_SOURCE_JSON",
            defaultPath: Self.qingtianQidianDefaultPath,
            named: "企点小说"
        )
        let bridge = ModernParserBridge(source: source)

        let deviceType = bridge.evaluateSourceScript("""
        var __dev = '安卓';
        try { java.deviceID(); __dev = '苹果' } catch (e) {}
        __dev
        """)
        #expect(bridge.lastSourceScriptError == nil)
        #expect(deviceType == "苹果", "source takes paraForAndroid, whose showCmt url is relative")

        let env = bridge.evaluateSourceScript("checkEnv()")
        #expect(bridge.lastSourceScriptError == nil)
        #expect(env == "轻阅读")
    }

    @Test("unchanged Shuqi jsLib compiles and builds a signed URL from response cookies")
    func shuqiFixture() throws {
        let source = try loadSource(environmentKey: "SHUQI_SOURCE_JSON", defaultPath: Self.shuqiDefaultPath)
        var requestCount = 0
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request in
            requestCount += 1
            return LegadoHTTPResult(
                requestURL: request.url!, finalURL: request.url!, statusCode: 200,
                statusMessage: "OK", headers: ["X-Test": "fixture"],
                cookies: ["shuqi_token": "fixture-token", "z": "1"], body: "fixture-body"
            )
        }
        #expect(bridge.evaluateSourceScript("typeof GetUrl") == "function")
        #expect(bridge.lastSourceScriptError == nil)
        let response = bridge.evaluateSourceScript("var r=java.get('https://t.shuqi.com', {}); [r.body(),r.cookies().toString(),r.statusCode()].join('|')")
        #expect(response == "fixture-body|{shuqi_token=fixture-token, z=1}|200")
        #expect(requestCount == 1)
        let authorization = bridge.evaluateSourceScript("Token(); source.getLoginHeaderMap().get('authorization')")
        #expect(bridge.lastSourceScriptError == nil)
        #expect(authorization?.contains("fixture-token") == true)
        let url = bridge.evaluateSourceScript("GetUrl('/api/search', 'keyword=test')")
        #expect(bridge.lastSourceScriptError == nil)
        #expect(url?.contains("https://ocean.shuqireader.com/api/search") == true)
        #expect(url?.contains("sign=") == true)
    }

    @Test("Shuqi auth error refreshes its bearer before the next source request")
    func shuqiLoginCheckRefreshesBearerImmediately() throws {
        let source = try loadSource(
            environmentKey: "SHUQI_SOURCE_JSON",
            defaultPath: Self.shuqiDefaultPath
        )
        LoginManager.shared.storeLoginHeader(
            sourceUrl: source.bookSourceUrl,
            raw: #"{"authorization":"Bearer stale-fixture"}"#
        )
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }

        var oceanAuthorization: String?
        var requestedHosts: [String] = []
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request in
            requestedHosts.append(request.url?.host ?? "<nil>")
            if request.url?.host == "t.shuqi.com" {
                return LegadoHTTPResult(
                    requestURL: request.url!, finalURL: request.url!, statusCode: 200,
                    statusMessage: "OK", headers: ["Set-Cookie": "shuqi_token=fresh-fixture"],
                    cookies: ["shuqi_token": "fresh-fixture", "z": "1"], body: "fixture"
                )
            }
            oceanAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return .bodyOnly(request: request, body: #"{"data":[]}"#)
        }

        let authError = #"{"message":"Api Gateway Auth ERROR","status":"10003"}"#
        #expect(bridge.applyLoginCheck(html: authError, baseURL: source.bookSourceUrl) == authError)
        #expect(requestedHosts == ["t.shuqi.com"])
        #expect(bridge.lastSourceScriptError == nil)
        #expect(
            bridge.evaluateSourceScript(
                "java.ajax(GetUrl('/webapi/bcspub/openapi/book/chapterlist','bookId=1'))"
            ) == #"{"data":[]}"#
        )
        #expect(oceanAuthorization == "Bearer fresh-fixture")
    }

    @Test("unchanged Qimao jsLib builds device and signing inputs")
    func qimaoFixture() throws {
        let source = try loadSource(environmentKey: "QIMAO_SOURCE_JSON", defaultPath: Self.qimaoDefaultPath)
        let bridge = ModernParserBridge(source: source)
        var browserPage: LegadoBrowserPageRequest?
        bridge.browserPagePresentHandler = { browserPage = $0 }
        #expect(bridge.evaluateSourceScript("typeof qmDevice") == "function")
        #expect(bridge.lastSourceScriptError == nil)
        let device = try #require(bridge.evaluateSourceScript("JSON.stringify(qmDevice.call(this))"))
        let deviceObject = try #require(JSONSerialization.jsonObject(with: Data(device.utf8)) as? [String: Any])
        #expect((deviceObject["uuid"] as? String)?.isEmpty == false)
        #expect((deviceObject["device_id"] as? String)?.isEmpty == false)
        let headers = try #require(bridge.evaluateSourceScript("JSON.stringify(qmHeaders.call(this, 'fixture-token'))"))
        #expect(headers.contains("qm-params"))
        #expect(headers.contains("sign"))

        #expect(
            bridge.evaluateSourceScript(
                "qmOpenComment.call(this,'paragraph','book-fixture','chapter-fixture','paragraph-fixture','七猫段评','')"
            ) == "true"
        )
        let page = try #require(browserPage)
        #expect(page.baseURL == "https://api-cmnt.wtzw.com/")
        #expect(page.html.contains("qmCommentPageData"))
        #expect(page.injectedJavaScript.contains("window.qmRun=run"))
        #expect(page.configurationJSON.contains("heightPercentage"))
        #expect(bridge.lastSourceScriptError == nil)
    }

    @Test(
        "opt-in live sources complete search to first chapter",
        .enabled(if: legadoSourceLiveTestsEnabled, "Set RUN_LEGADO_SOURCE_LIVE_TESTS=1 to run external source requests")
    )
    func liveReadingFlow() async throws {
        let sources = [
            try loadSource(environmentKey: "QIMAO_SOURCE_JSON", defaultPath: Self.qimaoDefaultPath),
            try loadSource(environmentKey: "SHUQI_SOURCE_JSON", defaultPath: Self.shuqiDefaultPath),
        ]
        for var source in sources {
            source.id = UUID()
            source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
            let books = try await BookSourceFetcher.shared.search(query: "斗罗大陆", in: source)
            let book = try #require(books.first)
            let info = try await BookSourceFetcher.shared.fetchBookInfoPackage(
                url: book.bookUrl, source: source, runtimeVariables: book.runtimeVariables
            )
            let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
            let toc = try await BookSourceFetcher.shared.fetchTOCPackage(
                tocUrl: tocURL, source: source, runtimeVariables: info.runtimeVariables,
                onFirstPageReady: nil, forceRefresh: true
            )
            let chapter = try #require(toc.chapters.first { $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator })
            let package = try await BookSourceFetcher.shared.fetchChapterPackage(
                ref: chapter, bookId: UUID(), source: source, chapterReferer: tocURL
            )
            #expect(!package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

@Suite("Legado Parser Bridge Contract", .serialized)
struct LegadoParserBridgeContractTests {
    @Test("chapter content JS receives Legado nextChapterUrl")
    func chapterContentReceivesNextChapterURL() throws {
        var source = BookSource(
            bookSourceUrl: "https://next-chapter.example",
            bookSourceName: "next chapter fixture"
        )
        source.ruleContent.content = "<js>nextChapterUrl</js>"
        let bridge = ModernParserBridge(source: source)
        let chapter = OnlineChapterRef(
            index: 0,
            title: "Chapter 1",
            url: "https://next-chapter.example/1"
        )

        let result = try bridge.parseChapterResult(
            html: "fixture",
            baseURL: chapter.url,
            source: source,
            chapterRef: chapter,
            nextChapterURL: "https://next-chapter.example/2"
        )

        #expect(result.content == "https://next-chapter.example/2")
    }

    @Test("TOC pre-update JS runs in the source runtime before transport")
    func tocPreUpdateUsesSourceRuntime() throws {
        var source = BookSource(
            bookSourceUrl: "https://preupdate.example",
            bookSourceName: "pre-update fixture"
        )
        source.lastUpdateTime = Int64.random(in: 1...Int64.max)
        let bridge = ModernParserBridge(source: source)

        let result = try bridge.runTOCPreUpdateJS(
            """
            source.put('preUpdateMarker', 'ran');
            book.setVariable('pageToken', 'token-1');
            book.tocUrl = 'https://preupdate.example/toc/updated';
            """,
            tocURL: "https://preupdate.example/toc/original",
            runtimeVariables: ["book.name": "Fixture"]
        )

        #expect(result.tocURL == "https://preupdate.example/toc/updated")
        #expect(result.runtimeVariables?["book.tocUrl"] == result.tocURL)
        #expect(result.runtimeVariables?["book.variable.pageToken"] == "token-1")
        #expect(
            BookSourceRuntimeStateStore.shared.sourceValue(
                for: source.bookSourceUrl,
                key: "preUpdateMarker"
            ) == "ran"
        )
    }

    @Test("source script HTTP uses the injected bridge handler")
    func injectedNetworkHandler() {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com"
        source.header = #"{"X-Source":"source-value"}"#
        var requestCount = 0
        var capturedHeaders: [String: String] = [:]
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request in
            requestCount += 1
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            return .bodyOnly(request: request, body: "fixture-body")
        }

        #expect(bridge.evaluateSourceScript("java.get('https://example.com/test', {'X-Call':'call-value'}).body()") == "fixture-body")
        #expect(requestCount == 1)
        #expect(capturedHeaders["X-Source"] == "source-value")
        #expect(capturedHeaders["X-Call"] == "call-value")
    }

    @Test("putLoginHeader affects the next java request in the same JS evaluation")
    func loginHeaderIsImmediatelyVisibleToNetwork() {
        var source = BookSource()
        source.bookSourceUrl = "https://login-header.example"
        source.header = #"{"X-Source":"source-value","Authorization":"Bearer stale"}"#
        LoginManager.shared.removeLoginHeader(sourceUrl: source.bookSourceUrl)
        defer { LoginManager.shared.removeLoginHeader(sourceUrl: source.bookSourceUrl) }

        var capturedHeaders: [String: String] = [:]
        let bridge = ModernParserBridge(source: source)
        bridge.sourceScriptNetworkHandler = { request in
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            return .bodyOnly(request: request, body: "fixture-body")
        }

        let response = bridge.evaluateSourceScript("""
        source.putLoginHeader(JSON.stringify({Authorization:'Bearer fixture'}));
        java.ajax('https://login-header.example/data');
        """)

        #expect(response == "fixture-body")
        #expect(bridge.lastSourceScriptError == nil)
        #expect(capturedHeaders["X-Source"] == "source-value")
        #expect(capturedHeaders["Authorization"] == "Bearer fixture")
    }
}
