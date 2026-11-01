import Foundation
import Testing
@testable import yuedu_app

/// `LegadoHeadlessWebView.sniffVideo`: a source's player page loads unseen and the video its
/// own script picks is what the app's player plays.
@MainActor
@Suite("Video page sniffing", .serialized)
struct VideoPageSnifferTests {
    private func page(_ html: String) -> URLRequest {
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URLRequest(url: URL(string: "data:text/html;charset=utf-8,\(encoded)")!)
    }

    private func sniff(_ html: String, timeout: TimeInterval = 10) async -> URL? {
        await LegadoHeadlessWebView.sniffVideo(
            page: page(html), userAgent: nil, timeout: timeout,
            isVideoRequest: DirectChapterVideoResolver.isVideoRequest
        )
    }

    @Test("a link the page's script hands its <video> is the video")
    func scriptSetsVideoSource() async {
        let found = await sniff("""
        <video id="v" playsinline></video>
        <script>
          Promise.resolve().then(() => {
            document.getElementById('v').src = 'https://cdn.example.com/drama/12.mp4?sign=a';
          });
        </script>
        """)
        #expect(found?.absoluteString == "https://cdn.example.com/drama/12.mp4?sign=a")
    }

    @Test("a <source> in the page's own markup is the video")
    func markupSource() async {
        let found = await sniff("""
        <video controls><source src="https://cdn.example.com/hls/index.m3u8" type="application/x-mpegURL"></video>
        """)
        #expect(found?.absoluteString == "https://cdn.example.com/hls/index.m3u8")
    }

    // A Media Source player hands its <video> a blob: and fetches the playlist itself.
    @Test("a playlist the page requests is the video; its blob: is not")
    func requestedPlaylist() async {
        let found = await sniff("""
        <video id="v"></video>
        <script>
          document.getElementById('v').src = 'blob:https://example.com/0000';
          const request = new XMLHttpRequest();
          request.open('GET', 'https://api.example.com/api/playinfo?id=1');
          request.open('GET', 'https://cdn.example.com/hls/master.m3u8?t=1');
        </script>
        """)
        #expect(found?.absoluteString == "https://cdn.example.com/hls/master.m3u8?t=1")
    }

    @Test("a page that hands its player nothing finds no video")
    func nothingFound() async {
        let found = await sniff("<p>這一集需要會員</p>", timeout: 2)
        #expect(found == nil)
    }
}
