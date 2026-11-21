import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

/// FB-231: a long press at 3× played HLS episodes silent, the picture jumping between two frames.
/// Measured 2026-11-21 against an HLS clip with a tone, at 2× and 3×: above 2× AVFoundation
/// disables an HLS item's audio and video tracks and scans (6 frames in 3 s); an HLS playlist
/// with an I-frame playlist (`canPlayFastForward` true) scans its I-frames, still silent. The same
/// clip as an MP4 file plays 3× with sound at its full frame rate.
@Suite("Video playback rate")
struct VideoPlaybackRateTests {
    @Test("a streamed episode plays no faster than 2×")
    func streamedCapsAtTwo() {
        #expect(VideoPlaybackRate.playable(3, isStream: true) == 2)
        #expect(VideoPlaybackRate.playable(2, isStream: true) == 2)
        #expect(VideoPlaybackRate.playable(1.5, isStream: true) == 1.5)
        #expect(VideoPlaybackRate.playable(0.5, isStream: true) == 0.5)
    }

    @Test("a file plays every speed the menu offers")
    func fileKeepsThree() {
        #expect(VideoPlaybackRate.playable(3, isStream: false) == 3)
        #expect(VideoPlaybackRate.playable(VideoPlaybackRate.longPress, isStream: false) == 3)
    }

    @Test("an episode not yet known to be a file is held to 2×")
    func unknownIsHeld() {
        #expect(VideoPlaybackRate.playable(3, isStream: nil) == 2)
    }

    @Test("the menu offers what the episode can play")
    func menuRates() {
        #expect(VideoPlaybackRate.offered(isStream: true).max() == 2)
        #expect(VideoPlaybackRate.offered(isStream: false) == VideoPlaybackRate.menu)
    }

    @Test("an HLS playlist is a stream, an MP4 is not")
    func detectsStream() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)
        let referer = "https://v.example/play/1"
        let server = try VideoStillFixtureServer(directory: fixtures, referer: referer)
        let base = try await server.start()
        defer { server.stop() }
        let headers = ["Referer": referer]
        let playlist = HeaderedMediaAsset.make(url: base.appendingPathComponent("video-still-hls.m3u8"), headers: headers)
        let file = HeaderedMediaAsset.make(url: base.appendingPathComponent("video-still-landscape.mp4"), headers: headers)
        #expect(try await VideoPlaybackRate.isStream(playlist))
        #expect(try await !VideoPlaybackRate.isStream(file))
    }

    /// The player as the screen drives it: a long press on an HLS episode with sound. Past 2×
    /// AVFoundation disables the item's tracks — the silent scan the report describes — so the
    /// tracks staying enabled is the sound going on. The last step forces 3× on the same item to
    /// show the check would catch it.
    @Test("a long press on a stream keeps its sound")
    @MainActor
    func longPressKeepsSound() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)
        let referer = "https://v.example/play/1"
        let server = try VideoStillFixtureServer(directory: fixtures, referer: referer)
        let base = try await server.start()
        let controller = VideoPlaybackController(
            link: VideoStream(url: base.appendingPathComponent("video-rate-hls.m3u8"), headers: ["Referer": referer]),
            title: "FB-231"
        )
        defer { controller.close(); server.stop() }
        controller.start()
        try await until("ready: \(controller.phase), \(String(describing: controller.isStream))") {
            controller.phase == .playing && controller.isStream != nil
        }
        #expect(controller.isStream == true)

        controller.setLongPressing(true)
        #expect(controller.effectiveRate == 2)
        #expect(controller.player.rate == 2)
        try await Task.sleep(for: .seconds(1))
        let tracks = try #require(controller.player.currentItem?.tracks)
        #expect(tracks.contains { $0.assetTrack?.mediaType == .audio && $0.isEnabled }, "\(tracks.map(\.isEnabled))")

        await controller.player.seek(to: .zero)
        controller.player.rate = 3
        try await until("forced 3× disables the tracks: \(controller.player.currentItem?.tracks.map(\.isEnabled) ?? []), t=\(controller.player.currentTime().seconds), rate=\(controller.player.rate)") {
            controller.player.currentItem?.tracks.allSatisfy { !$0.isEnabled } == true
        }
    }

    @MainActor
    private func until(_ what: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out: \(what())")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
