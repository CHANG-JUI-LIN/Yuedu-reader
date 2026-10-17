import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Open Library module plan, OL1b (maintainer, 2026-10-17): what Open Library's file needs of
/// the format. A `*.` host a redirect may follow into (its covers redirect to archive.org's
/// numbered servers), a search's shortest keyword (it refuses one under three characters), and
/// `isbn` / `author` rules that read several values.
@MainActor
@Suite("Module format additions", .serialized)
struct ModuleFormatAdditionsTests {
    private func module(_ object: [String: Any], hosts: [String] = ["example.com"], required: String? = "3.0") -> Data {
        var base: [String: Any] = ["id": "f.test", "title": "f", "version": "1.0", "hosts": hosts,
                                   "modules": [[String: Any]]()]
        if let required { base["requiredVersion"] = required }
        base.merge(object) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: base)
    }

    private func rejection(_ data: Data) -> RuleModuleRejection? {
        do { _ = try RuleModuleValidator.validate(data, appVersion: "3.0.0"); return nil } catch { return error }
    }

    private func search(url: String = "https://example.com/s?q={{keyword}}", _ extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = ["request": ["url": url], "list": ["items": "$.docs[*]", "title": "$.title", "url": "$.key"]]
        entry.merge(extra) { _, new in new }
        return ["search": entry]
    }

    // MARK: - Hosts

    @Test("a `*.` host is a domain and every name under it, for redirects only")
    func wildcardMatching() {
        let hosts = RuleModuleHosts(["example.com", "*.archive.org"])
        #expect(hosts.allowsRequest(to: "example.com"))
        #expect(!hosts.allowsRequest(to: "archive.org"), "a request goes only to a host written out")
        #expect(!hosts.allowsRequest(to: "ia801609.us.archive.org"))
        #expect(hosts.allowsRedirect(to: "example.com"))
        #expect(hosts.allowsRedirect(to: "ARCHIVE.org"))
        #expect(hosts.allowsRedirect(to: "ia801609.us.archive.org"))
        #expect(!hosts.allowsRedirect(to: "notarchive.org"))
        #expect(!hosts.allowsRedirect(to: "archive.org.example.net"))
        #expect(!hosts.allowsRedirect(to: "sub.example.com"), "a host written out is that host alone")
    }

    @Test("a `*.` host names a domain of two labels or more, needs 3.0, and no request may be sent to it")
    func wildcardValidation() {
        #expect(rejection(module(search(), hosts: ["example.com", "*.archive.org"])) == nil)
        for bad in ["*", "*.org", "a.*.org", "*.*.archive.org", "*archive.org", "*.archive..org"] {
            #expect(rejection(module(search(), hosts: ["example.com", bad])) == .unknownValue(field: "hosts", value: bad), "\(bad)")
        }
        #expect(rejection(module(search(url: "https://ia800.us.archive.org/s?q={{keyword}}"), hosts: ["example.com", "*.archive.org"]))
                == .hostNotAllowed(field: "search.request.url", host: "ia800.us.archive.org"))
        #expect(rejection(module(search(), hosts: ["example.com", "*.archive.org"], required: nil))
                == .needsRequiredVersion(field: "hosts", minimum: "3.0"))
    }

    @Test("an update that adds a `*.` host says so")
    func wildcardIsAnAddedHost() throws {
        let old = try RuleModuleValidator.validate(module(search()), appVersion: "3.0.0")
        let new = try RuleModuleValidator.validate(module(search(), hosts: ["example.com", "*.archive.org"]), appVersion: "3.0.0")
        #expect(new.hosts(addedTo: old) == ["*.archive.org"])
    }

    // MARK: - Covers

    private struct Fixture {
        let provider: ModuleProvider
        let folder: URL
        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    private func fixture(_ data: Data) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FormatAdditions-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.0", officialFiles: { [] })
        let installed = try await library.install(data, from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        return Fixture(provider: ModuleProvider(module: installed, client: client), folder: folder)
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
    }

    private static let isbn = "9787536692930"

    private func lookupModule(hosts: [String]) -> Data {
        module(["lookup": ["request": ["url": "https://example.com/isbn/{{isbn}}"],
                           "list": ["items": "$.docs[*]", "title": "$.title", "url": "$.key", "isbn": "$.isbns",
                                    "intro": "$.intro", "cover": "$.cover"]]], hosts: hosts)
    }

    private func isbnQuery(missing: Set<MetadataField> = [.cover, .intro]) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: "三體", authors: ["劉慈欣"],
                          identifiers: [ExternalIdentifier.normalized(.isbn13, Self.isbn)!], copySource: .localLibrary, missing: missing)
    }

    private func record(cover: String) -> String {
        #"{"docs":[{"title":"三體","key":"/w/1","isbns":["7536692935","\#(Self.isbn)"],"intro":"地球往事。","cover":"\#(cover)"}]}"#
    }

    @Test("a cover redirected into a `*.` host is fetched; one redirected elsewhere is no cover, and the record still fills")
    func coverRedirects() async throws {
        let f = try await fixture(lookupModule(hosts: ["example.com", "*.cdn.example.net"]))
        defer { f.cleanUp() }
        let covers = f.folder.appendingPathComponent("covers")
        let filler = ModuleFillProvider(provider: f.provider, coverDirectory: covers)

        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(record(cover: "https://example.com/c/1.jpg")),
            "example.com/c/1.jpg": .redirect("https://img7.cdn.example.net/1.jpg"),
            "img7.cdn.example.net/1.jpg": .image(png()),
        ])
        let fetched = try await filler.lookUp(isbnQuery())
        #expect(fetched.values[.cover] == .text("module-f.test-\(Self.isbn).jpg"))
        #expect(fetched.values[.intro] == .text("地球往事。"))

        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(record(cover: "https://example.com/c/1.jpg")),
            "example.com/c/1.jpg": .redirect("https://elsewhere.example/1.jpg"),
            "elsewhere.example/1.jpg": .image(png()),
        ])
        let refused = try await filler.lookUp(isbnQuery())
        #expect(refused.values[.cover] == nil)
        #expect(refused.values[.intro] == .text("地球往事。"), "a cover the module may not fetch does not lose the record")
        #expect(!ModuleStub.urls.contains("https://elsewhere.example/1.jpg"))
    }

    // MARK: - Several ISBNs and authors

    @Test("the record is the copy's when any of the ISBNs its rule reads is the copy's")
    func severalISBNs() async throws {
        let f = try await fixture(lookupModule(hosts: ["example.com"]))
        defer { f.cleanUp() }
        ModuleStub.install(["example.com/isbn/\(Self.isbn)": .json(record(cover: ""))])
        let result = try await ModuleFillProvider(provider: f.provider).lookUp(isbnQuery(missing: [.intro]))
        #expect(result.values[.intro] == .text("地球往事。"), "the ISBN-10 is listed first; the copy's ISBN-13 is second")
        #expect(ModuleFillProvider.record(in: [RuleListItem(name: "a", author: "", bookUrl: "", coverUrl: "", intro: "", wordCount: "",
                                                            lastChapter: "", kind: "", isbn: "9780000000002\n0000000000")],
                                          isbn: Self.isbn) == nil)
    }

    @Test("a search row keeps several authors and up to five ISBNs, each once")
    func rowAuthorsAndISBNs() throws {
        let item = RuleListItem(name: "三体", author: "刘慈欣\nKen Liu\n\n刘慈欣", bookUrl: "https://example.com/w/1", coverUrl: "",
                                intro: "", wordCount: "", lastChapter: "", kind: "",
                                isbn: ["7536692935", "9787536692930", "1427265836", "9781427265838", "076539748X", "9780765397485",
                                       "9780765382030", "9781784971571"].joined(separator: "\n"))
        let entry = try #require(RuleModuleValidator.validate(module(search()), appVersion: "3.0.0").search)
        guard case .item(let record, let summary, _) = ModuleProvider.entry(
            item, of: entry, instance: ModuleProvider.instanceKey(moduleID: "f.test"), hasURLRule: true,
            hosts: RuleModuleHosts(["example.com"])) else { Issue.record("no item"); return }
        #expect(record.authors == ["刘慈欣", "Ken Liu"])
        #expect(summary.authors == ["刘慈欣", "Ken Liu"])
        #expect(record.identifiers.filter { $0.scheme == .isbn13 }.count == 5,
                "7536692935 and 9787536692930 are one book; five books are kept")
    }

    // MARK: - Shortest keyword

    @Test("a search's minKeywordLength: 1 or more, a search's only, and needs 3.0")
    func minKeywordValidation() {
        #expect(rejection(module(search(["minKeywordLength": 3]))) == nil)
        #expect(rejection(module(search(["minKeywordLength": 0]))) == .unknownValue(field: "search.minKeywordLength", value: "0"))
        #expect(rejection(module(["modules": [["id": "a", "title": "a", "request": ["url": "https://example.com/a"],
                                               "list": ["items": "li", "title": "h3@text"], "minKeywordLength": 3]]]))
                == .unknownValue(field: "modules[0].minKeywordLength", value: "3"))
        #expect(rejection(module(search(["minKeywordLength": 3]), required: nil))
                == .needsRequiredVersion(field: "search.minKeywordLength", minimum: "3.0"))
    }

    @Test("a keyword shorter than the search takes is never sent: no search in 搜索, nothing to fill from")
    func minKeywordLength() async throws {
        let f = try await fixture(module(search(["minKeywordLength": 3])))
        defer { f.cleanUp() }
        ModuleStub.install(["example.com/s": .json(#"{"docs":[{"title":"三體 全集","key":"/w/1"}]}"#)])
        #expect(try await f.provider.search(" 三體 ") == nil)
        #expect(try await f.provider.searchItems("三體") == nil)
        let filler = ModuleFillProvider(provider: f.provider)
        #expect(!filler.canLookUp(MetadataFillQuery(copyID: UUID(), title: "三體", authors: ["劉慈欣"], identifiers: [],
                                                    copySource: .localLibrary, missing: [.intro])))
        #expect(ModuleStub.urls.isEmpty)
        #expect(try await f.provider.search("三體全") != nil)
        #expect(ModuleStub.urls.count == 1)
    }
}
