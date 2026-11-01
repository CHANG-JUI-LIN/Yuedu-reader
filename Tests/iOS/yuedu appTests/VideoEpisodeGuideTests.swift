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

    private func stream(from content: String) throws -> URLRequest {
        guard case .stream(let request) = try DirectChapterVideoResolver.link(from: content) else {
            Issue.record("expected a stream: \(content)")
            return URLRequest(url: URL(string: "about:blank")!)
        }
        return request
    }

    @Test("a chapter's link may carry legado's header options")
    func linkWithHeaders() throws {
        let request = try stream(
            from: #"https://cdn.example.com/a/index.m3u8,{"headers":{"Referer":"https://example.com/"}}"#
        )
        #expect(request.url?.absoluteString == "https://cdn.example.com/a/index.m3u8")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://example.com/")
    }

    @Test("a link wrapped in the content pipeline's markup still plays")
    func wrappedLink() throws {
        let request = try stream(from: "<p>https://example.com/v.mp4</p>")
        #expect(request.url?.absoluteString == "https://example.com/v.mp4")
        let withHeaders = try stream(
            from: #"<p>https://example.com/v.m3u8?a=1&amp;b=2,{&quot;headers&quot;:{&quot;Referer&quot;:&quot;https://example.com/&quot;}}</p>"#
        )
        #expect(withHeaders.url?.absoluteString == "https://example.com/v.m3u8?a=1&b=2")
        #expect(withHeaders.value(forHTTPHeaderField: "Referer") == "https://example.com/")
    }

    @Test("a bare link's query is kept as it is")
    func bareLinkQueryUntouched() throws {
        let request = try stream(from: "https://example.com/v.mp4?id=3&lang=zh&copy=1")
        #expect(request.url?.absoluteString == "https://example.com/v.mp4?id=3&lang=zh&copy=1")
    }

    // A source written for a legado without a player opens a browser itself and returns this.
    @Test("a link inside a source's message is not taken as the stream")
    func linkInProseIsNotAStream() {
        #expect(throws: VideoChapterLinkError.self) {
            try DirectChapterVideoResolver.link(from: "【刷新正文】播放 ✅直链: https://example.com/v.mp4")
        }
    }

    @Test("DASH, as a manifest or a link, says so")
    func dashIsNamed() {
        #expect(throws: VideoChapterLinkError.dashManifest) {
            try DirectChapterVideoResolver.link(from: #"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash"></MPD>"#)
        }
        #expect(throws: VideoChapterLinkError.dashManifest) {
            try DirectChapterVideoResolver.link(from: "https://example.com/v/manifest.mpd")
        }
    }

    // 番茄四合一 / 七猫-OE: the content script opens the source's player page (`java.startBrowser`).
    @Test("a page the script opened for the episode is a page to sniff, keeping its options")
    func handedOverPageIsAPage() throws {
        let page = "http://example.com:8020/videoplayer?series_id=1&item_id=2&api_key=k"
        let content = DirectChapterVideoResolver.pageContent(page + #",{"headers":{"Referer":"http://example.com/"}}"#)
        guard case .page(let request) = try DirectChapterVideoResolver.link(from: content) else {
            Issue.record("expected a page: \(content)")
            return
        }
        #expect(request.url?.absoluteString == page)
        #expect(request.value(forHTTPHeaderField: "Referer") == "http://example.com/")
    }

    @Test("the handover prefers the script's stream to its page")
    func handoverPrefersStream() {
        let both = LegadoJSBridge.VideoEpisodeHandover(stream: "https://cdn.example.com/a.m3u8", page: "https://example.com/p")
        #expect(both.episodeContent == "https://cdn.example.com/a.m3u8")
        let page = LegadoJSBridge.VideoEpisodeHandover(stream: nil, page: "https://example.com/p")
        #expect(page.episodeContent == #"https://example.com/p,{"webView":true}"#)
        #expect(LegadoJSBridge.VideoEpisodeHandover().episodeContent == nil)
    }

    @Test("a stream request is told from the page and its API")
    func videoRequests() {
        let streams = [
            "https://cdn.example.com/hls/index.m3u8?sign=1",
            "https://cdn.example.com/v/1.MP4",
            "https://v26-default.example.com/abc/video/tos/cn/x/?a=1&mime_type=video_mp4&qs=0",
            "https://cdn.example.com/dash/manifest.mpd",
        ]
        for link in streams { #expect(DirectChapterVideoResolver.isVideoRequest(URL(string: link)!), "\(link)") }
        let pages = [
            "http://example.com:8020/videoplayer?series_id=1&item_id=2",
            "http://example.com:8020/api/video/detail?series_id=1",
            "https://example.com/api/playinfo?file=x",
            "blob:https://example.com/1234",
        ]
        for link in pages { #expect(!DirectChapterVideoResolver.isVideoRequest(URL(string: link)!), "\(link)") }
    }
}
