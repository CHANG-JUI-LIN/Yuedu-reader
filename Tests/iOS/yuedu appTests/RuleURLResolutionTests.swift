import Foundation
import Testing
@testable import yuedu_app

/// An `isUrl` rule result resolved the way Legado's `NetworkUtils.getAbsoluteURL` resolves it
/// (legado-E, MD3 and Sigma agree): absolute and data URLs as they are, a `javascript…` link
/// as nothing, anything else joined to the page by Java's `URL(base, spec)`.
///
/// Java's `URL` leaves a relative link's `,{…}` options where they are, so AnalyzeUrl still
/// finds them. `URL(string:relativeTo:)` percent-encodes them into the path, and a chapter,
/// next-content or next-TOC page written as `/p2,{"method":"POST"}` was fetched as a GET of
/// a path that does not exist.
@Suite("Rule URL resolution")
struct RuleURLResolutionTests {

    private static let base = "https://h.yuedu.test/book/1/index.html"

    /// Each link sits in `data-url` as well as `href`. The CSS extractor joins an `href` to
    /// the page itself before the engine sees it; `data-url` reaches the engine raw, the way
    /// `tag.option@value` or a JSON `$.url` does.
    private static func engine(_ hrefs: [String]) -> ModernRuleEngine {
        let links = hrefs.map { "<a data-url='\($0)' href='\($0)'>x</a>" }.joined()
        let engine = ModernRuleEngine()
        engine.setContent("<html><body>\(links)</body></html>", baseUrl: base)
        return engine
    }

    @Test("a root-relative link keeps its options")
    func rootRelativeKeepsOptions() {
        let engine = Self.engine([#"/p2,{"method":"POST","body":"a=1"}"#])
        #expect(engine.getString(ruleStr: "a@data-url", isUrl: true)
            == #"https://h.yuedu.test/p2,{"method":"POST","body":"a=1"}"#)
    }

    /// Legado's `BookChapter.getAbsoluteURL` rejoins the options after a bare comma.
    @Test("a path-relative link keeps its options; the spaces around the comma go")
    func pathRelativeKeepsOptions() {
        let engine = Self.engine([#"p2.html , {"method":"POST"}"#])
        #expect(engine.getString(ruleStr: "a@data-url", isUrl: true)
            == #"https://h.yuedu.test/book/1/p2.html,{"method":"POST"}"#)
    }

    @Test("options reach AnalyzeUrl from a resolved link")
    func optionsReachAnalyzeUrl() {
        let engine = Self.engine([#"/p2,{"method":"POST","body":"a=1"}"#])
        let analyzed = AnalyzeUrl(ruleUrl: engine.getString(ruleStr: "a@data-url", isUrl: true))
        #expect(analyzed.url == "https://h.yuedu.test/p2")
        #expect(analyzed.method == "POST")
    }

    @Test("a list of links keeps each link's options")
    func listKeepsOptions() {
        let engine = Self.engine([#"/p2,{"method":"POST"}"#, "/p3"])
        #expect(engine.getStringList(ruleStr: "a@data-url", isUrl: true) == [
            #"https://h.yuedu.test/p2,{"method":"POST"}"#, "https://h.yuedu.test/p3",
        ])
    }

    @Test("an href with options keeps them")
    func hrefKeepsOptions() {
        let engine = Self.engine([#"/p2,{"method":"POST"}"#])
        #expect(engine.getString(ruleStr: "a@href", isUrl: true)
            == #"https://h.yuedu.test/p2,{"method":"POST"}"#)
    }

    @Test("a javascript link resolves to nothing")
    func javascriptIsEmpty() {
        let engine = Self.engine(["javascript:void(0)"])
        #expect(engine.getString(ruleStr: "a@data-url", isUrl: true) == "")
        #expect(engine.getOptionalURL(ruleStr: "a@data-url") == "")
        #expect(engine.getString(ruleStr: "a@href", isUrl: true) == "")
    }

    @Test("javascript links drop out of a list of links")
    func javascriptDropsFromList() {
        let engine = Self.engine(["javascript:;", "/p3"])
        #expect(engine.getStringList(ruleStr: "a@data-url", isUrl: true) == ["https://h.yuedu.test/p3"])
    }

    @Test("plain relative and absolute links resolve as before")
    func plainLinksUnchanged() {
        let engine = Self.engine(["/p3", "p4.html", "../p5", "?page=2", "https://o.yuedu.test/x,{\"a\":1}"])
        #expect(engine.getStringList(ruleStr: "a@data-url", isUrl: true) == [
            "https://h.yuedu.test/p3",
            "https://h.yuedu.test/book/1/p4.html",
            "https://h.yuedu.test/book/p5",
            "https://h.yuedu.test/book/1/index.html?page=2",
            "https://o.yuedu.test/x,{\"a\":1}",
        ])
    }
}
