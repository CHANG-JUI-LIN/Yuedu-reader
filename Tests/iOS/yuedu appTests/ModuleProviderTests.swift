import Foundation
import Testing
@testable import yuedu_app

/// Phase 6d: an installed module as a source. Requests are answered by `ModuleStub` on the
/// client's own session; nothing reaches the network.
@MainActor
@Suite("Module provider", .serialized)
struct ModuleProviderTests {
    private let listHTML = #"""
    <ul class="books">
      <li><h3>第一本</h3><span class="a">甲</span><img src="https://img.example.com/1.jpg"/>
        <p class="d">一段<b>簡介</b></p><i class="t">奇幻</i><a href="/b/1">x</a></li>
      <li><h3>第二本</h3><span class="a">乙</span><img src="https://elsewhere.example/2.jpg"/><a href="/b/2">x</a></li>
    </ul>
    """#

    private func module(_ entries: [RuleModule.Entry], hosts: [String] = ["example.com", "img.example.com"]) -> RuleModule {
        RuleModule(id: "test.module", title: "測試模組", description: nil, author: nil, site: nil, version: "1.0",
                   requiredVersion: nil, hosts: hosts, rateLimit: nil, modules: entries, search: nil)
    }

    private func htmlEntry(cache: Int? = nil, params: [RuleModule.Param]? = nil,
                           url: String = "https://example.com/new/{{category}}?p={{page}}") -> RuleModule.Entry {
        RuleModule.Entry(
            id: "new", title: "新書", cacheDuration: cache,
            params: params ?? [
                RuleModule.Param(name: "category", type: "enumeration",
                                 enumOptions: [RuleModule.Option(title: "小說", value: "novel"),
                                               RuleModule.Option(title: "漫畫", value: "comic")]),
                RuleModule.Param(name: "page", type: "page"),
            ],
            request: RuleModule.Request(url: url),
            list: RuleModule.ListRules(items: "ul.books li", title: "h3@text", author: ".a@text", cover: "img@src",
                                       intro: ".d@html", url: "a@href", kind: ".t@text"))
    }

    private struct Fixture {
        let folder: URL
        let client: RuleModuleClient
        let clock: Clock
    }

    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func makeFixture() -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleProvider-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let clock = Clock()
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder), now: { clock.date })
        return Fixture(folder: folder, client: client, clock: clock)
    }

    private func section(_ entryID: String = "new", parameters: [String: String] = [:]) -> HomeSection {
        HomeSection(layout: .row, binding: .module(moduleID: "test.module", entryID: entryID), parameters: parameters)
    }

    @Test("an HTML list: data-only items, plain and bounded; covers only from the module's hosts")
    func htmlEntryItems() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/comic": .html(listHTML)])
        let provider = ModuleProvider(module: module([htmlEntry()]), client: f.client)

        #expect(provider.loadPolicy(for: section()) == .parallel)
        #expect(provider.loadPolicy(for: section("gone")) == nil, "an entry the module no longer has")
        let entries = try await provider.load(section(parameters: ["category": "comic"]))

        #expect(ModuleStub.urls == ["https://example.com/new/comic?p=1"], "the section's own value, the first page")
        #expect(entries.count == 2)
        guard case .item(let record, let summary, let opening) = entries[0] else { Issue.record("not an item"); return }
        #expect(opening == .bibliographic)
        #expect(record.key == SourceItemKey(instance: SourceInstanceKey(type: .module, id: "test.module"), item: "https://example.com/b/1"))
        #expect(record.acquisitions == [.viewOnly])
        #expect(summary.title == "第一本")
        #expect(summary.authors == ["甲"])
        #expect(summary.blurb == "一段簡介", "markup is dropped")
        #expect(summary.category == "奇幻")
        #expect(summary.cover == .remote(URL(string: "https://img.example.com/1.jpg")!, headers: [:]))
        guard case .item(_, let second, _) = entries[1] else { Issue.record("not an item"); return }
        #expect(second.cover == .generated(seed: "第二本"), "a cover from a host the module does not list is not fetched")
    }

    @Test("defaults: an enumeration's first option when it names no default")
    func defaults() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/novel": .html(listHTML)])
        _ = try await ModuleProvider(module: module([htmlEntry()]), client: f.client).load(section())
        #expect(ModuleStub.urls == ["https://example.com/new/novel?p=1"])
    }

    @Test("a JSON list")
    func jsonEntry() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/api/list": .json(#"{"data":[{"name":"JSON 書","author":"丙","link":"/b/9","lang":"ja"}]}"#)])
        let entry = RuleModule.Entry(id: "api", title: "API", request: RuleModule.Request(url: "https://example.com/api/list"),
                                     list: RuleModule.ListRules(items: "$.data[*]", title: "$.name", author: "$.author",
                                                                url: "$.link", language: "$.lang"))
        let page = try await ModuleProvider(module: module([entry]), client: f.client)
            .browse(CollectionLocation(id: "api", title: ""), after: nil)
        #expect(page.next == nil, "an entry with no paging parameter has one page")
        guard case .item(let record, let summary, _) = try #require(page.entries.first) else { Issue.record("not an item"); return }
        #expect(summary.title == "JSON 書")
        #expect(summary.language == "ja")
        #expect(record.key.item == "https://example.com/b/9")
    }

    @Test("the root lists the entries")
    func root() async throws {
        let f = makeFixture()
        let provider = ModuleProvider(module: module([htmlEntry()]), client: f.client)
        let root = try await provider.browse(nil, after: nil)
        #expect(root.entries == [.location(CollectionLocation(id: "new", title: "新書"))])
        #expect(await provider.capabilities() == CollectionCapabilities(search: .none, paginates: true))
    }

    @Test("paging by page")
    func pagingByPage() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/novel": .html(listHTML)])
        let provider = ModuleProvider(module: module([htmlEntry()]), client: f.client)
        let location = CollectionLocation(id: "new", title: "")
        let first = try await provider.browse(location, after: nil)
        #expect(first.next == CollectionCursor(value: "2"))
        let second = try await provider.browse(location, after: first.next)
        #expect(second.next == CollectionCursor(value: "3"))
        #expect(ModuleStub.urls == ["https://example.com/new/novel?p=1", "https://example.com/new/novel?p=2"])

        ModuleStub.install(["example.com/new/novel": .html("<ul class=\"books\"></ul>")])
        let last = try await provider.browse(location, after: second.next)
        #expect(last.entries.isEmpty && last.next == nil, "an empty page ends the list")
    }

    @Test("paging by offset moves by the items read")
    func pagingByOffset() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/list": .html(listHTML)])
        let entry = htmlEntry(params: [RuleModule.Param(name: "start", type: "offset")], url: "https://example.com/list?from={{start}}")
        let provider = ModuleProvider(module: module([entry]), client: f.client)
        let location = CollectionLocation(id: "new", title: "")
        let first = try await provider.browse(location, after: nil)
        #expect(first.next == CollectionCursor(value: "2"))
        _ = try await provider.browse(location, after: first.next)
        #expect(ModuleStub.urls == ["https://example.com/list?from=0", "https://example.com/list?from=2"])
    }

    @Test("a redirect to a host the module does not list is never followed")
    func redirectRefused() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install([
            "example.com/new/novel": .redirect("https://evil.example/steal"),
            "evil.example/steal": .html(listHTML),
        ])
        let provider = ModuleProvider(module: module([htmlEntry()]), client: f.client)
        do {
            _ = try await provider.load(section())
            Issue.record("the redirect was followed")
        } catch let failure as SourceFailure {
            #expect(failure.kind == .invalidAddress)
        }
        #expect(!ModuleStub.urls.contains { $0.contains("evil.example") }, "the redirected request is never sent")
    }

    @Test("a redirect within the module's hosts is followed")
    func redirectAllowed() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install([
            "example.com/new/novel": .redirect("https://img.example.com/moved"),
            "img.example.com/moved": .html(listHTML),
        ])
        let entries = try await ModuleProvider(module: module([htmlEntry()]), client: f.client).load(section())
        #expect(entries.count == 2)
    }

    @Test("a 403 is a failure, not an empty row")
    func rejected() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/novel": .status(403)])
        do {
            _ = try await ModuleProvider(module: module([htmlEntry()]), client: f.client).load(section())
            Issue.record("a 403 read as a page")
        } catch let failure as SourceFailure {
            #expect(failure.kind == .rejected)
            #expect(failure.status == 403)
        }
    }

    @Test("an empty list is empty, not a failure")
    func empty() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/novel": .html("<p>今日無新書</p>")])
        #expect(try await ModuleProvider(module: module([htmlEntry()]), client: f.client).load(section()).isEmpty)
    }

    @Test("the cache answers within cacheDuration, per parameters, and only then")
    func cache() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/novel": .html(listHTML), "example.com/new/comic": .html(listHTML)])
        let provider = ModuleProvider(module: module([htmlEntry(cache: 3600)]), client: f.client)
        _ = try await provider.load(section())
        let again = try await provider.load(section())
        #expect(again.count == 2)
        #expect(ModuleStub.urls.count == 1, "answered from the cache")
        _ = try await provider.load(section(parameters: ["category": "comic"]))
        #expect(ModuleStub.urls.count == 2, "another value is another page")
        f.clock.date += 3601
        _ = try await provider.load(section())
        #expect(ModuleStub.urls.count == 3, "fetched again once the duration has passed")
    }

    @Test("its manifest, and its binding round-trips")
    func manifestAndBinding() async throws {
        let f = makeFixture()
        var described = module([htmlEntry()])
        described.rateLimit = "2/1000"
        let manifest = await ModuleProvider(module: described, client: f.client).manifest()
        #expect(manifest.instance == SourceInstanceKey(type: .module, id: "test.module"))
        #expect(manifest.displayName == "測試模組")
        #expect(manifest.capabilities == [.browse, .homeSections])
        #expect(manifest.hosts == ["example.com", "img.example.com"])
        #expect(manifest.rateLimit == "2/1000")

        let original = section(parameters: ["category": "comic"])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == original)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"module""#))
    }

    @Test("values fill every template, percent-encoded in a URL")
    func fill() {
        #expect(RuleModuleClient.fill("https://example.com/s?q={{keyword}}&p={{page}}", ["keyword": "三體 & 其他", "page": "1"], encode: true)
                == "https://example.com/s?q=%E4%B8%89%E9%AB%94%20%26%20%E5%85%B6%E4%BB%96&p=1")
        #expect(RuleModuleClient.fill("Bearer {{token}}", ["token": "a b"], encode: false) == "Bearer a b")
    }

    @Test("a JSON body gets its values JSON-escaped, never percent-encoded (format 3.0)")
    func jsonBody() {
        #expect(RuleModuleClient.fill(#"{"keyword":"{{keyword}}"}"#, ["keyword": "葬送 \"の\" \\ 1\n"], encoding: .json)
                == #"{"keyword":"葬送 \"の\" \\ 1\n"}"#)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// Bangumi's search as its module file asks it (format 3.0): a JSON POST body, comics by
    /// platform, aliases from the infobox, tags without format words and the work's own names.
    private func bangumiSearch() -> RuleModule.Entry {
        RuleModule.Entry(
            id: nil, title: nil,
            request: RuleModule.Request(url: "https://api.bgm.tv/v0/search/subjects?limit=10", method: "POST",
                                        body: #"{"keyword":"{{keyword}}","filter":{"type":[1]}}"#,
                                        headers: ["Content-Type": "application/json"], bodyEncoding: "json"),
            list: RuleModule.ListRules(items: "$.data[*]", title: "$.name", author: "$.infobox[?(@.key=='原作')].value",
                                       cover: "$.images.large", intro: "$.summary", url: "https://bgm.tv/subject/{{$.id}}",
                                       aliases: "$.name_cn&&$.infobox[?(@.key=='别名')].value[*].v",
                                       tags: "$.tags[*].name", publisher: "$.infobox[?(@.key=='出版社')].value",
                                       contentKind: "$.platform##漫画##comic"),
            excludeTags: ["漫画", "单行本", "漫画单行本", "漫画分卷", "コミックス", "日本", "原创"])
    }

    @Test("a Bangumi search: a JSON body, comics, aliases and genre tags from its real reply")
    func bangumi() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let reply = try String(contentsOf: Self.fixtures.appendingPathComponent("Bangumi/bangumi-search.json"), encoding: .utf8)
        ModuleStub.install(["api.bgm.tv/v0/search/subjects": .json(reply)])
        var bangumi = module([], hosts: ["api.bgm.tv", "lain.bgm.tv"])
        bangumi.search = bangumiSearch()
        let search = try #require(bangumi.search)

        let page = try await f.client.page(of: search, in: bangumi, values: search.values([:], position: 0, keyword: #"葬送の"フリーレン""#))
        #expect(ModuleStub.bodies == [#"{"keyword":"葬送の\"フリーレン\"","filter":{"type":[1]}}"#])
        let work = try #require(page.items.first)
        #expect(work.name == "葬送のフリーレン")
        #expect(work.aliases == ["葬送的芙莉莲", "葬送者芙莉莲", "FRIEREN"])
        #expect(work.publisher == "小学館")
        #expect(search.contentKind(of: work) == .comic)
        #expect(search.tags(of: work) == ["旅行", "寿命论", "奇幻", "治愈", "勇者"],
                "no format words, no year, not the author 山田鐘人 nor the publisher 小学館")

        let entries = try #require(try await ModuleProvider(module: bangumi, client: f.client).search("葬送のフリーレン")).entries
        #expect(entries.count == 5)
        guard case .item(let record, let summary, _) = entries[0] else { Issue.record("not an item"); return }
        #expect(record.key.item == "https://bgm.tv/subject/305429", "the work's page, read in place from its id")
        #expect(record.contentKind == .comic)
        #expect(summary.contentKind == .comic)
        #expect(summary.category == "旅行", "without a kind rule, the first genre tag")
    }

    @Test("an entry's kind, overridden only by an item that says comic; an ISBN becomes an identifier")
    func kindsAndISBN() {
        let novels = RuleModule.Entry(id: "n", title: "n", request: RuleModule.Request(url: "https://example.com/"),
                                      list: RuleModule.ListRules(items: "a", title: "b"))
        var item = RuleListItem(name: "書", author: "", bookUrl: "", coverUrl: "", intro: "", wordCount: "", lastChapter: "",
                                kind: "", isbn: "4-7503-2023-4")
        #expect(novels.contentKind(of: item) == .text)
        item.contentKind = "小说"
        #expect(novels.contentKind(of: item) == .text, "a value other than comic leaves the entry's kind")
        item.contentKind = "comic"
        #expect(novels.contentKind(of: item) == .comic)
        var comics = novels
        comics.contentKind = "comic"
        item.contentKind = nil
        #expect(comics.contentKind(of: item) == .comic)

        let entry = ModuleProvider.entry(item, of: novels, instance: ModuleProvider.instanceKey(moduleID: "m"),
                                         hasURLRule: false, hosts: [])
        guard case .item(let record, _, _) = entry else { Issue.record("not an item"); return }
        #expect(record.identifiers == Set([ExternalIdentifier.normalized(.isbn13, "9784750320236")!]))
    }
}

/// Answers by host and path from a table; records every URL asked for.
final class ModuleStub: URLProtocol {
    enum Reply {
        case html(String)
        case json(String)
        case status(Int)
        case redirect(String)
        /// Never answers: a site that hangs.
        case hang
    }

    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requested: [String] = []
    nonisolated(unsafe) private static var sentBodies: [String] = []
    nonisolated(unsafe) private static var sentAgents: [String] = []
    private static let lock = NSLock()

    static var urls: [String] { lock.withLock { requested } }
    /// Each request's body, as UTF-8 (empty without one).
    static var bodies: [String] { lock.withLock { sentBodies } }
    /// Each request's User-Agent.
    static var userAgents: [String] { lock.withLock { sentAgents } }

    static func install(_ table: [String: Reply]) {
        lock.withLock {
            replies = table
            requested = []
            sentBodies = []
            sentAgents = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let reply: Reply? = Self.lock.withLock {
            Self.requested.append(url.absoluteString)
            Self.sentBodies.append(String(decoding: body, as: UTF8.self))
            Self.sentAgents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
            return Self.replies["\(url.host ?? "")\(url.path)"]
        }
        func finish(_ status: Int, _ headers: [String: String], _ body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        switch reply {
        case .html(let text): finish(200, ["Content-Type": "text/html; charset=utf-8"], Data(text.utf8))
        case .json(let text): finish(200, ["Content-Type": "application/json"], Data(text.utf8))
        case .status(let code): finish(code, [:], Data())
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            finish(302, ["Location": location], Data())
        case .hang: break
        case nil: finish(404, [:], Data())
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
