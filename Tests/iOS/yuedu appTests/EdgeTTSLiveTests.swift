import Combine
import XCTest
@testable import yuedu_app

/// Opt-in network smoke test for the consumer service. Set YUEDU_EDGE_TTS_LIVE=1
/// in the test runner's EnvironmentVariables to verify the real iOS playback path.
final class EdgeTTSLiveTests: XCTestCase {
    @MainActor
    func testMicrosoftPlaybackPauseResumeAndStop() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YUEDU_EDGE_TTS_LIVE"] == "1",
                          "Requires an explicit live Microsoft service check")
        let gs = GlobalSettings.shared
        let previous = (gs.httpTtsUrlTemplate, gs.httpTtsHeaders, gs.ttsUseSystemVoice, gs.edgeTtsVoiceID)
        let coordinator = TTSCoordinator()
        defer {
            coordinator.stop(reason: "finished live Edge test")
            gs.httpTtsUrlTemplate = previous.0
            gs.httpTtsHeaders = previous.1
            gs.ttsUseSystemVoice = previous.2
            gs.edgeTtsVoiceID = previous.3
        }
        gs.selectEdgeTTSVoice(.defaultVoice)
        coordinator.speechRate = 0.5
        XCTAssertFalse(coordinator.hasAudiblePlaybackStarted)
        let started = expectation(description: "Microsoft audio actually starts")
        let playback = coordinator.$hasAudiblePlaybackStarted.filter { $0 }.first().sink { _ in
            started.fulfill()
        }
        let error = coordinator.$errorMessage.compactMap { $0 }.first().sink { message in
            XCTFail(message)
            started.fulfill()
        }
        defer { playback.cancel(); error.cancel() }
        coordinator.speak(text: "你好，這是閱讀器內建的微軟語音。我們正在測試暫停、繼續和停止朗讀。", title: "Edge TTS live test")
        await fulfillment(of: [started], timeout: 45)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.hasAudiblePlaybackStarted)
        coordinator.pause()
        XCTAssertEqual(coordinator.playbackState, .paused)
        coordinator.resume()
        XCTAssertEqual(coordinator.playbackState, .playing)
        coordinator.stop(reason: "verify live Edge stop")
        XCTAssertEqual(coordinator.playbackState, .stopped)
        XCTAssertFalse(coordinator.hasAudiblePlaybackStarted)
    }
}
