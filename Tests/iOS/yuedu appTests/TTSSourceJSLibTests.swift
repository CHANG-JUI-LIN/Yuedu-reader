import Foundation
import Testing
@testable import yuedu_app

/// Where a network voice source's shared JavaScript lives, and how its login state reaches a
/// synthesis request.
///
/// The provider used to run the source's `loginUrl` as JavaScript once per spoken segment,
/// "to define shared functions/variables". No Legado fork does that — upstream evaluates
/// `loginUrl` only from an explicit 登入 action (`BaseSource.login()`, which appends its own
/// `login()` call and throws when the source has none), and carries login state into a request
/// through the stored login header (`AnalyzeUrl(hasLoginHeader: true)` → `getLoginHeaderMap()`).
/// Running a login URL — or a JSON login descriptor — through the JS engine every segment filled
/// a two-minute listening session with 337 `SyntaxError: Unexpected end of script`, all of them
/// discarded by a bare `_ =`.
///
/// Shared helpers belong in `jsLib`, which is the field Legado's `HttpTTS` actually has.
@Suite("TTS source jsLib and login headers")
struct TTSSourceJSLibTests {

    // MARK: - Parsing

    @Test("jsLib is imported from the source JSON")
    func jsLibIsParsed() throws {
        let json = """
        [
          {
            "name": "有 jsLib 的語音源",
            "url": "@js:endpoint(speakText)",
            "jsLib": "function endpoint(t){ return 'https://tts.test/say?t=' + t }"
          }
        ]
        """
        let source = try #require(TTSSourceJSONParser.parse(data: Data(json.utf8)).first)
        #expect(source.jsLib?.contains("function endpoint") == true)
    }

    @Test("a source without jsLib keeps it nil")
    func missingJsLibIsNil() throws {
        let json = #"[{"name":"無 jsLib","url":"https://tts.test/say"}]"#
        let source = try #require(TTSSourceJSONParser.parse(data: Data(json.utf8)).first)
        #expect(source.jsLib == nil)
    }

    /// Sources already on disk were encoded before `jsLib` existed; decoding them must not fail.
    @Test("a stored source saved before jsLib existed still decodes")
    func storedSourceWithoutJsLibDecodes() throws {
        let stored = """
        {
          "id": "legacy",
          "name": "舊的語音源",
          "urlTemplate": "https://tts.test/say",
          "headers": {}
        }
        """
        let source = try JSONDecoder().decode(ImportedTTSSource.self, from: Data(stored.utf8))
        #expect(source.jsLib == nil)
        #expect(source.name == "舊的語音源")
    }

    @Test("jsLib survives a save/load round trip")
    func jsLibRoundTrips() throws {
        let source = ImportedTTSSource(
            name: "來回",
            urlTemplate: "@js:endpoint(speakText)",
            jsLib: "function endpoint(t){ return t }"
        )
        let decoded = try JSONDecoder().decode(
            ImportedTTSSource.self,
            from: try JSONEncoder().encode(source)
        )
        #expect(decoded.jsLib == source.jsLib)
    }

    // MARK: - Synthesis

    @Test("a jsLib helper is in scope for the url rule")
    func jsLibHelperIsCallableFromURLRule() async throws {
        let source = ImportedTTSSource(
            name: "jsLib 語音源",
            urlTemplate: "@js:endpoint(speakText)",
            sourceID: "tts-jslib",
            jsLib: "function endpoint(t){ return 'https://tts.test/say?t=' + encodeURIComponent(t) }"
        )

        try await withTTSSource(source) {
            let data = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            #expect(data == Self.wav)
            let url = try #require(TTSJSLibTestURLProtocol.lastRequest?.url?.absoluteString)
            #expect(url.hasPrefix("https://tts.test/say?t="))
        }
    }

