import Foundation
import Testing
@testable import yuedu_app

// Phase 6c: the module format, its validator, its store, and the list mapping a module shares
// with 來源配置.

private let exampleModule = #"""
{
  "id": "example.newbooks",
  "title": "新書速報",
  "description": "某書店的新書與排行。",
  "author": "someone",
  "site": "https://example.com",
  "version": "1.0.0",
  "requiredVersion": "2.0",
  "hosts": ["example.com", "img.example.com"],
  "rateLimit": "2/1000",
  "futureKey": { "kept": true },
  "modules": [
    {
      "id": "new",
      "title": "新書",
      "description": "每週新書",
      "cacheDuration": 3600,
      "params": [
        { "name": "category", "title": "分類", "type": "enumeration", "value": "novel",
          "enumOptions": [{ "title": "小說", "value": "novel" }, { "title": "漫畫", "value": "comic" }] },
        { "name": "size", "title": "數量", "type": "count", "value": 20 },
        { "name": "page", "title": "頁", "type": "page" }
      ],
      "request": { "url": "https://example.com/new/{{category}}?p={{page}}&n={{size}}", "method": "GET", "headers": {}, "charset": "utf-8" },
      "list": { "items": ".book-list li", "title": "h3@text", "author": ".author@text", "cover": "img@src",
                "intro": ".desc@text", "url": "a@href", "kind": ".tag@text", "language": "" }
    }
  ],
  "search": {
    "title": "搜尋",
    "request": { "url": "https://example.com/search?q={{keyword}}&p={{page}}" },
    "list": { "items": "$.data[*]", "title": "$.name", "author": "$.author", "cover": "$.cover", "url": "$.link" }
  }
}
"""#

/// The example with one change made to its JSON object.
private func example(_ change: (inout [String: Any]) -> Void) -> Data {
    var object = try! JSONSerialization.jsonObject(with: Data(exampleModule.utf8)) as! [String: Any]
    change(&object)
    return try! JSONSerialization.data(withJSONObject: object)
}

private func editEntry(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
    var modules = object["modules"] as! [[String: Any]]
    change(&modules[0])
    object["modules"] = modules
}

private func editList(_ object: inout [String: Any], _ key: String, _ value: String) {
    editEntry(&object) { entry in
        var list = entry["list"] as! [String: Any]
        list[key] = value
        entry["list"] = list
    }
}

private func editRequest(_ object: inout [String: Any], _ key: String, _ value: Any) {
    editEntry(&object) { entry in
        var request = entry["request"] as! [String: Any]
        request[key] = value
        entry["request"] = request
    }
}

private func rejection(_ data: Data, appVersion: String = "3.0") -> RuleModuleRejection? {
    do {
        _ = try RuleModuleValidator.validate(data, appVersion: appVersion)
        return nil
    } catch {
        return error
    }
}

@Suite("Rule module format")
struct RuleModuleFormatTests {
    @Test("the plan's example decodes, numbers read as text")
    func decodesExample() throws {
        let module = try RuleModuleValidator.validate(Data(exampleModule.utf8), appVersion: "3.0")
        #expect(module.id == "example.newbooks")
        #expect(module.hosts == ["example.com", "img.example.com"])
        #expect(module.rateLimit == "2/1000")
        let entry = try #require(module.modules.first)
        #expect(entry.id == "new")
        #expect(entry.cacheDuration == 3600)
        #expect(entry.params.map(\.kind) == [.enumeration, .count, .page])
        #expect(entry.params[1].value == "20", "a number in the file reads as its text")
        #expect(entry.params[0].enumOptions?.map(\.value) == ["novel", "comic"])
        #expect(entry.list.fields.name == "h3@text")
        #expect(entry.list.fields.bookUrl == "a@href")
        let search = try #require(module.search)
        #expect(search.id == nil && search.params.isEmpty, "the search entry has no id, and params may be left out")
        #expect(search.request.method == nil)
        #expect(search.list.intro == nil)
    }

    @Test("versions compare numerically, missing parts count as zero")
    func versions() throws {
        func version(_ text: String) throws -> RuleModuleVersion { try #require(RuleModuleVersion(text)) }
        #expect(try version("1.10") > version("1.9"))
        #expect(try version("3.0") == version("3"))
        #expect(try version("3.0.1") > version("3.0"))
        #expect(RuleModuleVersion("1.x") == nil)
        #expect(RuleModuleVersion("") == nil)
        #expect(RuleModuleVersion("1..2") == nil)
    }
}

@Suite("Rule module validator")
struct RuleModuleValidatorTests {
    @Test("a clean module passes")
    func clean() {
        #expect(rejection(Data(exampleModule.utf8)) == nil)
    }

    @Test("size and entry limits")
    func limits() {
        let large = example { $0["description"] = String(repeating: "字", count: 90_000) }
        #expect(large.count > RuleModuleValidator.maxBytes)
        #expect(rejection(large) == .tooLarge(bytes: large.count))

        let many = example { object in
            let entry = (object["modules"] as! [[String: Any]])[0]
            object["modules"] = (0...RuleModuleValidator.maxEntries).map { index in
                var copy = entry
                copy["id"] = "e\(index)"
                return copy
            }
        }
        #expect(rejection(many) == .tooManyEntries(51))
        #expect(rejection(example {
            $0["modules"] = []
            $0["search"] = nil
        }) == .noEntries)
    }

    @Test("not JSON, missing and mistyped fields are named")
    func shape() {
        #expect(rejection(Data("not json".utf8)) == .notJSON)
        #expect(rejection(example { $0["version"] = nil }) == .missingField("version"))
        #expect(rejection(example { $0["hosts"] = "example.com" }) == .malformed(field: "hosts"))
        #expect(rejection(example { editEntry(&$0) { $0["request"] = nil } }) == .missingField("modules[0].request"))
        #expect(rejection(example { editEntry(&$0) { $0["title"] = " " } }) == .missingField("modules[0].title"))
        #expect(rejection(example { editEntry(&$0) { $0["id"] = nil } }) == .missingField("modules[0].id"))
        #expect(rejection(example { $0["title"] = "" }) == .missingField("title"))
        #expect(rejection(example { editList(&$0, "title", "") }) == .emptyRule(field: "modules[0].list.title"))
        #expect(rejection(example { editList(&$0, "items", " ") }) == .emptyRule(field: "modules[0].list.items"))
    }

    @Test("ids must be file-safe and entries unique")
    func ids() {
        #expect(rejection(example { $0["id"] = "../escape" }) == .invalidID("../escape"))
        #expect(rejection(example { $0["id"] = "新書" }) == .invalidID("新書"))
        #expect(rejection(example { $0["id"] = ".." }) == .invalidID(".."))
        #expect(rejection(example { object in
            let entry = (object["modules"] as! [[String: Any]])[0]
            object["modules"] = [entry, entry]
        }) == .duplicateEntryID("new"))
    }

    @Test("versions: its own must be numeric, and the app must be new enough")
    func appVersion() {
        #expect(rejection(example { $0["version"] = "one" }) == .invalidVersion(field: "version", value: "one"))
        #expect(rejection(example { $0["requiredVersion"] = "3.x" }) == .invalidVersion(field: "requiredVersion", value: "3.x"))
        #expect(rejection(Data(exampleModule.utf8), appVersion: "1.9.9") == .requiresNewerApp(required: "2.0", running: "1.9.9"))
        #expect(rejection(Data(exampleModule.utf8), appVersion: "2.0.1") == nil)
        #expect((try? RuleModuleValidator.validate(Data(exampleModule.utf8))) != nil, "the running app reads the plan's example")
        #expect(rejection(example { $0["requiredVersion"] = nil }, appVersion: "1.0") == nil)
    }

    @Test("JavaScript is refused wherever it appears")
    func javaScript() {
        #expect(rejection(example { editList(&$0, "title", "h3@text@js:result.trim()") }) == .javaScript(field: "modules[0].list.title"))
        #expect(rejection(example { editList(&$0, "cover", "<js>'x'</js>") }) == .javaScript(field: "modules[0].list.cover"))
        #expect(rejection(example { editRequest(&$0, "url", "@js:'https://example.com/'") }) == .javaScript(field: "modules[0].request.url"))
    }

    @Test("@get and @put are refused: v1 has no variables")
    func variables() {
        #expect(rejection(example { editList(&$0, "url", "a@href@put:{id:a@href}") }) == .variables(field: "modules[0].list.url"))
        #expect(rejection(example { editRequest(&$0, "url", "https://example.com/@get:{id}") }) == .variables(field: "modules[0].request.url"))
    }

    @Test("every template is a declared parameter, paging, or the search keyword")
    func templates() {
        #expect(rejection(example { editRequest(&$0, "url", "https://example.com/new?sort={{sort}}") })
                == .undeclaredTemplate(field: "modules[0].request.url", name: "sort"))
        #expect(rejection(example { editRequest(&$0, "url", "https://example.com/new?q={{keyword}}") })
                == .undeclaredTemplate(field: "modules[0].request.url", name: "keyword"), "keyword belongs to search")
        #expect(rejection(example { editRequest(&$0, "body", "o={{offset}}&c={{category}}") }) == nil)
        #expect(rejection(example { editRequest(&$0, "headers", ["X-Token": "{{token}}"]) })
                == .undeclaredTemplate(field: "modules[0].request.headers.X-Token", name: "token"))
        #expect(rejection(example { editList(&$0, "intro", ".desc@text{{page}}") })
                == .undeclaredTemplate(field: "modules[0].list.intro", name: "page"), "a list rule fills no parameters")
    }

    @Test("parameters: known types, options for an enumeration")
    func params() {
        #expect(rejection(example { editEntry(&$0) { $0["params"] = [["name": "x", "type": "slider"]] } })
                == .unknownParamType(field: "modules[0].params[0].type", type: "slider"))
        #expect(rejection(example { editEntry(&$0) { $0["params"] = [["name": "category", "type": "enumeration"]] } })
                == .enumerationWithoutOptions(field: "modules[0].params[0].enumOptions"))
    }

    @Test("requests: GET or POST, http(s), to a listed host")
    func requests() {
        #expect(rejection(example { editRequest(&$0, "method", "PUT") }) == .unsupportedMethod(field: "modules[0].request.method", method: "PUT"))
        #expect(rejection(example { editRequest(&$0, "method", "post") }) == nil)
        #expect(rejection(example { editRequest(&$0, "url", "ftp://example.com/x") }) == .invalidURL(field: "modules[0].request.url"))
        #expect(rejection(example { editRequest(&$0, "url", "/relative/{{page}}") }) == .invalidURL(field: "modules[0].request.url"))
        #expect(rejection(example { editRequest(&$0, "url", "https://evil.example/new") })
                == .hostNotAllowed(field: "modules[0].request.url", host: "evil.example"))
        #expect(rejection(example { editRequest(&$0, "url", "https://{{category}}.example.com/") })
                == .hostNotAllowed(field: "modules[0].request.url", host: "{{category}}.example.com"))
        #expect(rejection(example { editRequest(&$0, "url", #"https://example.com/x,{"webView":true,"js":"1"}"#) })
                == .urlOptions(field: "modules[0].request.url"))
        #expect(rejection(example { editRequest(&$0, "url", "https://example.com/x?ids=1,{{page}}") }) == nil,
                "a template after a comma is filled before Legado would split")
        #expect(rejection(example { editRequest(&$0, "url", "https://IMG.example.com:8443/new?p={{page}}") }) == nil,
                "hosts compare without case, and a port is not part of the host")
    }
}

@Suite("Rule module store", .serialized)
struct RuleModuleStoreTests {
    private func makeStore() throws -> (RuleModuleStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuleModules-\(UUID().uuidString)")
        return (RuleModuleStore(directory: folder), folder)
    }

    @Test("install keeps the bytes as written and where they came from")
    func install() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = URL(string: "https://example.com/module.json")!
        let data = Data(exampleModule.utf8)
        let installed = try store.install(data, from: source, appVersion: "3.0", now: Date(timeIntervalSince1970: 100))
        #expect(installed.module.id == "example.newbooks")
        #expect(try store.data(id: "example.newbooks") == data, "unknown keys round-trip")

        let listing = store.list(appVersion: "3.0")
        #expect(listing.failures.isEmpty)
        #expect(listing.modules == [installed])
        #expect(listing.modules.first?.subscriptionURL == source)

        #expect(throws: RuleModuleStoreError.alreadyInstalled("example.newbooks")) {
            try store.install(data, from: nil, appVersion: "3.0")
        }
        #expect(throws: RuleModuleStoreError.rejected(.notJSON)) { try store.install(Data("{".utf8), from: nil, appVersion: "3.0") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["example.newbooks"], "no staging folder is left behind")
    }

    @Test("update needs a newer version of the same module, and drops its cache")
    func update() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.install(Data(exampleModule.utf8), from: nil, appVersion: "3.0", now: Date(timeIntervalSince1970: 100))
        let cache = store.cacheDirectory(id: "example.newbooks")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("page".utf8).write(to: cache.appendingPathComponent("p1"))

        #expect(throws: RuleModuleStoreError.notNewer(installed: "1.0.0", offered: "1.0")) {
            try store.update(id: "example.newbooks", with: example { $0["version"] = "1.0" }, appVersion: "3.0")
        }
        #expect(throws: RuleModuleStoreError.differentModule(expected: "example.newbooks", offered: "other")) {
            try store.update(id: "example.newbooks", with: example {
                $0["id"] = "other"
                $0["version"] = "2"
            }, appVersion: "3.0")
        }
        #expect(throws: RuleModuleStoreError.notInstalled("missing")) {
            try store.update(id: "missing", with: Data(exampleModule.utf8), appVersion: "3.0")
        }

        let newer = example { $0["version"] = "1.0.10" }
        let updated = try store.update(id: "example.newbooks", with: newer, appVersion: "3.0", now: Date(timeIntervalSince1970: 200))
        #expect(updated.module.version == "1.0.10")
        #expect(updated.installedAt == Date(timeIntervalSince1970: 100))
        #expect(updated.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(try store.data(id: "example.newbooks") == newer)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("remove deletes the folder, cache included")
    func remove() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.install(Data(exampleModule.utf8), from: nil, appVersion: "3.0")
        try FileManager.default.createDirectory(at: store.cacheDirectory(id: "example.newbooks"), withIntermediateDirectories: true)
        try store.remove(id: "example.newbooks")
        #expect(store.list(appVersion: "3.0").modules.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("example.newbooks").path))
        #expect(throws: RuleModuleStoreError.notInstalled("example.newbooks")) { try store.remove(id: "example.newbooks") }
        #expect(throws: RuleModuleStoreError.notInstalled("..")) { try store.remove(id: "..") }
    }

    @Test("a corrupt file is reported and skipped, never overwritten")
    func corrupt() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.install(Data(exampleModule.utf8), from: nil, appVersion: "3.0")
        let other = example {
            $0["id"] = "other"
            $0["version"] = "1"
        }
        try store.install(other, from: nil, appVersion: "3.0")
        let broken = folder.appendingPathComponent("other/module.json")
        try Data("{ broken".utf8).write(to: broken)

        let listing = store.list(appVersion: "3.0")
        #expect(listing.modules.map(\.module.id) == ["example.newbooks"])
        #expect(listing.failures.map(\.folder) == ["other"])
        #expect(throws: RuleModuleStoreError.alreadyInstalled("other")) { try store.install(other, from: nil, appVersion: "3.0") }
        #expect(try Data(contentsOf: broken) == Data("{ broken".utf8))

        #expect(store.list(appVersion: "1.0").failures.map(\.folder) == ["example.newbooks", "other"],
                "a module the running app is too old for is reported, not dropped")
    }

    @Test("no folder yet lists nothing")
    func empty() throws {
        let (store, _) = try makeStore()
        let listing = store.list(appVersion: "3.0")
        #expect(listing.modules.isEmpty && listing.failures.isEmpty)
    }
}

@Suite("Rule list mapping")
struct RuleListMappingTests {
    private let html = #"""
    <ul>
      <li class="book"><a href="/book/1">First</a><span class="author">甲</span><img src="/c/1.jpg"/>
        <p class="desc">One</p><i class="tag">奇幻</i><i class="tag">冒險</i><b>12萬字</b><em>第10章</em></li>
      <li class="book"><a href="/book/2"></a><span class="author">乙</span></li>
      <li class="book"><a href="/book/3">Third</a><span class="author">丙</span></li>
    </ul>
    """#

    private func source() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com"
        source.bookSourceName = "例"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.author = ".author@text"
        source.ruleSearch.bookUrl = "a@href"
        source.ruleSearch.coverUrl = "img@src"
        source.ruleSearch.intro = ".desc@text"
        source.ruleSearch.kind = ".tag@text"
        source.ruleSearch.wordCount = "b@text"
        source.ruleSearch.lastChapter = "em@text"
        return source
    }

    private func fields(_ rule: SearchRule) -> RuleListFields {
        RuleListFields(name: rule.name, author: rule.author, bookUrl: rule.bookUrl, coverUrl: rule.coverUrl,
                       intro: rule.intro, wordCount: rule.wordCount, lastChapter: rule.lastChapter, kind: rule.kind)
    }

    @Test("a 來源配置's search list reads the same through the bridge and the mapping")
    func searchParity() throws {
        let source = source()
        let base = "https://example.com/search?key=x"
        let bridged = try ModernParserBridge(source: source).parseSearchResults(html: html, baseURL: base, source: source)
        let mapped = RuleListMapping.items(engine: ModernRuleEngine(), content: html, baseURL: base,
                                           listRule: source.ruleSearch.bookList, fields: fields(source.ruleSearch))
        #expect(mapped.map(\.name) == ["First", "Third"], "an item with no name is skipped")
        #expect(mapped.first == RuleListItem(name: "First", author: "甲", bookUrl: "https://example.com/book/1",
                                             coverUrl: "https://example.com/c/1.jpg", intro: "One", wordCount: "12萬字",
                                             lastChapter: "第10章", kind: "奇幻,冒險"))
        #expect(bridged.map(\.name) == mapped.map(\.name))
        #expect(bridged.map(\.bookUrl) == mapped.map(\.bookUrl))
        #expect(bridged.map(\.coverUrl) == mapped.map(\.coverUrl))
        #expect(bridged.map(\.kind) == mapped.map(\.kind))
        #expect(bridged.allSatisfy { $0.tocUrl.isEmpty && $0.sourceId == source.id && $0.sourceName == "例" })

        let explored = ModernParserBridge(source: source).parseExploreResults(html: html, baseURL: base, source: source)
        #expect(explored.map(\.author) == mapped.map(\.author), "explore reuses the search rules through the same mapping")
    }

    @Test("explore's own rules fill every slot")
    func exploreOwnRules() {
        var source = source()
        source.ruleExplore.bookList = "li.book"
        source.ruleExplore.name = "em@text"
        source.ruleExplore.author = "b@text"
        source.ruleExplore.bookUrl = "img@src"
        source.ruleExplore.coverUrl = "a@href"
        source.ruleExplore.intro = ".author@text"
        source.ruleExplore.wordCount = ".desc@text"
        source.ruleExplore.lastChapter = "a@text"
        source.ruleExplore.kind = "i.tag@text"
        let books = ModernParserBridge(source: source).parseExploreResults(html: html, baseURL: "https://example.com", source: source)
        let first = books.first
        #expect(books.count == 1, "only the first item has an em")
        #expect(first?.name == "第10章")
        #expect(first?.author == "12萬字")
        #expect(first?.bookUrl == "https://example.com/c/1.jpg")
        #expect(first?.coverUrl == "https://example.com/book/1")
        #expect(first?.intro == "甲")
        #expect(first?.wordCount == "One")
        #expect(first?.lastChapter == "First")
        #expect(first?.kind == "奇幻,冒險")
    }

    @Test("the early filter skips an item before its other fields are read")
    func earlyFilter() throws {
        let source = source()
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: html, baseURL: "https://example.com", source: source, earlyFilter: { _, author in author == "丙" })
        #expect(books.map(\.name) == ["Third"])
    }

    @Test("a module's JSON list maps through the same helper")
    func moduleJSON() throws {
        let module = try RuleModuleValidator.validate(Data(exampleModule.utf8), appVersion: "3.0")
        let list = try #require(module.search?.list)
        let json = #"{"data":[{"name":"甲書","author":"甲","cover":"https://img.example.com/1.jpg","link":"/b/1"},{"name":"","link":"/b/2"}]}"#
        let items = RuleListMapping.items(engine: ModernRuleEngine(), content: json, baseURL: "https://example.com/search",
                                          listRule: list.items, fields: list.fields)
        #expect(items == [RuleListItem(name: "甲書", author: "甲", bookUrl: "https://example.com/b/1",
                                       coverUrl: "https://img.example.com/1.jpg", intro: "", wordCount: "", lastChapter: "", kind: "")])
    }

    @Test("an empty list rule reads nothing")
    func emptyListRule() {
        #expect(RuleListMapping.items(engine: ModernRuleEngine(), content: html, baseURL: "https://example.com",
                                      listRule: "", fields: fields(source().ruleSearch)).isEmpty)
    }
}
