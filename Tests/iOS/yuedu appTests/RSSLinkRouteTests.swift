import Foundation
import Testing
@testable import yuedu_app

/// Crashlytics c43ca927 (2.0.7): `SFSafariViewController(url:)` raised
/// NSInvalidArgumentException for a non-http(s) link from RSS data. Every link the RSS
/// screens open goes through `RSSLinkRoute`; only `.inApp` reaches `SafariView`.
@Suite("RSS link routing")
struct RSSLinkRouteTests {
    private let base = URL(string: "https://example.com/blog/feed.xml")!

    private func inAppString(_ route: RSSLinkRoute) -> String? {
        if case .inApp(let webURL) = route { return webURL.url.absoluteString }
        return nil
    }

    private func systemString(_ route: RSSLinkRoute) -> String? {
        if case .system(let url) = route { return url.absoluteString }
        return nil
    }

    @Test("absolute http and https open in app unchanged")
    func absoluteWebLinks() {
        #expect(inAppString(.route("https://example.com/a?b=1", relativeTo: nil)) == "https://example.com/a?b=1")
        #expect(inAppString(.route("http://example.com/a", relativeTo: nil)) == "http://example.com/a")
        #expect(inAppString(.route("  https://example.com/a \n", relativeTo: nil)) == "https://example.com/a")
        #expect(inAppString(.route("HTTPS://example.com/a", relativeTo: nil)) == "https://example.com/a")
    }

    @Test("relative links resolve against the base")
    func relativeLinksResolve() {
        #expect(inAppString(.route("/2026/10/post.html", relativeTo: base)) == "https://example.com/2026/10/post.html")
        #expect(inAppString(.route("post.html", relativeTo: base)) == "https://example.com/blog/post.html")
        #expect(inAppString(.route("//cdn.example.org/x", relativeTo: base)) == "https://cdn.example.org/x")
    }

    @Test("relative links without a web base are unopenable")
    func relativeWithoutBase() {
        #expect(RSSLinkRoute.route("/2026/10/post.html", relativeTo: nil) == .unopenable)
        #expect(RSSLinkRoute.route("post.html", relativeTo: URL(string: "file:///tmp/feed.xml")) == .unopenable)
    }

    @Test("app schemes go to the system, including our own import schemes")
    func appSchemesGoToSystem() {
        #expect(systemString(.route("mailto:editor@example.com", relativeTo: base)) == "mailto:editor@example.com")
        #expect(systemString(.route("tel:+886212345678", relativeTo: base)) == "tel:+886212345678")
        #expect(systemString(.route("legado://import/rssSource?src=https://a.com/r.json", relativeTo: base)) != nil)
        #expect(systemString(.route("yuedu://module?src=https://a.com/m.json", relativeTo: base)) != nil)
        #expect(systemString(.route("feed://example.com/rss", relativeTo: base)) == "feed://example.com/rss")
    }

    @Test("script, inline and local schemes are unopenable")
    func unopenableSchemes() {
        #expect(RSSLinkRoute.route("javascript:void(0)", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("JavaScript:openArticle(3)", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("data:text/html,<p>x</p>", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("about:blank", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("file:///etc/hosts", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("", relativeTo: base) == .unopenable)
        #expect(RSSLinkRoute.route("   ", relativeTo: base) == .unopenable)
    }

    @Test("http without a host is not handed to Safari")
    func httpWithoutHost() {
        #expect(RSSLinkRoute.route("https:///path", relativeTo: nil) == .unopenable)
        #expect(InAppWebURL(URL(string: "mailto:a@b.c")!) == nil)
    }

    @Test("Legado option suffix is dropped and CJK paths are encoded")
    func legadoOptionsAndCJK() {
        #expect(inAppString(.route("https://x.com/a,{'webView':true}", relativeTo: nil)) == "https://x.com/a")
        let cjk = inAppString(.route("/文章/第一章.html", relativeTo: base))
        #expect(cjk == "https://example.com/%E6%96%87%E7%AB%A0/%E7%AC%AC%E4%B8%80%E7%AB%A0.html")
    }

    @Test("article links resolve against the homepage, then the feed URL")
    func sourceArticleLinkBase() {
        var source = RSSSource(name: "Blog", url: "https://example.com/blog/feed.xml", sortOrder: 0)
        #expect(source.articleLinkBaseURL?.absoluteString == "https://example.com/blog/feed.xml")

        source.homepageURL = "https://www.example.com/"
        #expect(inAppString(.route("p/1", relativeTo: source.articleLinkBaseURL)) == "https://www.example.com/p/1")

        source.homepageURL = "mailto:editor@example.com"
        #expect(source.articleLinkBaseURL?.absoluteString == "https://example.com/blog/feed.xml")
    }

    @Test("homepage route: relative homepages resolve, scripts hide the action")
    func sourceHomepageRoute() {
        var source = RSSSource(name: "Blog", url: "https://example.com/blog/feed.xml", sortOrder: 0)
        #expect(source.homepageLinkRoute == nil)

        source.homepageURL = "/about"
        #expect(source.homepageLinkRoute.flatMap(inAppString) == "https://example.com/about")

        source.homepageURL = "javascript:void(0)"
        #expect(source.homepageLinkRoute == .unopenable)

        source.homepageURL = "mailto:editor@example.com"
        #expect(source.homepageLinkRoute.flatMap(systemString) == "mailto:editor@example.com")
    }
}
