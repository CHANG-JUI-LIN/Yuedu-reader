import Foundation
import Testing
@testable import yuedu_app

/// A `webView` request with the content rule's `sourceRegex` (and `java.webViewGetSource`):
/// Legado's `BackstageWebView.SnifferWebClient` (legado-E `BackstageWebView.kt` 304–376)
/// answers the first resource the page loads whose URL matches the regex whole
/// (`onLoadResource` → `resUrl.matches(regex)`), whenever the page loads it. A page that
/// finishes, or a navigation that fails, ends nothing: with no match it raises
/// `getStrResponse`'s `withTimeout` at the deadline.
///
/// Until 11-09 the sniffer answered once, at the first finished load, and any failed
/// navigation ended it: 蜻蜓FM's program page (YCK1329, YCK1330) hands its player the audio
/// from script and sends itself to the app's own scheme, and its chapters failed with
/// 「不支援的URL」 or matched nothing.
@MainActor
@Suite("WebView resource sniffing", .serialized)
struct WebViewResourceSniffTests {
    private static let audioRegex = #".*\.(mp3|m4a).*"#

    private func sniff(
        _ html: String, js: String? = nil, regex: String = audioRegex, timeout: TimeInterval = 10
    ) async -> (body: String, failure: LegadoHeadlessWebView.Failure?) {
        let page = await LegadoHeadlessWebView.load(
            html: html, url: "https://sniff.test/vchannels/1/programs/2/", js: js,
            userAgent: nil, timeout: timeout, sourceRegex: regex
        )
        return (page.body, page.failure)
    }

    @Test("a link the page's script hands its <audio> after the page loaded is the answer")
    func audioSourceAfterLoad() async {
        let page = await sniff("""
        <audio id="a"></audio>
        <script>
          window.addEventListener('load', () => setTimeout(() => {
            document.getElementById('a').src = 'https://cdn.example.com/a/1.m4a?x=1';
          }, 300));
        </script>
        """)
        #expect(page.failure == nil)
        #expect(page.body == "https://cdn.example.com/a/1.m4a?x=1")
    }

    @Test("a link handed to `new Audio(...)` is the answer")
    func audioConstructor() async {
        let page = await sniff("""
        <script>
          window.addEventListener('load', () => setTimeout(() => {
            window.player = new Audio('https://cdn.example.com/b/2.mp3');
          }, 300));
        </script>
        """)
        #expect(page.failure == nil)
        #expect(page.body == "https://cdn.example.com/b/2.mp3")
    }

    @Test("a page that sends itself to an app's scheme is still listened to")
    func appSchemeNavigationListensOn() async {
        let page = await sniff("""
        <audio id="a"></audio>
        <script>
          window.addEventListener('load', () => {
            location.href = 'yuedusnifftest://open?id=2';
            setTimeout(() => { document.getElementById('a').src = 'https://cdn.example.com/c/3.m4a'; }, 500);
          });
        </script>
        """)
        #expect(page.failure == nil)
        #expect(page.body == "https://cdn.example.com/c/3.m4a")
    }

    @Test("the source's script runs after the page loads, and what it hands the player is the answer")
    func sourceScriptHandsTheLink() async {
        let page = await sniff(
            #"<audio id="a"></audio>"#,
            js: "document.getElementById('a').src = 'https://cdn.example.com/d/4.m4a'"
        )
        #expect(page.failure == nil)
        #expect(page.body == "https://cdn.example.com/d/4.m4a")
    }

    // `resUrl.matches(regex)` is Kotlin's whole-string match: a query after `.mp3` misses `.*\.mp3`.
    @Test("a link the regex does not match whole is not the answer: the deadline is")
    func nothingMatchesUntilTheDeadline() async {
        let page = await sniff("""
        <audio id="a" src="https://cdn.example.com/e/5.mp3?sign=1"></audio>
        """, regex: #".*\.mp3"#, timeout: 2)
        #expect(page.failure == .timedOut(milliseconds: 2000))
        #expect(page.body == "")
    }
}