    /// The behaviour change, stated as a contract: `loginUrl` is a login procedure, not a place
    /// to declare helpers. A rule that depends on one now fails loudly instead of relying on a
    /// per-segment evaluation upstream does not perform.
    @Test("loginUrl is not a scope for the url rule's helpers")
    func loginUrlDoesNotDefineHelpers() async throws {
        let source = ImportedTTSSource(
            name: "把函式放在 loginUrl 的語音源",
            urlTemplate: "@js:endpoint(speakText)",
            sourceID: "tts-loginurl-helper",
            loginUrl: "@js:function endpoint(t){ return 'https://tts.test/say?t=' + t }"
        )

        try await withTTSSource(source) {
            await #expect(throws: TTSAudioProviderError.self) {
                _ = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            }
            #expect(TTSJSLibTestURLProtocol.lastRequest == nil)
        }
    }

    /// A plain-URL `loginUrl` is the common shape, and it is what used to be fed to the JS
    /// engine every segment. Synthesis must be entirely unaffected by its presence.
    @Test("a plain-URL loginUrl does not disturb synthesis")
    func plainLoginURLIsInert() async throws {
        let source = ImportedTTSSource(
            name: "一般 loginUrl 的語音源",
            urlTemplate: "@js:'https://tts.test/say?t=' + encodeURIComponent(speakText)",
            sourceID: "tts-plain-loginurl",
            loginUrl: "https://tts.test/login"
        )

        try await withTTSSource(source) {
            let data = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            #expect(data == Self.wav)
        }
    }

    /// How login state actually reaches a synthesis request upstream.
    @Test("the stored login header is sent with the request")
    func storedLoginHeaderIsApplied() async throws {
        let source = ImportedTTSSource(
            name: "需要登入的語音源",
            urlTemplate: "@js:'https://tts.test/say?t=' + encodeURIComponent(speakText)",
            sourceID: "tts-login-header"
        )

        try await withTTSSource(source) {
            LoginManager.shared.storeLoginHeaders(
                sourceUrl: source.id,
                headers: ["Authorization": "Bearer stored-token"]
            )
            _ = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            #expect(
                TTSJSLibTestURLProtocol.lastRequest?
                    .value(forHTTPHeaderField: "Authorization") == "Bearer stored-token"
            )
        }
    }

    /// A header the rule's own JS sets during this evaluation is fresher than the stored one.
    @Test("a header put by the rule overrides the stored one")
    func ruleHeaderWinsOverStoredHeader() async throws {
        let source = ImportedTTSSource(
            name: "自己換 token 的語音源",
            urlTemplate: """
            @js:source.putLoginHeader(JSON.stringify({'Authorization':'Bearer fresh-token'}));\
            'https://tts.test/say?t=' + encodeURIComponent(speakText)
            """,
            sourceID: "tts-fresh-header"
        )

        try await withTTSSource(source) {
            LoginManager.shared.storeLoginHeaders(
                sourceUrl: source.id,
                headers: ["Authorization": "Bearer stale-token"]
            )
            _ = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            #expect(
                TTSJSLibTestURLProtocol.lastRequest?
                    .value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token"
            )
        }
    }

    // MARK: - Harness

    private static let wav = Data(Array("RIFF".utf8) + [UInt8](repeating: 0, count: 8))

    /// Installs `source` as the active network voice, runs `body`, and puts every global it
    /// touched back — `GlobalSettings` and `LoginManager` are process-wide.
    private func withTTSSource(
        _ source: ImportedTTSSource,
        _ body: () async throws -> Void
    ) async throws {
        let gs = GlobalSettings.shared
        let previousTemplate = gs.httpTtsUrlTemplate
        let previousHeaders = gs.httpTtsHeaders
        let previousSources = gs.importedTTSSources
        let previousUseSystemVoice = gs.ttsUseSystemVoice

        TTSJSLibTestURLProtocol.reset()
        TTSJSLibTestURLProtocol.responseData = Self.wav
        URLProtocol.registerClass(TTSJSLibTestURLProtocol.self)

        gs.importedTTSSources = [source]
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = [:]
        gs.ttsUseSystemVoice = false

        defer {
            URLProtocol.unregisterClass(TTSJSLibTestURLProtocol.self)
            TTSJSLibTestURLProtocol.reset()
            LoginManager.shared.clearLogin(sourceUrl: source.id)
            gs.httpTtsUrlTemplate = previousTemplate
            gs.httpTtsHeaders = previousHeaders
            gs.importedTTSSources = previousSources
            gs.ttsUseSystemVoice = previousUseSystemVoice
        }

        try await body()
    }
}

private final class TTSJSLibTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        responseData = Data()
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "tts.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
