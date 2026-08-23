import Foundation
import Testing
@testable import yuedu_app

/// A voice source declares how hard it may be hit, and until now the TTS path ignored it.
///
/// 小米MiMo TTS ships `"concurrentRate": "1/1000"` — one request per second. `HTTPTTSEngine`
/// keeps a three-segment preload window and downloads in parallel, so the source was handed four
/// requests at once; the field was parsed, stored, shown in the UI, and never enforced. The
/// throttle already existed for book sources (`SourceRateLimit`), so this wires the TTS provider
/// into the same one rather than growing a second implementation.
@Suite("TTS concurrentRate")
struct TTSConcurrentRateTests {

    @Test("Legado's rate forms parse the way book sources already read them")
    func rateFormsAreShared() async {
        // "N/M" — a window. Two requests fit immediately, the third waits out the window.
        let windowElapsed = await Self.elapsed(rate: "2/400", requests: 3)
        #expect(windowElapsed > 0.3)

        // "N" — a concurrency cap, no waiting when nothing else is in flight.
        let serialElapsed = await Self.elapsed(rate: "1", requests: 3)
        #expect(serialElapsed < 0.3)

        // Unlimited, the overwhelming majority of sources.
        let unlimitedElapsed = await Self.elapsed(rate: "", requests: 3)
        #expect(unlimitedElapsed < 0.3)
    }

    @Test("a 1/1000 source is not handed a whole preload window at once")
    func preloadBurstIsThrottled() async throws {
        let source = ImportedTTSSource(
            name: "限流語音源",
            urlTemplate: "@js:'https://rate.test/api/tts?t=' + encodeURIComponent(speakText)",
            sourceID: "tts-rate-1000",
            concurrentRate: "1/1000"
        )

        let started = Date()
        try await Self.withTTSSource(source) {
            // What the engine does at the start of a chapter: the current segment plus its
            // preload window, all at once.
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<3 {
                    group.addTask {
                        _ = try? await CustomHTTPProvider()
                            .audioData(for: "第\(index)段", title: "測試", rate: 0.5)
                    }
                }
            }
            // Inside the harness: its teardown resets the counter.
            #expect(TTSRateTestURLProtocol.requestCount == 3)
        }

        // Three requests at one per second cannot finish in under two seconds.
        #expect(Date().timeIntervalSince(started) > 1.8)
    }

    @Test("a source declaring no rate is not slowed down")
    func sourceWithoutRateRunsStraightThrough() async throws {
        let source = ImportedTTSSource(
            name: "不限流語音源",
            urlTemplate: "@js:'https://rate.test/api/tts?t=' + encodeURIComponent(speakText)",
            sourceID: "tts-rate-none"
        )

        let started = Date()
        try await Self.withTTSSource(source) {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<3 {
                    group.addTask {
                        _ = try? await CustomHTTPProvider()
                            .audioData(for: "第\(index)段", title: "測試", rate: 0.5)
                    }
                }
            }
            #expect(TTSRateTestURLProtocol.requestCount == 3)
        }

        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    // MARK: - Harness

    private static let wav = Data(Array("RIFF".utf8) + [UInt8](repeating: 0, count: 8))

    /// Wall time for `requests` sequential acquisitions of `rate`, straight through the shared
    /// limiter — no network, so this measures only the budget.
    private static func elapsed(rate: String, requests: Int) async -> TimeInterval {
        let key = "tts-rate-probe-\(rate)-\(UUID().uuidString)"
        let started = Date()
        for _ in 0..<requests {
            await SourceRateLimit.run(rate: rate, key: key) {}
        }
        return Date().timeIntervalSince(started)
    }

    private static func withTTSSource(
        _ source: ImportedTTSSource,
        _ body: () async throws -> Void
    ) async rethrows {
        let gs = GlobalSettings.shared
        let previousTemplate = gs.httpTtsUrlTemplate
        let previousHeaders = gs.httpTtsHeaders
        let previousSources = gs.importedTTSSources
        let previousUseSystemVoice = gs.ttsUseSystemVoice

        TTSRateTestURLProtocol.reset()
        TTSRateTestURLProtocol.responseData = wav
        URLProtocol.registerClass(TTSRateTestURLProtocol.self)

        gs.importedTTSSources = [source]
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = [:]
        gs.ttsUseSystemVoice = false

        defer {
            URLProtocol.unregisterClass(TTSRateTestURLProtocol.self)
            TTSRateTestURLProtocol.reset()
            LoginManager.shared.clearLogin(sourceUrl: source.id)
            gs.httpTtsUrlTemplate = previousTemplate
            gs.httpTtsHeaders = previousHeaders
            gs.importedTTSSources = previousSources
            gs.ttsUseSystemVoice = previousUseSystemVoice
        }

        try await body()
    }
}

private final class TTSRateTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock {
            responseData = Data()
            count = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "rate.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
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
