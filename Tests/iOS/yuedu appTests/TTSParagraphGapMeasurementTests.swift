import AVFoundation
import Foundation
import XCTest
@testable import yuedu_app

/// Opt-in: plays real audio through each engine reachable without a user's credentials and
/// prints the `tts.gap` of every paragraph boundary (FB-23). Set YUEDU_TTS_GAP_MEASURE=1 in the
/// runner's environment (`TEST_RUNNER_YUEDU_TTS_GAP_MEASURE=1` on the xcodebuild line); the
/// Edge case also needs the network.
@MainActor
final class TTSParagraphGapMeasurementTests: XCTestCase {
    private static let paragraphs = [
        "第一段。天色漸暗，城門外的風吹得很急。",
        "第二段。他把燈點上，翻開那本舊書。",
        "第三段。書頁之間夾著一張發黃的信紙。",
        "第四段。信上只寫了一句話，字跡已經模糊。",
        "第五段。他看了很久，終於把信收進懷裡。",
    ]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YUEDU_TTS_GAP_MEASURE"] == "1",
                          "Measurement run only")
    }

    func testSystemVoiceGaps() async throws {
        let engine = SystemTTSEngine()
        defer { engine.stop() }
        let gaps = try await run(engine, timeout: 90) { $0.gapTrace.gaps }
        report("system", gaps)
    }

    /// What the synthesizer itself puts before and after each paragraph's speech.
    func testSystemVoiceBakedSilence() async throws {
        for text in Self.paragraphs.prefix(3) {
            let utterance = SystemTTSEngine.makeUtterance(text: text, rate: 0.5, pronunciationHints: [])
            utterance.voice = SystemTTSEngine.preferredVoice(for: text)
            let synthesizer = AVSpeechSynthesizer()
            let (samples, sampleRate): ([Float], Double) = await withCheckedContinuation { continuation in
                var collected: [Float] = []
                var sampleRate = 22_050.0
                var done = false
                synthesizer.write(utterance) { buffer in
                    guard !done else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        done = true
                        continuation.resume(returning: (collected, sampleRate))
                        return
                    }
                    sampleRate = pcm.format.sampleRate
                    if let floats = pcm.floatChannelData {
                        collected.append(contentsOf: UnsafeBufferPointer(start: floats[0], count: Int(pcm.frameLength)))
                    } else if let ints = pcm.int16ChannelData {
                        collected.append(contentsOf: UnsafeBufferPointer(start: ints[0], count: Int(pcm.frameLength)).map { Float($0) / 32_768 })
                    }
                }
            }
            let (lead, trail, total) = Self.silence(samples, rate: sampleRate)
            print("⏱ FB23 system clip total=\(Int(total))ms leadingSilence=\(Int(lead))ms trailingSilence=\(Int(trail))ms voice=\(utterance.voice?.identifier ?? "nil")")
            withExtendedLifetime(synthesizer) {}
        }
    }

    /// Two formats alternate, so nothing can be queued: every boundary loads at the boundary,
    /// the only path build 131 had.
    func testHTTPLoadAtBoundary() async throws {
        try await withHTTPTemplate {
            let engine = HTTPTTSEngine(audioProvider: ToneProvider(latencyMs: 300, alternateFormats: true))
            defer { engine.stop() }
            let gaps = try await run(engine, timeout: 120) { $0.gapTrace.gaps }
            report("http-load-at-boundary", gaps)
        }
    }

    func testHTTPSourceGapsFastServer() async throws {
        try await measureHTTP(latencyMs: 300, label: "http-fixture-300ms")
    }

    /// A source slower to answer than a paragraph lasts: the preload cannot stay ahead.
    func testHTTPSourceGapsSlowServer() async throws {
        try await measureHTTP(latencyMs: 2_500, label: "http-fixture-2500ms")
    }

    func testEdgeGapsAndBakedSilence() async throws {
        let provider = EdgeTTSAudioProvider(voice: EdgeTTSVoice.voice(id: "zh-CN-XiaoxiaoNeural") ?? .defaultVoice)
        for text in Self.paragraphs.prefix(2) {
            let data = try await provider.audioData(for: text, title: "", rate: 0.5)
            let (lead, trail, total) = try Self.edgeSilence(data)
            print("⏱ FB23 edge clip total=\(Int(total))ms leadingSilence=\(Int(lead))ms trailingSilence=\(Int(trail))ms")
        }
        try await withHTTPTemplate {
            let engine = HTTPTTSEngine(audioProvider: provider)
            defer { engine.stop() }
            let gaps = try await run(engine, timeout: 120) { $0.gapTrace.gaps }
            report("edge", gaps)
        }
    }

    // MARK: - Helpers

    private func measureHTTP(latencyMs: Int, label: String) async throws {
        try await withHTTPTemplate {
            let engine = HTTPTTSEngine(audioProvider: ToneProvider(latencyMs: latencyMs))
            defer { engine.stop() }
            let gaps = try await run(engine, timeout: 120) { $0.gapTrace.gaps }
            report(label, gaps)
        }
    }

    private func withHTTPTemplate(_ body: () async throws -> Void) async throws {
        let settings = GlobalSettings.shared
        let oldTemplate = settings.httpTtsUrlTemplate
        settings.httpTtsUrlTemplate = "https://example.invalid/{{text}}"
        defer { settings.httpTtsUrlTemplate = oldTemplate }
        try await body()
    }

    private func run<E: TTSPlayable>(
        _ engine: E,
        timeout: TimeInterval,
        gaps: @escaping (E) -> [TTSParagraphGapTrace.Gap]
    ) async throws -> [TTSParagraphGapTrace.Gap] {
        let finished = expectation(description: "unit finished")
        var collected: [TTSParagraphGapTrace.Gap] = []
        engine.onPageFinished = {
            collected = gaps(engine)
            finished.fulfill()
            return .finished
        }
        engine.onError = { XCTFail("engine error \($0)") }
        engine.speak(
            text: Self.paragraphs.joined(separator: "\n"),
            title: "",
            rate: 0.5,
            pronunciationHints: [],
            speakerAttributions: nil
        )
        await fulfillment(of: [finished], timeout: timeout)
        return collected
    }

    private func report(_ label: String, _ gaps: [TTSParagraphGapTrace.Gap]) {
        let values = gaps.map(\.ms)
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let detail = gaps.map { "#\($0.index)=\(Int($0.ms.rounded()))ms(\($0.next))" }.joined(separator: " ")
        print("⏱ FB23 \(label) boundaries=\(gaps.count) mean=\(Int(mean.rounded()))ms max=\(Int((values.max() ?? 0).rounded()))ms \(detail)")
        XCTAssertEqual(gaps.count, Self.paragraphs.count - 1)
    }

    /// Leading and trailing near-silence of a decoded clip, in ms: padding the server bakes
    /// into each clip, which a finish-to-start span cannot see.
    private static func edgeSilence(_ data: Data) throws -> (Double, Double, Double) {
        let decoder = try TTSChunkDecoder(data: data)
        let rate = decoder.processingFormat.sampleRate
        var samples: [Float] = []
        while let buffer = try decoder.read(frameCapacity: 8_192), buffer.frameLength > 0 {
            let channel = buffer.floatChannelData![0]
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return silence(samples, rate: rate)
    }

    private static func silence(_ samples: [Float], rate: Double) -> (Double, Double, Double) {
        let threshold: Float = 0.01   // -40 dBFS
        let first = samples.firstIndex { abs($0) > threshold } ?? samples.count
        let last = samples.lastIndex { abs($0) > threshold } ?? 0
        return (
            Double(first) / rate * 1000,
            Double(samples.count - 1 - last) / rate * 1000,
            Double(samples.count) / rate * 1000
        )
    }
}

/// An HTTP voice source answering after `latencyMs` with 1.5 s of tone, in place of a local
/// fixture server: the engine path from the provider's answer onward is the same.
private final class ToneProvider: TTSAudioProvider, Sendable {
    let displayName = "Tone fixture"
    let latencyMs: Int
    let alternateFormats: Bool
    init(latencyMs: Int, alternateFormats: Bool = false) {
        self.latencyMs = latencyMs
        self.alternateFormats = alternateFormats
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        try await Task.sleep(nanoseconds: UInt64(latencyMs) * 1_000_000)
        let odd = text.hasPrefix("第二") || text.hasPrefix("第四")
        let sampleRate = alternateFormats && odd ? 22_050 : 24_000
        let samples = (0..<Int(Double(sampleRate) * 1.5)).map {
            Int16(6_000 * sin(2 * Double.pi * 330 * Double($0) / Double(sampleRate)))
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + size); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(size)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return data
    }
}
