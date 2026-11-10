import CoreMedia
import Foundation
import Testing
@testable import yuedu_app

/// FB-144: a swipe across the picture seeks, and the timeline seeks wherever the stream can.
@Suite("Video seeking")
@MainActor
struct VideoSeekTests {
    private func span(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    @Test("a known duration is the timeline")
    func knownDuration() {
        let timeline = VideoTimeline(duration: 60, seekable: [span(0, 60)])
        #expect(timeline.duration == 60)
        #expect(timeline.seekableRange == 0...60)
    }

    /// Measured: a 60 s HLS playlist without `#EXT-X-ENDLIST` reports duration NaN and seekable
    /// 0–30 s. It used to leave the timeline disabled.
    @Test("a playlist without an end seeks in its seekable ranges")
    func indefiniteDurationUsesSeekableRanges() {
        let timeline = VideoTimeline(duration: .nan, seekable: [span(0, 30)])
        #expect(timeline.duration == 0)
        #expect(timeline.seekableRange == 0...30)
    }

    @Test("a live stream with no window has nothing to seek")
    func liveWithoutWindow() {
        #expect(VideoTimeline(duration: .nan, seekable: []).seekableRange == nil)
        #expect(VideoTimeline(duration: .nan, seekable: [span(42, 42)]).seekableRange == nil)
    }

    @Test("several seekable ranges make one span")
    func rangesUnion() {
        let timeline = VideoTimeline(duration: .infinity, seekable: [span(100, 130), span(10, 40)])
        #expect(timeline.seekableRange == 10...130)
    }

    @Test("a swipe across spans a short video whole, a mid one two minutes, a long one a tenth")
    func secondsPerWidthScalesWithLength() {
        #expect(VideoPan.secondsPerWidth(span: 90) == 90)
        #expect(VideoPan.secondsPerWidth(span: 600) == 120)
        #expect(VideoPan.secondsPerWidth(span: 2700) == 270)
        #expect(VideoPan.secondsPerWidth(span: 0) == 120)
    }

    @Test("a swipe's target scales with the width and stays inside the range")
    func seekTime() {
        // Half the width of a 45-minute episode: 135 s on.
        #expect(VideoPan.seekTime(origin: 600, translation: 200, width: 400, in: 0...2700) == 735)
        #expect(VideoPan.seekTime(origin: 600, translation: -200, width: 400, in: 0...2700) == 465)
        #expect(VideoPan.seekTime(origin: 10, translation: -400, width: 400, in: 0...2700) == 0)
        #expect(VideoPan.seekTime(origin: 80, translation: 400, width: 400, in: 0...90) == 90)
        #expect(VideoPan.seekTime(origin: 20, translation: -400, width: 400, in: 15...45) == 15)
    }

    /// Measured on the simulator: playing at 0:47 of a playlist without an end, seekable 0–0:30.
    @Test("a swipe from past the seekable window moves from its edge")
    func seekTimeFromOutsideRange() {
        #expect(VideoPan.seekTime(origin: 47, translation: -200, width: 400, in: 0...30) == 15)
        #expect(VideoPan.seekTime(origin: 47, translation: 0, width: 400, in: 0...30) == 30)
    }

    @Test("a swipe across decides by its dominant axis")
    func panAxis() {
        let size = CGSize(width: 900, height: 400)
        let middle = CGPoint(x: 450, y: 200)
        #expect(VideoPanKind(start: middle, translation: CGSize(width: 30, height: 10), in: size) == .seek)
        #expect(VideoPanKind(start: middle, translation: CGSize(width: -30, height: 20), in: size) == .seek)
        #expect(VideoPanKind(start: middle, translation: CGSize(width: 5, height: -30), in: size) == .episodes)
    }

    @Test("the badge's delta is signed")
    func deltaFormat() {
        #expect(VideoPlayerFormat.delta(65) == "+1:05")
        #expect(VideoPlayerFormat.delta(-30) == "−0:30")
    }
}
