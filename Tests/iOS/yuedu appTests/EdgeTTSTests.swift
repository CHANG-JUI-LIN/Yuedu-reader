import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EdgeTTSTests {
    @Test func handshakeUsesFiveMinuteWindowsAndExpectedDigest() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(EdgeTTSProtocol.securityToken(date: date) == "42301B335578FEFDAE2637DED1ABD614505D432559EC08032B82048483726AFF")
        #expect(EdgeTTSProtocol.securityToken(date: date) == EdgeTTSProtocol.securityToken(date: date.addingTimeInterval(1)))
        #expect(EdgeTTSProtocol.securityToken(date: date) != EdgeTTSProtocol.securityToken(date: date.addingTimeInterval(300)))
        let request = EdgeTTSProtocol.request(date: date)
        let url = try #require(request.url)
        #expect(url.scheme == "wss")
        #expect(url.host == "speech.platform.bing.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "Sec-MS-GEC" }?.value == EdgeTTSProtocol.securityToken(date: date))
        #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("muid=") == true)
    }

    @Test func ssmlEscapesMarkupAndRemovesUnsupportedControlCharacters() {
        let parts = EdgeTTSProtocol.escapedTextChunks("你好<&>\"'\u{0}\u{B}\n😀")
        #expect(parts == ["你好&lt;&amp;&gt;&quot;&apos;  \n😀"])
        let messages = EdgeTTSProtocol.messages(escapedText: parts[0], voice: .defaultVoice, rate: 0.65)
        #expect(messages.count == 2)
        #expect(messages[0].contains("Path:speech.config\r\n\r\n"))
        #expect(messages[1].contains("name='zh-TW-HsiaoChenNeural'"))
        #expect(messages[1].contains("rate='+30%'"))
        #expect(messages[1].contains(parts[0]))
    }

    @Test func escapedByteLimitPreservesUnicodeAndWholeEntities() {
        let text = String(repeating: "書&😀", count: 1000)
        let chunks = EdgeTTSProtocol.escapedTextChunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 4096 })
        #expect(chunks.joined() == String(repeating: "書&amp;😀", count: 1000))
        #expect(chunks.allSatisfy { !$0.hasSuffix("&") && !$0.hasSuffix("&am") })
    }

    @Test func ratesCoverReaderRangeAndNonfiniteInput() {
        #expect(EdgeTTSProtocol.rateString(0.1) == "-80%")
        #expect(EdgeTTSProtocol.rateString(0.5) == "+0%")
        #expect(EdgeTTSProtocol.rateString(1) == "+100%")
        #expect(EdgeTTSProtocol.rateString(2.5) == "+400%")
        #expect(EdgeTTSProtocol.rateString(.nan) == "+0%")
    }

    @Test func audioFrameParsesTwoByteLengthAndAcceptsTerminalMarker() throws {
        let audio = Data([0xFF, 0xF3, 0x44, 0xC0])
        let frame = Self.frame(headers: "X-RequestId:abc\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n", payload: audio)
        #expect(try EdgeTTSProtocol.event(.data(frame)) == .audio(audio))
        #expect(try EdgeTTSProtocol.event(.data(Self.frame(headers: "Path:audio\r\n", payload: Data()))) == .metadata)
        #expect(try EdgeTTSProtocol.event(.string("Path:turn.end\r\n\r\n{}")) == .finished)
        #expect(try EdgeTTSProtocol.event(.string("Path:audio.metadata\r\n\r\n{}")) == .metadata)
    }

    @Test func malformedFramesAndUnexpectedPathsAreErrors() {
        let frames = [
            Data(), Data([0]), Data([0, 20, 65]),
            Self.frame(headers: "Path:audio\r\nContent-Type:text/html\r\n", payload: Data("error".utf8)),
            Self.frame(headers: "Path:audio\r\n", payload: Data([1])),
        ]
        for frame in frames {
            #expect(throws: EdgeTTSError.invalidResponse) { try EdgeTTSProtocol.event(.data(frame)) }
        }
        #expect(throws: EdgeTTSError.invalidResponse) { try EdgeTTSProtocol.event(.string("Path:unknown\r\n\r\n{}")) }
        #expect(throws: EdgeTTSError.invalidResponse) { try EdgeTTSProtocol.event(.string("broken")) }
    }

    @Test func providerSelectionPreservesDirectAudioAndCustomSources() throws {
        let template = EdgeTTSVoice.defaultVoice.sourceIdentifier
        let edge = try #require(TTSAudioProviderSelection.make(template: template, isDirectChapterAudio: false) as? EdgeTTSAudioProvider)
        #expect(edge.voice == .defaultVoice)
        #expect(try TTSAudioProviderSelection.make(template: template, isDirectChapterAudio: true) is CustomHTTPProvider)
        #expect(try TTSAudioProviderSelection.make(template: "https://tts.example.com/{{text}}", isDirectChapterAudio: false) is CustomHTTPProvider)
        #expect(throws: EdgeTTSError.invalidVoice) {
            try TTSAudioProviderSelection.make(template: "yuedu-edge-tts:missing", isDirectChapterAudio: false)
        }
        #expect(TTSPlaybackRouting.shouldUseHTTP(text: "你好", httpTemplate: template, useSystemVoice: false))
        #expect(!TTSPlaybackRouting.shouldUseHTTP(text: "你好", httpTemplate: template, useSystemVoice: true))
    }

    @Test @MainActor func voiceSelectionPersistsWithoutChangingImportedSources() throws {
        let gs = GlobalSettings.shared
        let previous = (gs.httpTtsUrlTemplate, gs.httpTtsHeaders, gs.ttsUseSystemVoice, gs.edgeTtsVoiceID)
        let sources = gs.importedTTSSources
        defer {
            gs.httpTtsUrlTemplate = previous.0
            gs.httpTtsHeaders = previous.1
            gs.ttsUseSystemVoice = previous.2
            gs.edgeTtsVoiceID = previous.3
        }
        let voice = try #require(EdgeTTSVoice.voice(id: "zh-CN-YunxiNeural"))
        gs.ttsUseSystemVoice = true
        gs.httpTtsHeaders = ["Authorization": "test"]
        gs.selectEdgeTTSVoice(voice)
        #expect(gs.usesEdgeTTS)
        #expect(gs.httpTtsHeaders.isEmpty)
        #expect(gs.selectedEdgeTTSVoice == voice)
        #expect(gs.importedTTSSources == sources)
        #expect(UserDefaults.standard.string(forKey: "yd_edge_tts_voice_id") == voice.id)
        #expect(UserDefaults.standard.string(forKey: "yd_http_tts_url_template") == voice.sourceIdentifier)
        gs.ttsUseSystemVoice = true
        #expect(!gs.usesEdgeTTS)
    }

    @Test func providerSendsCapturedVoiceAndRejectsEmptyAudio() async throws {
        let audio = Data([0xFF, 0xF3, 0x44, 0xC0] + Array(repeating: UInt8(0), count: 12))
        let transport = RecordingEdgeTransport(data: audio)
        let voice = try #require(EdgeTTSVoice.voice(id: "zh-CN-YunxiNeural"))
        let provider = EdgeTTSAudioProvider(voice: voice, transport: transport)
        #expect(try await provider.audioData(for: "你好<&", title: "private book", rate: 1) == audio)
        let sent = await transport.sent
        #expect(sent.count == 1)
        #expect(sent[0][1].contains("name='zh-CN-YunxiNeural'"))
        #expect(sent[0][1].contains("rate='+100%'"))
        #expect(!sent[0][1].contains("private book"))
        let emptyProvider = EdgeTTSAudioProvider(voice: voice, transport: RecordingEdgeTransport(data: Data()))
        await #expect(throws: EdgeTTSError.emptyAudio) {
            try await emptyProvider.audioData(for: "你好", title: "", rate: 0.5)
        }
        let invalidProvider = EdgeTTSAudioProvider(voice: voice, transport: RecordingEdgeTransport(data: Data("<html>service unavailable</html>".utf8)))
        await #expect(throws: EdgeTTSError.invalidResponse) {
            try await invalidProvider.audioData(for: "你好", title: "", rate: 0.5)
        }
    }

    @Test func cancellationStopsFurtherRequests() async throws {
        let transport = CancellingEdgeTransport()
        let provider = EdgeTTSAudioProvider(voice: .defaultVoice, transport: transport)
        await #expect(throws: CancellationError.self) {
            try await provider.audioData(for: String(repeating: "小說", count: 3000), title: "", rate: 0.5)
        }
        #expect(await transport.calls == 1)
    }

    @Test @MainActor func emptyEdgeResponseStopsPlaybackWithoutRetryOrSkipping() async {
        let gs = GlobalSettings.shared
        let previousTemplate = gs.httpTtsUrlTemplate
        defer { gs.httpTtsUrlTemplate = previousTemplate }
        gs.httpTtsUrlTemplate = EdgeTTSVoice.defaultVoice.sourceIdentifier
        let transport = RecordingEdgeTransport(data: Data())
        let engine = HTTPTTSEngine(audioProvider: EdgeTTSAudioProvider(voice: .defaultVoice, transport: transport))
        var skipped = false
        engine.onSegmentSkipped = { _ in skipped = true }
        let failed = await withCheckedContinuation { continuation in
            engine.onError = { _ in continuation.resume(returning: true) }
            engine.speak(text: "第一段測試。", title: "", rate: 0.5)
        }
        #expect(failed)
        #expect(!engine.isPlaying)
        #expect(!skipped)
        #expect(await transport.sent.count == 1)
        engine.stop()
    }

    @Test func cancellationAfterReceivingAudioDoesNotRequestAnotherChunk() async throws {
        let transport = SuspendedEdgeTransport()
        let provider = EdgeTTSAudioProvider(voice: .defaultVoice, transport: transport)
        let task = Task {
            try await provider.audioData(for: String(repeating: "小說", count: 3000), title: "", rate: 0.5)
        }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.calls == 1)
    }

    private static func frame(headers: String, payload: Data) -> Data {
        let bytes = Data(headers.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes + payload
    }
}

private actor RecordingEdgeTransport: EdgeTTSTransport {
    let data: Data
    var sent: [[String]] = []
    init(data: Data) { self.data = data }
    func synthesize(request: URLRequest, messages: [String]) async throws -> Data {
        sent.append(messages)
        return data
    }
}

private actor CancellingEdgeTransport: EdgeTTSTransport {
    var calls = 0
    func synthesize(request: URLRequest, messages: [String]) async throws -> Data {
        calls += 1
        throw CancellationError()
    }
}

private actor SuspendedEdgeTransport: EdgeTTSTransport {
    var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Data, Never>?

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func synthesize(request: URLRequest, messages: [String]) async throws -> Data {
        calls += 1
        return await withCheckedContinuation {
            response = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func finish() {
        response?.resume(returning: Data([0xFF, 0xF3, 0x44, 0xC0]))
        response = nil
    }
}
