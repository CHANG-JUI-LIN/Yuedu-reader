import Foundation
import XCTest
@testable import yuedu_app

@MainActor
final class HTTPTTSQueueTests: XCTestCase {
    func testFailedSegmentPausesAndResumeRequestsTheSameText() async {
        await assertFailurePreservesSegment(TTSAudioProviderError.emptyData)
    }

    func testProviderCancellationDoesNotLeavePlaybackWaitingForever() async {
        await assertFailurePreservesSegment(URLError(.cancelled))
    }

    private func assertFailurePreservesSegment(_ error: Error) async {
        let settings = GlobalSettings.shared
        let oldTemplate = settings.httpTtsUrlTemplate
        settings.httpTtsUrlTemplate = "https://example.invalid/{{text}}"
        defer { settings.httpTtsUrlTemplate = oldTemplate }

        let provider = QueueProbeProvider(failure: error)
        let engine = HTTPTTSEngine(audioProvider: provider)
        defer { engine.stop() }
        var segments: [Int] = []
        var skipped = false
        var stopped = false
        engine.onSegmentChanged = { segments.append($0.index) }
        engine.onSegmentSkipped = { _ in skipped = true }
        engine.onStop = { stopped = true }
        let failed = expectation(description: "Current segment failed")
        engine.onError = { error in
            guard case .chunkUnavailable(index: 0, underlying: _) = error as? TTSPlaybackError else {
                XCTFail("Failure must retain the first paragraph")
                failed.fulfill()
                return
            }
            failed.fulfill()
        }
        engine.speak(text: "第一段。\n第二段。\n第三段。", title: "", rate: 0.5)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(skipped)
        XCTAssertFalse(stopped)
        XCTAssertEqual(Set(segments), [0])

        let failedAgain = expectation(description: "Resume retries the same paragraph")
        engine.onError = { _ in failedAgain.fulfill() }
        engine.resume()
        await fulfillment(of: [failedAgain], timeout: 5)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0 == "第一段。" }.count, 2)
        XCTAssertEqual(Set(segments), [0])
        XCTAssertFalse(skipped)
        XCTAssertFalse(stopped)
    }

    func testPrefetchStaysWithinThreeSegmentsOfPlayback() async {
        let settings = GlobalSettings.shared
        let oldTemplate = settings.httpTtsUrlTemplate
        let oldConcurrency = settings.ttsPreSynthesisConcurrency
        settings.ttsPreSynthesisConcurrency = 2
        settings.httpTtsUrlTemplate = "https://example.invalid/{{text}}"
        defer {
            settings.httpTtsUrlTemplate = oldTemplate
            settings.ttsPreSynthesisConcurrency = oldConcurrency
        }

        let windowFilled = expectation(description: "Third lookahead segment requested")
        let escapedWindow = expectation(description: "Must not recursively synthesize the chapter")
        escapedWindow.isInverted = true
        let provider = QueueProbeProvider { text in
            if text == "段落3。" { windowFilled.fulfill() }
            if ["段落4。", "段落5。", "段落6。"].contains(text) { escapedWindow.fulfill() }
        }
        let engine = HTTPTTSEngine(audioProvider: provider)
        defer { engine.stop() }
        engine.speak(text: (0...6).map { "段落\($0)。" }.joined(separator: "\n"), title: "", rate: 0.5)
        await fulfillment(of: [windowFilled], timeout: 5)
        // Observe absence of additional requests after all lookahead completions. This is
        // an inverted assertion, not a delay used to make production state settle.
        await fulfillment(of: [escapedWindow], timeout: 0.3)
        let requests = await provider.requests
        XCTAssertEqual(Set(requests), Set((0...3).map { "段落\($0)。" }))
        XCTAssertEqual(requests.count, 4)
    }

    func testConfiguredConcurrencyControlsRequestsAndPersists() async {
        let settings = GlobalSettings.shared
        let oldTemplate = settings.httpTtsUrlTemplate
        let oldConcurrency = settings.ttsPreSynthesisConcurrency
        settings.httpTtsUrlTemplate = "https://example.invalid/{{text}}"
        defer {
            settings.httpTtsUrlTemplate = oldTemplate
            settings.ttsPreSynthesisConcurrency = oldConcurrency
        }

        for limit in [1, 2, 8] {
            let filled = expectation(description: "Use all \(limit) slots")
            filled.expectedFulfillmentCount = limit
            let exceeded = expectation(description: "Stay within \(limit) slots")
            exceeded.isInverted = true
            let expectedTexts = Set((0..<limit).map { "段落\($0)。" })
            let provider = QueueProbeProvider(holdAll: true) { text in
                if expectedTexts.contains(text) { filled.fulfill() }
                else { exceeded.fulfill() }
            }
            let engine = HTTPTTSEngine(audioProvider: provider)
            settings.ttsPreSynthesisConcurrency = limit
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "yd_tts_pre_synthesis_concurrency"), limit)
            engine.speak(text: (0...10).map { "段落\($0)。" }.joined(separator: "\n"), title: "", rate: 0.5)
            await fulfillment(of: [filled], timeout: 5)
            await fulfillment(of: [exceeded], timeout: 0.2)
            let requests = await provider.requests
            XCTAssertEqual(Set(requests), expectedTexts)
            XCTAssertEqual(requests.count, limit)
            engine.stop()
        }

        settings.ttsPreSynthesisConcurrency = 0
        XCTAssertEqual(settings.ttsPreSynthesisConcurrency, 1)
        settings.ttsPreSynthesisConcurrency = 100
        XCTAssertEqual(settings.ttsPreSynthesisConcurrency, 8)
    }
}

private actor QueueProbeProvider: TTSAudioProvider {
    nonisolated let displayName = "Queue probe"
    private let failure: Error?
    private let holdAll: Bool
    private let onRequest: @Sendable (String) -> Void
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private(set) var requests: [String] = []

    init(failure: Error? = nil, holdAll: Bool = false, onRequest: @escaping @Sendable (String) -> Void = { _ in }) {
        self.failure = failure
        self.holdAll = holdAll
        self.onRequest = onRequest
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        requests.append(text)
        onRequest(text)
        if let failure { throw failure }
        // Hold the audible request so preloads complete without starting an audio graph.
        guard holdAll || text == "段落0。" else { return Data([0]) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
