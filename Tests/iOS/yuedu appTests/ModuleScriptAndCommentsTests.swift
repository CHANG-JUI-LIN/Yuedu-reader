import Combine
import CryptoKit
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Format 3.0.2's `javascript` (scripts that compute and never connect) and `comments` (本章說:
/// a chapter's comments for any book). Every reply here is made up: no site's readers are quoted.
@MainActor
@Suite("Module scripts and chapter comments", .serialized)
struct ModuleScriptAndCommentsTests {
    // MARK: - Fixture

    private func module(_ object: [String: Any], id: String = "c.test") -> Data {
        var base: [String: Any] = ["id": id, "title": "評論站", "version": "1.0", "requiredVersion": "3.0.2",
                                   "hosts": ["example.com"], "modules": [[String: Any]]()]
        base.merge(object) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: base)
    }

    private var search: [String: Any] {
        ["request": ["url": "https://example.com/s?q={{keyword}}"],
         "list": ["items": "$.books[*]", "title": "$.title", "author": "$.author", "url": "$.href", "id": "$.id"]]
    }

    private func comments(_ chapter: [String: Any] = [:]) -> [String: Any] {
        var block: [String: Any] = [
            "request": ["url": "https://example.com/c/{{chapterId}}?sort={{sort}}&p={{page}}"],
            "sorts": [["title": "最熱", "value": "hot"], ["title": "最新", "value": "new"]],
            "list": ["items": "$.list[*]", "text": "$.content", "author": "$.user", "likes": "$.likes"],
        ]
        block.merge(chapter) { _, new in new }
        return ["chapters": ["request": ["url": "https://example.com/b/{{id}}/chapters"],
                             "list": ["items": "$.chapters[*]", "id": "$.cid", "title": "$.name"]],
                "chapter": block]
    }

    private func rejection(_ data: Data, appVersion: String = "3.0.2") -> RuleModuleRejection? {
        do { _ = try RuleModuleValidator.validate(data, appVersion: appVersion); return nil } catch { return error }
    }

    private struct Fixture {
        let module: RuleModule
        let client: RuleModuleClient
        let library: RuleModuleLibrary
        let order: MetadataFillOrderStore
        let folder: URL
        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    private func fixture(_ object: [String: Any], id: String = "c.test") async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleComments-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.2", officialFiles: { [] })
        let installed = try await library.install(module(object, id: id), from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        let suite = "ModuleComments-\(UUID().uuidString)"
        return Fixture(module: installed, client: client, library: library,
                       order: MetadataFillOrderStore(defaults: UserDefaults(suiteName: suite)!), folder: folder)
    }

    private static let localTitles = ["序章", "第一章 相遇", "第二章 離別", "第三章 風起", "第四章 雲湧", "第五章 歸途", "第六章 終局"]
    /// The site's edition: a 番外 between chapters two and three, so every later chapter stands one further on.
    private static let remoteChapters = """
    {"chapters":[
      {"cid":"a0","name":"序章"},{"cid":"a1","name":"第1章 相遇"},{"cid":"a2","name":"第2章 離別"},
      {"cid":"ax","name":"番外 那一年"},
      {"cid":"a3","name":"第3章 風起"},{"cid":"a4","name":"第4章 雲湧"},{"cid":"a5","name":"第5章 歸途"},{"cid":"a6","name":"第6章 終局"}
    ]}
    """

    private func query(_ chapter: String, authors: [String] = ["某作者"], titles: [String] = localTitles) -> ChapterCommentQuery {
        ChapterCommentQuery(work: WorkReviewQuery(title: "長夜", authors: authors, contentKind: .text),
                            chapterTitle: chapter, chapterTitles: titles)
    }

    // MARK: - The script context

    @Test("a script has java's listed functions and nothing that reaches outside")
    func surface() {
        let runtime = RuleModuleScriptRuntime(moduleID: "surface")
        let surface = runtime.surface()
        #expect(surface.java == RuleModuleScriptRuntime.functions.sorted(), "java's own functions are the allowlist, no more")
        #expect(!surface.hasNetworkGlobals, "no fetch, XMLHttpRequest, timers, Packages, cookie, source or cache")
        #expect(runtime.evaluate("typeof java.ajax + typeof java.connect + typeof java.get + typeof java.webView", bindings: [:])
                == "undefinedundefinedundefinedundefined", "the 來源配置 runtime's requests are not here")
        #expect(runtime.evaluate("eval('1+1')", bindings: [:]) == nil, "eval is off")
    }

    @Test("java's digests, HMAC, Base64 and ciphers give the values a site would check")
    func functions() {
        let runtime = RuleModuleScriptRuntime(moduleID: "functions")
        #expect(runtime.evaluate("java.md5Encode('abc')", bindings: [:]) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(runtime.evaluate("java.md5Encode16('abc')", bindings: [:]) == "3cd24fb0d6963f7d")
        #expect(runtime.evaluate("java.digestHex('abc', 'SHA-256')", bindings: [:])
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(runtime.evaluate("java.HMacHex('The quick brown fox jumps over the lazy dog', 'HmacSHA256', 'key')", bindings: [:])
                == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(runtime.evaluate("java.base64Decode(java.base64Encode('三體'))", bindings: [:]) == "三體")
        #expect(runtime.evaluate("java.hexDecodeToString(java.hexEncodeToString('三體'))", bindings: [:]) == "三體")
        let cipher = "java.aesBase64DecodeToString(java.aesEncodeToBase64String('本章說', '0123456789abcdef', 'AES/CBC/PKCS5Padding', 'fedcba9876543210'), '0123456789abcdef', 'AES/CBC/PKCS5Padding', 'fedcba9876543210')"
        #expect(runtime.evaluate(cipher, bindings: [:]) == "本章說")
        #expect(runtime.evaluate("JSON.parse(result).a + baseUrl", bindings: ["result": #"{"a":"x"}"#, "baseUrl": "/b"]) == "x/b")
        #expect(runtime.evaluate("({a: [1, 2]})", bindings: [:]) == #"{"a":[1,2]}"#, "an object is its JSON")
        #expect(runtime.evaluate("null", bindings: [:]) == nil)
        #expect(runtime.evaluate("throw new Error('x')", bindings: [:]) == nil)
        #expect(runtime.evaluate("1 + 1", bindings: [:]) == "2", "an exception leaves the context usable")
    }

    @Test("a script that never ends is given up on, and the module's scripts stay off")
    func runaway() {
        let runtime = RuleModuleScriptRuntime(moduleID: "runaway")
        #expect(runtime.evaluate("1 + 1", bindings: [:]) == "2")
        let started = Date()
        #expect(runtime.evaluate("while (true) {}", bindings: [:]) == nil)
        #expect(Date().timeIntervalSince(started) < RuleModuleScriptRuntime.timeout + 2)
        #expect(runtime.evaluate("1 + 1", bindings: [:]) == nil, "its context is still held by the script that ran away")
    }

    // MARK: - Validator

    @Test("JavaScript is the module's to declare: with `javascript` a rule and a request may script, without it neither")
    func declared() throws {
        var scripted = search
        scripted["list"] = ["items": "$.books[*]", "title": "$.title@js:result + '!'", "url": "$.href", "id": "$.id"]
        #expect(rejection(module(["search": scripted])) == .javaScript(field: "search.list.title"))
        let accepted = try RuleModuleValidator.validate(module(["search": scripted, "javascript": true]), appVersion: "3.0.2")
        #expect(accepted.javascript == true)

        var signed = search
        signed["request"] = ["url": "https://example.com/s?q={{keyword}}", "script": "request.url += '&sign=1'"]
        #expect(rejection(module(["search": signed])) == .javaScript(field: "search.request.script"))
        #expect(rejection(module(["search": signed, "javascript": true])) == nil)
        signed["request"] = ["url": "https://example.com/s?q={{keyword}}", "script": "  "]
        #expect(rejection(module(["search": signed, "javascript": true])) == .missingField("search.request.script"))

        var old = module(["search": search, "javascript": true])
        old = try JSONSerialization.data(withJSONObject: (try JSONSerialization.jsonObject(with: old) as! [String: Any])
            .merging(["requiredVersion": "3.0.1"]) { _, new in new })
        #expect(rejection(old) == .needsRequiredVersion(field: "javascript", minimum: "3.0.2"))
        #expect(rejection(module(["search": search, "javascript": true, "reading": [
            "toc": ["items": "li", "title": "a@text", "url": "a@href"], "content": ["text": "@get:x"],
        ]])) == .variables(field: "reading.content.text"), "variables stay refused")
    }

    @Test("a comments block needs a record to ask of, a chapter to ask about, and its orders declared")
    func commentsValidated() throws {
        let accepted = try RuleModuleValidator.validate(module(["search": search, "comments": comments()]), appVersion: "3.0.2")
        #expect(accepted.comments?.chapter.sorts?.map(\.value) == ["hot", "new"])
        #expect(rejection(module(["modules": [["id": "a", "title": "a", "request": ["url": "https://example.com/a"],
                                               "list": ["items": "li", "title": "h3@text"]]],
                                  "comments": comments()])) == .missingField("search"))
        #expect(rejection(module(["search": search, "comments": comments(["request": ["url": "https://example.com/c?p={{page}}"], "sorts": NSNull()])]))
                == .missingField("comments.chapter.request.url {{chapterId}}"))
        #expect(rejection(module(["search": search, "comments": comments(["request": ["url": "https://other.example/c/{{chapterId}}?sort={{sort}}"]])]))
                == .hostNotAllowed(field: "comments.chapter.request.url", host: "other.example"))
        #expect(rejection(module(["search": search, "comments": comments(["sorts": NSNull()])]))
                == .missingField("comments.chapter.sorts"), "{{sort}} with no order to send")
        #expect(rejection(module(["search": search, "comments": comments(["list": ["items": "$.list[*]", "text": " "]])]))
                == .emptyRule(field: "comments.chapter.list.text"))
    }

    // MARK: - Scripts in requests and rules

    @Test("a request's script signs the address; a rule's script reads the reply; both through the module's own request")
    func signs() async throws {
        var scripted = search
        scripted["request"] = ["url": "https://example.com/s?q={{keyword}}",
                               "script": "request.url += '&sign=' + java.md5Encode(values.keyword + 'salt')"]
        scripted["list"] = ["items": "@js:JSON.parse(java.base64Decode(JSON.parse(result).data)).books",
                            "title": "$.title@js:result + '（完）'", "author": "$.author", "url": "$.href", "id": "$.id"]
        let f = try await fixture(["search": scripted, "javascript": true], id: "c.signs")
        defer { f.cleanUp() }
        let payload = Data(#"{"books":[{"title":"長夜","author":"某作者","href":"/b/7","id":7}]}"#.utf8).base64EncodedString()
        ModuleStub.install(["example.com/s": .json(#"{"data":"\#(payload)"}"#)])
        let items = try #require(try await ModuleProvider(module: f.module, client: f.client).searchItems("長夜"))
        #expect(items.map(\.name) == ["長夜（完）"], "the list is the script's, each title its rule's then its script's")
        #expect(items.first?.id == "7")
        let sign = Insecure.MD5.hash(data: Data("長夜salt".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(ModuleStub.urls == ["https://example.com/s?q=%E9%95%B7%E5%A4%9C&sign=\(sign)"], "the signature the script computed is what was sent")
    }

    @Test("a script cannot send a request past the module's hosts: nothing leaves")
    func hostsHold() async throws {
        var scripted = search
        scripted["request"] = ["url": "https://example.com/s?q={{keyword}}",
                               "script": "request.url = 'https://other.example/steal?q=' + values.keyword"]
        let f = try await fixture(["search": scripted, "javascript": true], id: "c.hosts")
        defer { f.cleanUp() }
        ModuleStub.install(["other.example/steal": .json("{}"), "example.com/s": .json(#"{"books":[]}"#)])
        await #expect(throws: (any Error).self) {
            _ = try await ModuleProvider(module: f.module, client: f.client).searchItems("長夜")
        }
        #expect(ModuleStub.urls.isEmpty, "refused before it is sent")
    }

    // MARK: - Chapter titles

    @Test("a chapter title is its number and its name, however the edition writes the number")
    func keys() {
        typealias Key = ChapterTitleMatch.Key
        #expect(ChapterTitleMatch.key("第十二章 風起") == Key(number: 12, name: "风起"))
        #expect(ChapterTitleMatch.key("第12章：風起") == Key(number: 12, name: "风起"))
        #expect(ChapterTitleMatch.key("Chapter 12 風起") == Key(number: 12, name: "风起"))
        #expect(ChapterTitleMatch.key("012 風起") == Key(number: 12, name: "风起"))
        #expect(ChapterTitleMatch.key("第一千二百三十四回") == Key(number: 1234, name: ""))
        #expect(ChapterTitleMatch.key("第二〇三章 夜") == Key(number: 203, name: "夜"))
        #expect(ChapterTitleMatch.key("序章") == Key(number: nil, name: "序章"))
        #expect(ChapterTitleMatch.key("一九八四") == Key(number: nil, name: "一九八四"), "a title of numerals is a name")
        #expect(ChapterTitleMatch.number("十") == 10 && ChapterTitleMatch.number("二十") == 20 && ChapterTitleMatch.number("一万零五") == 10_005)
    }

    @Test("a chapter is matched by what it is called, never by where it stands; one that cannot be told is not matched")
    func positions() {
        let remote = ["序章", "第1章 相遇", "第2章 離別", "番外 那一年", "第3章 風起", "第1章 相遇"]
        let index = ChapterTitleMatch.Index(titles: remote)
        let numbers = ChapterTitleMatch.numberCounts(Self.localTitles)
        #expect(index.position(of: "第三章 風起", localNumbers: numbers) == 4, "past the 番外 the reader's copy does not have")
        #expect(index.position(of: "序章", localNumbers: numbers) == 0)
        #expect(index.position(of: "第二章 离别", localNumbers: numbers) == 2, "another script, another numeral")
        #expect(index.position(of: "第一章 相遇", localNumbers: numbers) == nil, "the site has two of it")
        #expect(index.position(of: "第九章 沒有的章", localNumbers: numbers) == nil)
        // The editions title a chapter differently: its number tells it, when that number is one chapter's on both sides.
        #expect(index.position(of: "第三章 起風了", localNumbers: numbers) == 4)
        #expect(index.position(of: "第二章", localNumbers: numbers) == 2)
        #expect(index.position(of: "第三章 起風了", localNumbers: [3: 2]) == nil, "the reader's own copy has two chapter threes: volumes that start again")
        #expect(ChapterTitleMatch.Index(titles: ["第1章 甲", "第1章 乙"]).position(of: "第一章 丙", localNumbers: [1: 1]) == nil)
    }

    @Test("without an author a book is the site's when four fifths of its chapters are there, and five at least")
    func sameBook() {
        let remote = ["序章", "第1章 相遇", "第2章 離別", "番外 那一年", "第3章 風起", "第4章 雲湧", "第5章 歸途", "第6章 終局"]
        #expect(ChapterTitleMatch.isSameBook(localTitles: Self.localTitles, remoteTitles: remote))
        let other = ["楔子", "第1章 開端", "第2章 風波", "第3章 暗流", "第4章 交鋒", "第5章 落幕", "第6章 尾聲"]
        #expect(!ChapterTitleMatch.isSameBook(localTitles: Self.localTitles, remoteTitles: other), "the same numbers, another book's names")
        #expect(!ChapterTitleMatch.isSameBook(localTitles: ["序", "正文", "後記"], remoteTitles: ["序", "正文", "後記"]), "three chapters every book has")
        #expect(!ChapterTitleMatch.isSameBook(localTitles: [], remoteTitles: remote))
    }

    // MARK: - 本章說

    @Test("the chapter's comments are asked by the id the site's chapter list gave it")
    func thread() async throws {
        let f = try await fixture(["search": search, "comments": comments()])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"長夜","author":"某作者","href":"/b/7","id":7}]}"#),
            "example.com/b/7/chapters": .json(Self.remoteChapters),
            "example.com/c/a3": .json(#"{"list":[{"content":"伏筆在這裡。","user":"讀者甲","likes":9},{"content":" ","user":"空的"}]}"#),
            // A plausible-wrong answer: the chapter at the reader's own position (index 3) is the 番外.
            "example.com/c/ax": .json(#"{"list":[{"content":"番外的評論","user":"讀者乙"}]}"#),
        ])
        let thread = try #require(await ChapterComments.thread(for: query("第三章 風起"), library: f.library, order: f.order, client: f.client))
        #expect(thread.chapter == ModuleCommentChapter(id: "a3", title: "第3章 風起"))
        #expect(thread.module.id == "c.test" && thread.record.id == "7")
        #expect(thread.sorts.map(\.title) == ["最熱", "最新"])
        let found = try await ChapterComments.comments(in: thread, sort: "new", page: 2, client: f.client).comments
        #expect(found.map(\.text) == ["伏筆在這裡。"] && found.first?.author == "讀者甲" && found.first?.likes == 9)
        #expect(found.allSatisfy { $0.rating == nil })
        #expect(ModuleStub.urls == [
            "https://example.com/s?q=%E9%95%B7%E5%A4%9C", "https://example.com/b/7/chapters",
            "https://example.com/c/a3?sort=new&p=2",
        ], "the id sent is the one the chapter list returned, with the order and the page asked for")
        #expect(await ChapterComments.thread(for: query("第九章 沒有的章"), library: f.library, order: f.order, client: f.client) == nil)
    }

    @Test("a book with no author is the site's only when its chapters are; another book of the same title shows nothing")
    func titleOnly() async throws {
        let f = try await fixture(["search": search, "comments": comments()])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"長夜","author":"別人","href":"/b/1","id":1},{"title":"長夜","author":"某作者","href":"/b/7","id":7},{"title":"長夜漫漫","author":"某作者","href":"/b/8","id":8}]}"#),
            // The first 長夜 is another book: it has a 第三章 too, under another name.
            "example.com/b/1/chapters": .json(#"{"chapters":[{"cid":"z1","name":"第1章 開端"},{"cid":"z2","name":"第2章 風波"},{"cid":"z3","name":"第3章 暗流"},{"cid":"z4","name":"第4章 交鋒"},{"cid":"z5","name":"第5章 落幕"},{"cid":"z6","name":"第6章 尾聲"}]}"#),
            "example.com/b/7/chapters": .json(Self.remoteChapters),
        ])
        let thread = try #require(await ChapterComments.thread(for: query("第三章 風起", authors: []), library: f.library, order: f.order, client: f.client))
        #expect(thread.record.id == "7" && thread.chapter.id == "a3", "past the other 長夜, whose chapters are not this book's")
        #expect(!ModuleStub.urls.contains { $0.contains("/b/8/") }, "長夜漫漫 is another title")

        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"長夜","author":"別人","href":"/b/1","id":1}]}"#),
            "example.com/b/1/chapters": .json(#"{"chapters":[{"cid":"z1","name":"第1章 開端"},{"cid":"z2","name":"第2章 風波"},{"cid":"z3","name":"第3章 暗流"},{"cid":"z4","name":"第4章 交鋒"},{"cid":"z5","name":"第5章 落幕"},{"cid":"z6","name":"第6章 尾聲"}]}"#),
            "example.com/c/z3": .json(#"{"list":[{"content":"別本書的評論","user":"讀者丙"}]}"#),
        ])
        // The chapter list is cached by the block's `cacheDuration` only: this one sets none.
        #expect(await ChapterComments.thread(for: query("第三章 風起", authors: []), library: f.library, order: f.order, client: f.client) == nil,
                "its chapter three has the same number; it is still not this book")
        #expect(!ModuleStub.urls.contains { $0.contains("/c/") }, "no comments are asked for a book that is not the reader's")
    }

    @Test("the page reads on while a page brings something new, and stops at one that repeats")
    func paging() async {
        let thread = ChapterCommentThread(
            module: RuleModule(id: "m", title: "評論站", version: "1.0", hosts: ["example.com"], modules: []),
            record: RuleListItem(name: "長夜", author: "", bookUrl: "", coverUrl: "", intro: "", wordCount: "", lastChapter: "", kind: ""),
            chapter: ModuleCommentChapter(id: "a3", title: "第3章 風起"))
        var asked: [Int] = []
        let model = ChapterCommentsModel(heading: "第三章 風起", findThread: { thread }, readPage: { _, _, _, page in
            asked.append(page)
            let first = WorkReview(title: nil, text: "一", author: "甲", date: nil, rating: nil, likes: nil)
            let second = WorkReview(title: nil, text: "二", author: "乙", date: nil, rating: nil, likes: nil)
            // A site that ignores the page: page 3 is page 2 again.
            return page == 1 ? [first] : [second]
        })
        await model.load()
        #expect(model.phase == .loaded && model.comments.map(\.text) == ["一"] && model.hasMore)
        await model.loadMore()
        #expect(model.comments.map(\.text) == ["一", "二"] && model.hasMore)
        await model.loadMore()
        #expect(model.comments.map(\.text) == ["一", "二"] && !model.hasMore, "nothing new: the end")
        await model.loadMore()
        #expect(asked == [1, 2, 3])

        let none = ChapterCommentsModel(heading: "第三章 風起", findThread: { nil }, readPage: { _, _, _, _ in [] })
        await none.load()
        #expect(none.phase == .unavailable)
    }

    // MARK: - 段評, 熱評, 作者說 in the text

    private func notesBlock() -> [String: Any] {
        var block = comments(["total": "$.total"])
        block["paragraph"] = ["request": ["url": "https://example.com/c/{{chapterId}}/p/{{paragraphId}}?p={{page}}"],
                              "list": ["items": "$.list[*]", "text": "$.content", "author": "$.user"]]
        block["counts"] = ["request": ["url": "https://example.com/c/{{chapterId}}/counts"],
                           "list": ["items": "$.paragraphs[*]", "count": "$.n", "quote": "$.text", "index": "$.no", "id": "$.pid"]]
        block["hot"] = ["request": ["url": "https://example.com/c/{{chapterId}}/hot"],
                        "list": ["items": "$.hot[*]", "text": "$.content", "author": "$.user", "likes": "$.likes", "quote": "$.para"]]
        block["authorSay"] = ["request": ["url": "https://example.com/c/{{chapterId}}/say"], "text": "$.say", "author": "$.author"]
        return block
    }

    @Test("段評 needs a paragraph's comments to open, and a paragraph told by its text or by a counted number")
    func notesValidated() throws {
        let accepted = try RuleModuleValidator.validate(module(["search": search, "comments": notesBlock()]), appVersion: "3.0.2")
        #expect(accepted.comments?.counts != nil && accepted.comments?.hot != nil && accepted.comments?.authorSay != nil)
        var noParagraph = notesBlock()
        noParagraph["paragraph"] = nil
        #expect(rejection(module(["search": search, "comments": noParagraph])) == .missingField("comments.paragraph"))
        var numbered = notesBlock()
        numbered["counts"] = ["request": ["url": "https://example.com/c/{{chapterId}}/counts"],
                              "list": ["items": "$.paragraphs[*]", "count": "$.n", "index": "$.no"]]
        #expect(rejection(module(["search": search, "comments": numbered])) == .missingField("comments.counts.paragraphCount"),
                "a number alone cannot tell the reader's paragraph from the site's")
        numbered["counts"] = ["request": ["url": "https://example.com/c/{{chapterId}}/counts"], "paragraphCount": "$.count",
                              "list": ["items": "$.paragraphs[*]", "count": "$.n", "index": "$.no"]]
        #expect(rejection(module(["search": search, "comments": numbered])) == nil)
        var unnamed = notesBlock()
        unnamed["hot"] = ["request": ["url": "https://example.com/c/{{chapterId}}/hot"], "list": ["items": "$.hot[*]", "text": "$.content"]]
        #expect(rejection(module(["search": search, "comments": unnamed])) == .missingField("comments.hot.list.quote"))
        var elsewhere = notesBlock()
        elsewhere["authorSay"] = ["request": ["url": "https://example.com/say"], "text": "$.say"]
        #expect(rejection(module(["search": search, "comments": elsewhere])) == .missingField("comments.authorSay.request.url {{chapterId}}"))
    }

    @Test("a chapter's 段評 counts, 熱評 and 作者說 are read by the chapter's id; a part that fails leaves the others")
    func notes() async throws {
        let f = try await fixture(["search": search, "comments": notesBlock()], id: "c.notes")
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"長夜","author":"某作者","href":"/b/7","id":7}]}"#),
            "example.com/b/7/chapters": .json(Self.remoteChapters),
            "example.com/c/a3/counts": .json(#"{"paragraphs":[{"pid":"p9","no":2,"n":"12条","text":"　　風，起了。"},{"pid":"p10","no":3,"n":0,"text":"沒有評論的段"}]}"#),
            "example.com/c/a3/hot": .status(502),
            "example.com/c/a3/say": .json(#"{"say":"今天兩更。","author":"某作者"}"#),
            "example.com/c/a3": .json(#"{"total":"128条","list":[{"content":"伏筆。","user":"甲","likes":9}]}"#),
            "example.com/c/a3/p/p9": .json(#"{"list":[{"content":"這一段寫得好。","user":"乙"}]}"#),
        ])
        let thread = try #require(await ChapterComments.thread(for: query("第三章 風起"), library: f.library, order: f.order, client: f.client))
        let notes = await ChapterComments.notes(in: thread, client: f.client)
        #expect(notes.counts == [ModuleParagraphCount(paragraph: .init(quote: "风起了", index: 2, id: "p9"), count: 12)],
                "a paragraph with no comments has no bubble")
        #expect(notes.hot.isEmpty && notes.authorSay == ModuleAuthorSay(text: "今天兩更。", author: "某作者"))
        let chapter = try await ChapterComments.comments(in: thread, sort: nil, page: 1, client: f.client)
        #expect(chapter.total == 128 && chapter.comments.map(\.text) == ["伏筆。"])
        let paragraph = try await ChapterComments.comments(in: thread, paragraphID: "p9", sort: nil, page: 1, client: f.client)
        #expect(paragraph.comments.map(\.text) == ["這一段寫得好。"])
        #expect(ModuleStub.urls.contains("https://example.com/c/a3/p/p9?p=1"), "the paragraph's id is the one the counts gave")
    }

    @Test("a comment's paragraph is told by its text, or by its number when both editions count the same; else it has none")
    func paragraphs() {
        let chapter = "第三章 風起\n　　風，起了。\n　　「嗯。」\n　　他推開門，走進長夜。\n　　「嗯。」\n"
        let cut = ReaderTranslationText.paragraphs(in: chapter)
        let body = ChapterParagraphMatch.body(of: cut.map(\.key), title: "第三章 風起")
        #expect(body.map(\.position) == [1, 2, 3, 4], "the title is not a paragraph of the chapter")
        let keys = body.map(\.key)
        func index(_ quote: String, _ number: Int? = nil, count: Int? = nil) -> Int? {
            ChapterParagraphMatch.index(of: .init(quote: ChapterParagraphMatch.fold(quote), index: number, id: ""), in: keys, remoteCount: count)
        }
        #expect(index("他推開門") == 2, "its first words")
        #expect(index("他推开门，走进长夜。") == 2, "another script")
        #expect(index("「嗯。」") == nil, "too short to tell, and said twice")
        #expect(index("沒有這一段的文字") == nil)
        #expect(index("", 3, count: 4) == 2, "by number: both editions have four paragraphs")
        #expect(index("", 3, count: 5) == nil, "the site cut the chapter another way")
        #expect(index("", 3) == nil && index("", 9, count: 4) == nil)
    }

    @Test("what is added to a chapter owns none of its characters: positions are where they were")
    func splice() throws {
        let chapter = NSAttributedString(string: "標題\n第一段。\n第二段。")
        var decorations = ReaderTranslationLayout.Decorations()
        decorations.paragraphs[1] = .init(trailing: NSAttributedString(string: "①"), below: [NSAttributedString(string: "【熱評】\n")])
        decorations.chapterEnd = [NSAttributedString(string: "【本章說】\n")]
        let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: .off, decorations: decorations) { _ in nil })
        #expect(spliced.display.string == "標題\n第一段。①\n【熱評】\n第二段。\n【本章說】\n")
        let layout = spliced.layout
        #expect(layout.sourceText == chapter.string && layout.sourceLength == chapter.length)
        let source = chapter.string as NSString, display = spliced.display.string as NSString
        for offset in 0..<chapter.length {
            let shown = layout.displayOffset(charOffset: offset, translationOffset: nil)
            #expect(display.character(at: shown) == source.character(at: offset), "source \(offset)")
            let back = layout.sourcePosition(displayOffset: shown)
            #expect(back.charOffset == offset && back.translationOffset == nil)
        }
        let bubble = display.range(of: "①").location
        #expect(layout.isTranslation(NSRange(location: bubble, length: 1)), "added, not the book's: no highlight starts in it")
        let inBubble = layout.sourcePosition(displayOffset: bubble)
        #expect(layout.displayOffset(charOffset: inBubble.charOffset, translationOffset: inBubble.translationOffset) == bubble)
        #expect(layout.displayRanges(forSource: NSRange(location: 3, length: 4)) == [NSRange(location: 3, length: 4)])
        #expect(ReaderTranslationLayout.splice(chapter, mode: .off, decorations: .init()) { _ in nil } == nil, "nothing to add")

        // A place inside a translation is the same place once comments arrive.
        let translate: (String) -> String? = { $0 == "第一段。" ? "First paragraph." : nil }
        let before = try #require(ReaderTranslationLayout.splice(chapter, mode: .bilingual, translation: translate))
        let after = try #require(ReaderTranslationLayout.splice(chapter, mode: .bilingual, decorations: decorations, translation: translate))
        let word = (before.display.string as NSString).range(of: "paragraph").location
        let position = before.layout.sourcePosition(displayOffset: word)
        #expect(position.translationOffset != nil)
        let moved = after.layout.displayOffset(charOffset: position.charOffset, translationOffset: position.translationOffset)
        #expect((after.display.string as NSString).substring(with: NSRange(location: moved, length: 9)) == "paragraph")
        #expect(after.display.string == "標題\n第一段。①\nFirst paragraph.\n【熱評】\n第二段。\n【本章說】\n")
    }

    @Test("a chapter is asked about once, drawn when its answer is in, and left alone when its source drew its own")
    func decorator() async throws {
        let thread = ChapterCommentThread(
            module: try RuleModuleValidator.validate(module(["search": search, "comments": notesBlock()]), appVersion: "3.0.2"),
            record: RuleListItem(name: "長夜", author: "", bookUrl: "/b/7", coverUrl: "", intro: "", wordCount: "", lastChapter: "", kind: ""),
            chapter: ModuleCommentChapter(id: "a3", title: "第3章 風起"))
        var asked: [String] = []
        let decorator = ReaderChapterCommentDecorator { query in
            asked.append(query.chapterTitle)
            var notes = RuleModuleChapterNotes(fetchedAt: .now)
            notes.counts = [ModuleParagraphCount(paragraph: .init(quote: ChapterParagraphMatch.fold("他推開門"), index: nil, id: "p9"), count: 12),
                            ModuleParagraphCount(paragraph: .init(quote: ChapterParagraphMatch.fold("別本書的段落"), index: nil, id: "p1"), count: 3)]
            return .init(thread: thread, notes: notes)
        }
        decorator.reset(work: WorkReviewQuery(title: "長夜", authors: [], contentKind: .text), chapterTitles: { Self.localTitles })
        var arrived: [Int] = []
        let listening = decorator.updates.sink { arrived.append($0) }
        defer { listening.cancel() }

        let built = NSAttributedString(string: "第三章 風起\n　　風，起了。\n　　他推開門，走進長夜。\n", attributes: [.font: UIFont.systemFont(ofSize: 18)])
        let cut = ReaderTranslationText.paragraphs(in: built.string)
        let texts = cut.map(\.key)
        #expect(decorator.placements(forSpine: 3, title: "第三章 風起", paragraphs: texts) == nil, "not in yet")
        for _ in 0..<50 where arrived.isEmpty { await Task.yield() }
        #expect(arrived == [3] && asked == ["第三章 風起"], "asked once, and said when in")

        let placements = try #require(decorator.placements(forSpine: 3, title: "第三章 風起", paragraphs: texts))
        #expect(Array(placements.bubbles.keys) == [2] && placements.cards.isEmpty && placements.chapterEnd.isEmpty,
                "the paragraph the site quoted; the one it has no text of gets nothing")
        let placed = try #require(placements.bubbles[2])
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(placed.href))
        let target = ModuleCommentTargets.target(marker.moduleToken)
        #expect(placed.count == 12 && marker.count == "12")
        #expect(target?.paragraphID == "p9" && target?.thread == thread, "the bubble opens that paragraph's comments")
        #expect(target?.heading == "他推開門，走進長夜。")
        #expect(asked.count == 1)

        // As the chapter document draws it: a bubble on the paragraph's last line.
        let settings = ReaderRenderSettings(
            theme: "test", textColor: .black, backgroundColor: .white, fontSize: 18,
            lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8, letterSpacing: 0,
            marginH: 0, marginV: 0, footerHeight: 0, contentInsets: .zero, writingMode: .horizontal)
        let pieces = ReaderCommentPieces(settings: settings, textColor: .black, columnWidth: 320)
        let decorations = try #require(await pieces.decorations(placements, in: built, paragraphs: cut))
        let bubble = try #require(decorations.paragraphs[2]?.trailing)
        #expect(bubble.string.contains("\u{FFFC}") && !bubble.string.contains("\n"))
        var link: String?
        bubble.enumerateAttribute(HTMLAttributedStringBuilder.internalLinkAttribute, in: NSRange(location: 0, length: bubble.length)) { value, _, _ in
            link = (value as? String) ?? link
        }
        #expect(link == placed.href)

        let sourced = NSMutableAttributedString(attributedString: built)
        sourced.addAttribute(HTMLAttributedStringBuilder.internalLinkAttribute, value: "ydreview://r?d=abc", range: NSRange(location: 8, length: 1))
        #expect(ReaderCommentPieces.hasSourceComments(sourced) && !ReaderCommentPieces.hasSourceComments(built),
                "a chapter whose source drew its own comments is left alone")
    }
}
