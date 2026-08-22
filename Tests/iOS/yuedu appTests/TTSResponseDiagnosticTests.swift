import Foundation
import Testing
@testable import yuedu_app

/// When listening stops, the log has to say *why*.
///
/// Three failed segments in a row end the session, and the anomaly that records it used to read
/// `error=responsePostProcessingFailed` — the app's own category name, with none of the evidence.
/// A quota notice, a login wall and a truncated body are indistinguishable in that line, and the
/// provider's own `ttsLog` breadcrumbs are `NSLog`: visible on a tethered Mac, absent from the
/// 診斷與回報 export the user actually sends. So the provider now carries what came back on the
/// error itself.
@Suite("TTS response diagnostics")
struct TTSResponseDiagnosticTests {

    // MARK: - The diagnostic itself

    @Test("a text body is quoted back so the reason is readable")
    func textBodyIsQuoted() {
        let diagnostic = Self.diagnostic(
            url: "https://voice.test/api/tts?text=hi",
            status: 200,
            contentType: "application/json",
            body: Data(#"{"code":429,"msg":"今日配额已用完，请明天再试"}"#.utf8)
        )
        #expect(diagnostic.bodyExcerpt.contains("今日配额已用完"))
        #expect(diagnostic.description.contains("今日配额已用完"))
        #expect(diagnostic.status == 200)
        #expect(diagnostic.contentType == "application/json")
    }

    /// The same red line the book-source API log holds: a TTS URL carries the user's API key in
    /// its query string, so the query never reaches the log.
    @Test("the endpoint is recorded without its query string")
    func endpointDropsTheQuery() {
        let diagnostic = Self.diagnostic(
            url: "https://voice.test/api/tts?apiKey=SECRET-KEY&text=hi",
            status: 401,
            contentType: "text/plain",
            body: Data("请先登录".utf8)
        )
        #expect(diagnostic.endpoint == "voice.test/api/tts")
        #expect(!diagnostic.description.contains("SECRET-KEY"))
    }

    @Test("a long body is truncated")
    func longBodyIsTruncated() {
        let diagnostic = Self.diagnostic(
            url: "https://voice.test/api/tts",
            status: 200,
            contentType: "text/html",
            body: Data(String(repeating: "喔", count: 900).utf8)
        )
        #expect(diagnostic.bodyExcerpt.count == TTSResponseDiagnostic.excerptLimit + 1)
        #expect(diagnostic.bodyExcerpt.hasSuffix("…"))
    }

    @Test("a binary body falls back to its byte head")
    func binaryBodyUsesByteHead() {
        let diagnostic = Self.diagnostic(
            url: "https://voice.test/api/tts",
            status: 200,
            contentType: "audio/mpeg",
            body: Data([0x00, 0xFE, 0xFF, 0x01, 0x80, 0x7F])
        )
        #expect(diagnostic.bodyExcerpt.contains("hex="))
    }

    // MARK: - Through the provider

    @Test("a quota page served as HTTP 200 names itself in the error")
    func quotaPageSurfacesInTheThrownError() async throws {
        TTSDiagnosticTestURLProtocol.contentType = "application/json"
        TTSDiagnosticTestURLProtocol.responseData =
            Data(#"{"code":429,"msg":"今日配额已用完，请明天再试"}"#.utf8)

        let thrown = await Self.failure(
            urlTemplate: "@js:'https://voice.test/api/tts?apiKey=SECRET-KEY&t=' + encodeURIComponent(speakText)"
        )
        let error = try #require(thrown as? TTSAudioProviderError)
        guard case .responsePostProcessingFailed = error else {
            Issue.record("expected responsePostProcessingFailed, got \(error)")
            return
        }
        // This string is the point of the whole change: it is what the anomaly's detail carries
        // into 診斷與回報.
        let described = String(describing: error)
        #expect(described.contains("今日配额已用完"))
        #expect(described.contains("voice.test/api/tts"))
        #expect(!described.contains("SECRET-KEY"))
    }

    @Test("an HTTP error page names itself too")
    func badStatusSurfacesTheBody() async throws {
        TTSDiagnosticTestURLProtocol.status = 403
        TTSDiagnosticTestURLProtocol.contentType = "text/plain"
        TTSDiagnosticTestURLProtocol.responseData = Data("凭证无效，请重新登录".utf8)

        let thrown = await Self.failure(urlTemplate: "@js:'https://voice.test/api/tts'")
        let error = try #require(thrown as? TTSAudioProviderError)
        guard case .badStatus(let status, _) = error else {
            Issue.record("expected badStatus, got \(error)")
            return
        }
        #expect(status == 403)
        #expect(String(describing: error).contains("凭证无效"))
    }

    @Test("bytes that are neither text nor a known container say so")
    func unrecognisedContainerSurfacesItsHead() async throws {
        TTSDiagnosticTestURLProtocol.contentType = "audio/mpeg"
        TTSDiagnosticTestURLProtocol.responseData = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB])

        let thrown = await Self.failure(urlTemplate: "@js:'https://voice.test/api/tts'")
        let error = try #require(thrown as? TTSAudioProviderError)
        guard case .unrecognisedAudioPayload = error else {
            Issue.record("expected unrecognisedAudioPayload, got \(error)")
            return
        }
        #expect(String(describing: error).contains("hex="))
    }

    // MARK: - Harness

    private static func diagnostic(
        url: String,
        status: Int,
        contentType: String,
        body: Data
    ) -> TTSResponseDiagnostic {
        let request = URLRequest(url: URL(string: url)!)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return TTSResponseDiagnostic(request: request, response: response, data: body)
    }

    /// Runs one synthesis expected to fail and returns the error it threw.
    private static func failure(urlTemplate: String) async -> Error? {
        let source = ImportedTTSSource(
            name: "診斷語音源",
            urlTemplate: urlTemplate,
            sourceID: "tts-diagnostic"
        )
        let gs = GlobalSettings.shared
        let previousTemplate = gs.httpTtsUrlTemplate
        let previousHeaders = gs.httpTtsHeaders
        let previousSources = gs.importedTTSSources
        let previousUseSystemVoice = gs.ttsUseSystemVoice

        URLProtocol.registerClass(TTSDiagnosticTestURLProtocol.self)
        gs.importedTTSSources = [source]
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = [:]
        gs.ttsUseSystemVoice = false

        defer {
            URLProtocol.unregisterClass(TTSDiagnosticTestURLProtocol.self)
            TTSDiagnosticTestURLProtocol.reset()
            LoginManager.shared.clearLogin(sourceUrl: source.id)
            gs.httpTtsUrlTemplate = previousTemplate
            gs.httpTtsHeaders = previousHeaders
            gs.importedTTSSources = previousSources
            gs.ttsUseSystemVoice = previousUseSystemVoice
        }

        do {
            _ = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 0.5)
            Issue.record("synthesis unexpectedly succeeded")
            return nil
        } catch {
            return error
        }
    }
}

private final class TTSDiagnosticTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var contentType = "audio/wav"
    nonisolated(unsafe) static var status = 200

    static func reset() {
        responseData = Data()
        contentType = "audio/wav"
        status = 200
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "voice.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
