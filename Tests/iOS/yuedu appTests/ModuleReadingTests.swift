import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem plan, M5a: a module's `reading` rules — a book's table of contents from its
/// own page, page after page, and a chapter's text through the shared chapter builder — on
/// なろう's saved pages.
@MainActor
@Suite("Module reading", .serialized)
struct ModuleReadingTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Narou")

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    private func client() -> (client: RuleModuleClient, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleReading-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        return (RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                 store: RuleModuleStore(directory: folder)), folder)
    }

    /// なろう's reading rules, as its module file will carry them.
    static let narouReading = RuleModule.Reading(
        headers: ["User-Agent": "yuedureader/Yuedu (iOS) (+https://yuedureader.com/support)"],
        charset: nil,
        toc: RuleModule.TableOfContents(
            items: "@css:.p-eplist__chapter-title, .p-eplist__sublist",
            title: "@css:.p-eplist__subtitle@text||@css:.p-eplist__chapter-title@text",
            url: "@css:.p-eplist__subtitle@href",
            nextPage: "@css:.c-pager__item--next@href",
            singleChapter: "@css:.p-novel__body@text"),
        content: RuleModule.Content(text: "@css:.js-novel-text@html", title: nil, nextPage: nil))

    private func module(_ reading: RuleModule.Reading = Self.narouReading, hosts: [String] = ["ncode.syosetu.com"]) -> RuleModule {
        var module = RuleModule(id: "test.narou", title: "なろう", description: nil, author: nil, site: nil, version: "1.0",
                                requiredVersion: "3.0", hosts: hosts, rateLimit: nil, modules: [], search: nil)
        module.reading = reading
        return module
    }

    @Test("a table of contents read page after page, volume headings in place, the module's headers sent")
    func tableOfContents() async throws {
        let (client, folder) = client()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The second page is the saved last page: it has no next page. (`URL.path` drops the
        // trailing slash the stub keys on.)
        ModuleStub.install(["ncode.syosetu.com/n9669bk": .html(try page("narou-toc-p1.html")),
                            "ncode.syosetu.com/n9669bk?p=2": .html(try page("narou-toc-p3.html"))])
        let chapters = try await client.tableOfContents(bookURL: "https://ncode.syosetu.com/n9669bk/", title: "無職転生", in: module())

        #expect(ModuleStub.urls == ["https://ncode.syosetu.com/n9669bk/", "https://ncode.syosetu.com/n9669bk/?p=2"])
        #expect(ModuleStub.userAgents.allSatisfy { $0.hasPrefix("yuedureader/") })
        let episodes = chapters.filter { !$0.isVolume }
        let p1 = try page("narou-toc-p1.html"), p3 = try page("narou-toc-p3.html")
        func count(_ needle: String, _ text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        #expect(episodes.count == count("class=\"p-eplist__sublist\"", p1) + count("class=\"p-eplist__sublist\"", p3))
        #expect(chapters.count - episodes.count == count("class=\"p-eplist__chapter-title\"", p1) + count("class=\"p-eplist__chapter-title\"", p3),
                "each 章 heading is a volume, where the page has it")
        #expect(episodes.first == ModuleChapter(title: "プロローグ", url: "https://ncode.syosetu.com/n9669bk/1/"))
        #expect(episodes.dropFirst().first?.title == "第一話「もしかして：異世界」")
        #expect(!chapters.contains { $0.title.contains("/") && $0.title.contains(":") }, "a title is the subtitle, not its date")
    }

    @Test("a short story's page is its one chapter; a serial's list page is not")
    func singleChapter() async throws {
        let (client, folder) = client()
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install(["ncode.syosetu.com/n0001aa": .html(try page("narou-short.html"))])
        let chapters = try await client.tableOfContents(bookURL: "https://ncode.syosetu.com/n0001aa/", title: "短編", in: module())
        #expect(chapters == [ModuleChapter(title: "短編", url: "https://ncode.syosetu.com/n0001aa/")])
        #expect(ModuleStub.urls.count == 1)
        #expect(!RuleModuleClient.isSingleChapter(try page("narou-toc-p1.html"), baseURL: "https://ncode.syosetu.com/n9669bk/",
                                                   toc: Self.narouReading.toc))
    }

    @Test("the list stops at a page already read, and after maxTOCPages")
    func tocBounds() async throws {
        let (client, folder) = client()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toc = RuleModule.TableOfContents(items: "@css:li", title: "@css:a@text", url: "@css:a@href", nextPage: "@css:a.next@href")
        let reading = RuleModule.Reading(headers: nil, charset: nil, toc: toc, content: RuleModule.Content(text: "@css:p@html"))
        func list(_ next: String) -> String { #"<ul><li><a href="/c/1">一</a></li></ul><a class="next" href="\#(next)">次</a>"# }

        ModuleStub.install(["example.com/b": .html(list("/b"))])
        _ = try await client.tableOfContents(bookURL: "https://example.com/b", title: "書", in: module(reading, hosts: ["example.com"]))
        #expect(ModuleStub.urls == ["https://example.com/b"], "its next page is itself")

        var pages: [String: ModuleStub.Reply] = ["example.com/b": .html(list("/b?p=2"))]
        for index in 2...(RuleModuleClient.maxTOCPages + 5) { pages["example.com/b?p=\(index)"] = .html(list("/b?p=\(index + 1)")) }
        ModuleStub.install(pages)
        let chapters = try await client.tableOfContents(bookURL: "https://example.com/b", title: "書", in: module(reading, hosts: ["example.com"]))
        #expect(ModuleStub.urls.count == RuleModuleClient.maxTOCPages)
        #expect(chapters.count == RuleModuleClient.maxTOCPages)
    }

    @Test("a root-relative link keeps its page's port: a list's next page on a server not on 80 or 443")
    func rootRelativeKeepsPort() {
        #expect(RuleEngine.resolveURL("/n9669bk/?p=2", base: "http://localhost:18770/N9669BK/") == "http://localhost:18770/n9669bk/?p=2")
        #expect(RuleEngine.resolveURL("/c/1", base: "https://example.com/b") == "https://example.com/c/1")
        #expect(RuleEngine.resolveURL("//cdn.example.com/a.jpg", base: "http://localhost:18770/b") == "http://cdn.example.com/a.jpg",
                "a scheme-relative link names its own host and port")
        let next = ModernRuleEngine().setContent(#"<a class="next" href="/b?p=2">次</a>"#, baseUrl: "http://localhost:8080/b")
            .getOptionalURL(ruleStr: "@css:a.next@href")
        #expect(next == "http://localhost:8080/b?p=2")
    }

    @Test("a next page on another site is refused, not sent")
    func tocHosts() async throws {
        let (client, folder) = client()
        defer { try? FileManager.default.removeItem(at: folder) }
        let toc = RuleModule.TableOfContents(items: "@css:li", title: "@css:a@text", url: "@css:a@href", nextPage: "@css:a.next@href")
        let reading = RuleModule.Reading(headers: nil, charset: nil, toc: toc, content: RuleModule.Content(text: "@css:p@html"))
        ModuleStub.install(["example.com/b": .html(#"<ul><li><a href="/c/1">一</a></li></ul><a class="next" href="https://elsewhere.com/b">次</a>"#)])
        await #expect(throws: (any Error).self) {
            try await client.tableOfContents(bookURL: "https://example.com/b", title: "書", in: module(reading, hosts: ["example.com"]))
        }
        #expect(ModuleStub.urls == ["https://example.com/b"])
    }

    @Test("a chapter's text, read by the content rule and normalized as every online chapter; ruby stays ruby")
    func chapter() async throws {
        let (client, folder) = client()
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install(["ncode.syosetu.com/n9669bk/1": .html(try page("narou-episode.html"))])
        let built = try await client.chapterPackage(bookId: UUID(), chapterIndex: 0,
                                                    chapter: ModuleChapter(title: "プロローグ", url: "https://ncode.syosetu.com/n9669bk/1/"),
                                                    in: module())
        #expect(built.package.state == .cached)
        #expect(built.package.content.contains("俺は34歳住所不定無職。"))
        #expect(!built.package.content.contains("1/286"), "only the text, not the page's furniture")
        #expect(built.normalizedHTML.contains("俺は34歳住所不定無職。"))

        let ruby = #"<div class="p-novel__body"><div class="js-novel-text p-novel__text"><p id="L1">　<ruby>魔術<rp>(</rp><rt>まじゅつ</rt><rp>)</rp></ruby>を使う。</p></div></div>"#
        ModuleStub.install(["ncode.syosetu.com/n9669bk/2": .html(ruby)])
        let rubyChapter = try await client.chapterPackage(bookId: UUID(), chapterIndex: 1,
                                                          chapter: ModuleChapter(title: "第一話", url: "https://ncode.syosetu.com/n9669bk/2/"),
                                                          in: module())
        #expect(rubyChapter.normalizedHTML.contains("<rt>まじゅつ</rt>"), "the reader draws the reading over the word")
        #expect(rubyChapter.normalizedHTML.contains("<ruby>魔術"))
        // The plain copy (manga and audio detection, health checks) keeps `<rp>`'s fallback,
        // as every 來源配置 chapter's does; the reader and 聽書 read the HTML.
        #expect(rubyChapter.package.content == "魔術(まじゅつ)を使う。")
    }

    @Test("reading rules: no JS, a list, a url and a text; format 3.0")
    func readingRules() {
        func file(_ reading: String, required: String = "3.0") -> Data {
            Data("""
            {"id":"m","title":"模組","version":"1.0","requiredVersion":"\(required)","hosts":["example.com"],
             "modules":[{"id":"new","title":"新書","request":{"url":"https://example.com/"},"list":{"items":"li","title":"h3","url":"a@href"}}],
             "reading":\(reading)}
            """.utf8)
        }
        let good = #"{"toc":{"items":"li","title":"a@text","url":"a@href","nextPage":"a.next@href"},"content":{"text":"div.text@html"}}"#
        #expect(throws: Never.self) { try RuleModuleValidator.validate(file(good), appVersion: "3.0") }
        #expect(throws: RuleModuleRejection.missingField("reading.toc.url")) {
            try RuleModuleValidator.validate(file(#"{"toc":{"items":"li","title":"a@text","url":" "},"content":{"text":"p"}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.javaScript(field: "reading.content.text")) {
            try RuleModuleValidator.validate(file(#"{"toc":{"items":"li","title":"a@text","url":"a@href"},"content":{"text":"@js:result"}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.needsRequiredVersion(field: "reading", minimum: "3.0")) {
            try RuleModuleValidator.validate(file(good, required: "2.0"), appVersion: "3.0")
        }
    }
}
