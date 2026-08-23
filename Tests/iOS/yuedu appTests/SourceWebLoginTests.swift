import Foundation
import Testing
@testable import yuedu_app

/// The WebView cookie login used to be reachable only from book sources, so a voice source that
/// signs in on a web page had no way in. 纳米AI TTS declares `loginUrl: "https://bot.n.cn/"` and
/// says so in its own 使用说明 — 「阅读 2.0.4 是否能从 TTS 页面弹出网页由 App 运行时决定」 — which
/// left 手动填 Cookie as the only route. `SourceWebLogin` is the three values that login needs, so
/// both kinds of source feed one screen.
@Suite("Source web login")
struct SourceWebLoginTests {

    // MARK: - Voice sources

    @Test("a voice source with a plain login page gets a web login")
    func plainLoginURLIsOffered() throws {
        let source = ImportedTTSSource(
            name: "纳米AI TTS",
            urlTemplate: "@js:'https://bot.n.cn/api/tts/v1'",
            sourceID: "tts-nano",
            loginUrl: "https://bot.n.cn/"
        )
        let login = try #require(SourceWebLogin(ttsSource: source))
        #expect(login.url.absoluteString == "https://bot.n.cn/")
        #expect(login.name == "纳米AI TTS")
        // The cookie has to land under the key every synthesis request reads its header from.
        #expect(login.storageKey == source.id)
    }

    @Test("a voice source without a login page gets no web login")
    func noLoginURLMeansNoEntry() {
        let source = ImportedTTSSource(
            name: "小米MiMo TTS",
            urlTemplate: "@js:'https://api.xiaomimimo.com/v1/chat/completions'",
            sourceID: "tts-mimo"
        )
        #expect(SourceWebLogin(ttsSource: source) == nil)
    }

    /// A `@js:` loginUrl is a login *procedure* — `TTSSourceLoginView` evaluates it. Scraping a
    /// URL out of it and opening that too would run the login by two routes at once.
    @Test("a script loginUrl is not turned into a page")
    func scriptLoginURLIsNotAPage() {
        for script in [
            "@js:java.webView('https://example.com/login')",
            "<js>login()</js>",
            #"{"url":"https://example.com/login","method":"POST"}"#
        ] {
            let source = ImportedTTSSource(
                name: "腳本登入",
                urlTemplate: "@js:'https://example.com/tts'",
                sourceID: "tts-script",
                loginUrl: script
            )
            #expect(SourceWebLogin(ttsSource: source) == nil, "\(script) must not open a page")
        }
    }

    @Test("a non-web loginUrl is refused")
    func nonWebSchemeIsRefused() {
        for raw in ["ftp://example.com/", "example.com/login", "", "   "] {
            let source = ImportedTTSSource(
                name: "怪 URL",
                urlTemplate: "@js:'https://example.com/tts'",
                sourceID: "tts-odd",
                loginUrl: raw
            )
            #expect(SourceWebLogin(ttsSource: source) == nil, "\(raw) must not open a page")
        }
    }

    // MARK: - Book sources keep their existing resolution

    @Test("a book source's plain loginUrl still wins")
    func bookSourcePlainLoginURL() throws {
        var source = BookSource()
        source.bookSourceName = "起点"
        source.bookSourceUrl = "https://www.qidian.com"
        source.loginUrl = "https://www.qidian.com/sign/"
        let login = try #require(SourceWebLogin(bookSource: source))
        #expect(login.url.absoluteString == "https://www.qidian.com/sign/")
        #expect(login.storageKey == "https://www.qidian.com")
    }

    @Test("a book source's @js loginUrl still yields the URL written inside it")
    func bookSourceScriptLoginURL() throws {
        var source = BookSource()
        source.bookSourceName = "源"
        source.bookSourceUrl = "https://example.com"
        source.loginUrl = #"@js: java.webView("https://example.com/user/login")"#
        let login = try #require(SourceWebLogin(bookSource: source))
        #expect(login.url.absoluteString == "https://example.com/user/login")
    }

    /// Unlike a voice source, a book source has a site to fall back on — that is where a sign-in
    /// link lives — so an empty loginUrl still opens something.
    @Test("a book source with no loginUrl falls back to the site")
    func bookSourceFallsBackToSite() throws {
        var source = BookSource()
        source.bookSourceName = "源"
        source.bookSourceUrl = "https://example.com"
        source.loginUrl = ""
        let login = try #require(SourceWebLogin(bookSource: source))
        #expect(login.url.absoluteString == "https://example.com")
    }

    @Test("an unnamed book source still gets a usable title")
    func unnamedBookSourceGetsATitle() throws {
        var source = BookSource()
        source.bookSourceName = ""
        source.bookSourceUrl = "https://example.com"
        let login = try #require(SourceWebLogin(bookSource: source))
        #expect(!login.name.isEmpty)
    }
}
