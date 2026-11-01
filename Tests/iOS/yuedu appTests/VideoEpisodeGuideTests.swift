import Foundation
import Testing
@testable import yuedu_app

@Suite("Video episodes and links")
struct VideoEpisodeGuideTests {
    private func chapter(_ title: String, volume: Bool = false) -> OnlineChapterRef {
        OnlineChapterRef(index: 0, title: title, url: volume ? "" : "https://example.com/\(title).m3u8",
                         isVolume: volume)
    }

    /// 稀饭影视's shape: 線路 rows, each followed by its episodes.
    private var twoRoutes: [OnlineChapterRef] {
        [chapter("線路一", volume: true), chapter("1"), chapter("2"),
         chapter("線路二", volume: true), chapter("1"), chapter("2"), chapter("3")]
    }

    @Test("volume rows start 線路 and the chapters under them are its episodes")
    func routesFromVolumes() {
        let guide = VideoEpisodeGuide(chapters: twoRoutes)
        #expect(guide.routes.map(\.title) == ["線路一", "線路二"])
        #expect(guide.routes.map(\.episodes) == [[1, 2], [4, 5, 6]])
        #expect(guide.episodeNumber(of: 5) == 2)
    }

    @Test("a list with no volumes is one unnamed 線路")
    func noVolumes() {
        let guide = VideoEpisodeGuide(chapters: [chapter("1"), chapter("2")])
        #expect(guide.routes.count == 1)
        #expect(guide.routes[0].title == nil)
        #expect(guide.firstEpisode == 0)
    }

    @Test("a volume with nothing under it is no 線路")
    func emptyVolumeSkipped() {
        let guide = VideoEpisodeGuide(chapters: [chapter("空", volume: true), chapter("線路", volume: true), chapter("1")])
        #expect(guide.routes.map(\.title) == ["線路"])
        #expect(guide.routes[0].id == 0)
    }

    // Maintainer, 2026-11-01: the last episode of a 線路 goes on into the next 線路's first.
    @Test("the next episode crosses into the next 線路 and stops after the last")
    func nextCrossesRoutes() {
        let guide = VideoEpisodeGuide(chapters: twoRoutes)
        #expect(guide.episode(after: 1) == 2)
        #expect(guide.episode(after: 2) == 4)
        #expect(guide.episode(after: 6) == nil)
        #expect(guide.episode(before: 4) == 2)
        #expect(guide.episode(before: 1) == nil)
    }

    @Test("a saved place that is no longer an episode resumes at the first")
    func resumeFallsBackToFirst() {
        let guide = VideoEpisodeGuide(chapters: twoRoutes)
        #expect(guide.resumeEpisode(saved: 5) == 5)
        #expect(guide.resumeEpisode(saved: 3) == 1)
        #expect(guide.resumeEpisode(saved: 40) == 1)
    }

    @Test("a chapter's link may carry legado's header options")
    func linkWithHeaders() throws {
        let request = try DirectChapterVideoResolver.request(
            from: #"https://cdn.example.com/a/index.m3u8,{"headers":{"Referer":"https://example.com/"}}"#
        )
        #expect(request.url?.absoluteString == "https://cdn.example.com/a/index.m3u8")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://example.com/")
    }

    @Test("a link wrapped in the content pipeline's markup still plays")
    func wrappedLink() throws {
        let request = try DirectChapterVideoResolver.request(from: "<p>https://example.com/v.mp4</p>")
        #expect(request.url?.absoluteString == "https://example.com/v.mp4")
        let withHeaders = try DirectChapterVideoResolver.request(
            from: #"<p>https://example.com/v.m3u8?a=1&amp;b=2,{&quot;headers&quot;:{&quot;Referer&quot;:&quot;https://example.com/&quot;}}</p>"#
        )
        #expect(withHeaders.url?.absoluteString == "https://example.com/v.m3u8?a=1&b=2")
        #expect(withHeaders.value(forHTTPHeaderField: "Referer") == "https://example.com/")
    }

    @Test("a bare link's query is kept as it is")
    func bareLinkQueryUntouched() throws {
        let request = try DirectChapterVideoResolver.request(from: "https://example.com/v.mp4?id=3&lang=zh&copy=1")
        #expect(request.url?.absoluteString == "https://example.com/v.mp4?id=3&lang=zh&copy=1")
    }

    // A source written for a legado without a player opens a browser itself and returns this.
    @Test("a link inside a source's message is not taken as the stream")
    func linkInProseIsNotAStream() {
        #expect(throws: VideoChapterLinkError.self) {
            try DirectChapterVideoResolver.request(from: "【刷新正文】播放 ✅直链: https://example.com/v.mp4")
        }
    }

    @Test("DASH, as a manifest or a link, says so")
    func dashIsNamed() {
        #expect(throws: VideoChapterLinkError.dashManifest) {
            try DirectChapterVideoResolver.request(from: #"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash"></MPD>"#)
        }
        #expect(throws: VideoChapterLinkError.dashManifest) {
            try DirectChapterVideoResolver.request(from: "https://example.com/v/manifest.mpd")
        }
    }
}
