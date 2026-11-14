import Foundation
import Testing
@testable import yuedu_app

/// 讀者評論 (format 3.0.1): a module's `reviews` block, the records of a work it is asked for,
/// and what 作品詳情 draws of them. Every reply here is made up: no site's readers are quoted.
@MainActor
@Suite("Module reviews", .serialized)
struct ModuleReviewsTests {
    private static let isbn = "9787536692930"
    private static let isbn10 = "7536692935"

    // MARK: - Fixture

    private func module(_ object: [String: Any], id: String = "r.test", requiredVersion: String = "3.0.1") -> Data {
        var base: [String: Any] = ["id": id, "title": "書評站", "version": "1.0", "requiredVersion": requiredVersion,
                                   "hosts": ["example.com"], "modules": [[String: Any]]()]
        base.merge(object) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: base)
    }

    private var search: [String: Any] {
        ["request": ["url": "https://example.com/s?q={{keyword}}"],
         "list": ["items": "$.books[*]", "title": "$.title", "author": "$.author", "url": "$.href", "id": "$.id"]]
    }

    private var lookup: [String: Any] {
        ["request": ["url": "https://example.com/isbn/{{isbn}}"],
         // The site writes an edition's ISBN-13 and -10 in one value.
         "list": ["items": "$.books[*]", "title": "$.title", "author": "$.author", "url": "$.href", "id": "$.id",
                  "isbn": "$.identifier"]]
    }

    private func reviews(_ extra: [String: Any] = [:]) -> [String: Any] {
        var block: [String: Any] = [
            "request": ["url": "https://example.com/comments/{{id}}?limit=100"],
            "list": ["items": "$.comments[?(@.parent_id == null)]", "text": "$.text", "author": "$.user.name", "date": "$.date"],
        ]
        block.merge(extra) { _, new in new }
        return block
    }

    private struct Fixture {
        let provider: ModuleProvider
        let reviews: ModuleReviewProvider
        let library: RuleModuleLibrary
        let folder: URL
        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    private func fixture(_ object: [String: Any]) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleReviews-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.1", officialFiles: { [] })
        let installed = try await library.install(module(object), from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        let provider = ModuleProvider(module: installed, client: client)
        return Fixture(provider: provider, reviews: ModuleReviewProvider(provider: provider, client: client),
                       library: library, folder: folder)
    }

    private func query(isbn: Bool = false, authors: [String] = ["劉慈欣"], record: SourceItemKey? = nil) -> WorkReviewQuery {
        WorkReviewQuery(title: "三體", authors: authors, isbns: isbn ? [Self.isbn] : [], contentKind: .text, record: record)
    }

    private static let twoComments = """
    {"comments":[
      {"id":1,"parent_id":null,"text":"第一段。\\r\\n第二段。","date":"2025-01-02 15:43:23","user":{"name":"讀者甲"}},
      {"id":2,"parent_id":1,"text":"這是回覆","date":"2025-01-03 08:00:00","user":{"name":"讀者乙"}},
      {"id":3,"parent_id":null,"text":"   ","date":"2025-01-04 08:00:00","user":{"name":"讀者丙"}},
      {"id":4,"parent_id":null,"text":"<b>好看</b>","date":"不是日期","user":{"name":""}}
    ]}
    """

    // MARK: - Validator

    private func rejection(_ data: Data, appVersion: String = "3.0.1") -> RuleModuleRejection? {
        do { _ = try RuleModuleValidator.validate(data, appVersion: appVersion); return nil } catch { return error }
    }

    @Test("a reviews block is read with a record's id, and needs a 3.0.1 app")
    func accepted() throws {
        let validated = try RuleModuleValidator.validate(module(["search": search, "reviews": reviews([
            "cacheDuration": 86_400, "ratingScale": 10,
            "rating": ["score": "$.average", "count": "$.total", "distribution": "$.stars[*]"],
        ])]), appVersion: "3.0.1")
        #expect(validated.reviews?.request.url == "https://example.com/comments/{{id}}?limit=100")
        #expect(validated.reviews?.ratingScale == 10)
        #expect(validated.search?.list.id == "$.id")
        #expect(rejection(module(["search": search, "reviews": reviews()], requiredVersion: "3.0"))
                == .needsRequiredVersion(field: "search.list.id", minimum: "3.0.1"), "the first 3.0.1 field it uses")
        #expect(rejection(module(["search": search, "reviews": reviews()]), appVersion: "3.0")
                == .requiresNewerApp(required: "3.0.1", running: "3.0"))
    }

    @Test("a reviews block is refused when no record can be asked, or it reaches past the module")
    func refused() {
        var keyless = search
        keyless["list"] = ["items": "$.books[*]", "title": "$.title", "url": "$.href"]
        #expect(rejection(module(["search": keyless, "reviews": reviews()])) == .missingField("search.list.id"),
                "{{id}} with no id rule would ask the same page for every book")
        #expect(rejection(module(["modules": [["id": "a", "title": "a", "request": ["url": "https://example.com/a"],
                                               "list": ["items": "li", "title": "h3@text"]]],
                                  "reviews": reviews()])) == .missingField("search"), "a home list's rows are never matched to a work")
        #expect(rejection(module(["search": search, "reviews": reviews(["request": ["url": "https://example.com/comments"]])]))
                == .missingField("reviews.request.url {{id}}"))
        #expect(rejection(module(["search": search, "reviews": reviews(["request": ["url": "https://other.example/c/{{id}}"]])]))
                == .hostNotAllowed(field: "reviews.request.url", host: "other.example"))
        #expect(rejection(module(["search": search, "reviews": reviews(["request": ["url": "https://example.com/c/{{id}}?k={{keyword}}"]])]))
                == .undeclaredTemplate(field: "reviews.request.url", name: "keyword"))
        #expect(rejection(module(["search": search, "reviews": reviews(["list": ["items": "$.c[*]", "text": "@js:result"]])]))
                == .javaScript(field: "reviews.list.text"))
        #expect(rejection(module(["search": search, "reviews": reviews(["list": ["items": "$.c[*]", "text": " "]])]))
                == .emptyRule(field: "reviews.list.text"))
        #expect(rejection(module(["search": search, "reviews": reviews(["ratingScale": 0])]))
                == .unknownValue(field: "reviews.ratingScale", value: "0.0"))
    }

    // MARK: - Reading a page

    @Test("a page's reviews are plain text; a reply, an empty one and a date in no known form are left out")
    func readsPage() async throws {
        let f = try await fixture(["search": search, "reviews": reviews()])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"三體","author":"劉慈欣","href":"/b/7/a","id":7}]}"#),
            "example.com/comments/7": .json(Self.twoComments),
        ])
        let found = try #require(try await f.reviews.reviews(for: query()))
        #expect(found.moduleID == "r.test" && found.moduleTitle == "書評站")
        #expect(found.reviews.map(\.text) == ["第一段。\n第二段。", "好看"], "a reply (parent_id) and a blank text are no review")
        #expect(found.reviews.map(\.author) == ["讀者甲", nil])
        let day = try #require(found.reviews[0].date)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: day).day == 2)
        #expect(found.reviews[1].date == nil)
        #expect(found.reviews.allSatisfy { $0.rating == nil && $0.title == nil && $0.likes == nil }, "nothing the site did not give")
        #expect(found.rating == nil)
        #expect(ModuleStub.urls == ["https://example.com/s?q=%E4%B8%89%E9%AB%94", "https://example.com/comments/7?limit=100"])
    }

    @Test("ratings are stars out of five whatever the site's scale; a distribution is five bars or none")
    func ratings() async {
        let block = RuleModule.Reviews(
            request: .init(url: "https://example.com/c/{{id}}"),
            list: .init(items: "$.reviews[*]", text: "$.text", title: "$.title", rating: "$.score", likes: "$.likes"),
            ratingScale: 10,
            rating: .init(score: "$.average", count: "$.total", distribution: "$.stars[*]"))
        let page = #"""
        {"average":6.6,"total":1059,"stars":[320,210,180,150,199],
         "reviews":[{"title":"子曰","text":"知之為知之","score":6,"likes":3},{"text":"未評分","score":0,"likes":0},
                    {"text":"超出滿分","score":11}]}
        """#
        let read = await RuleModuleClient.readReviews(page, baseURL: "https://example.com/", by: block)
        #expect(read.reviews.map(\.rating) == [3, nil, nil], "0 is unrated, a number over the scale is not a rating")
        #expect(read.reviews.map(\.likes) == [3, nil, nil])
        #expect(read.reviews[0].title == "子曰")
        #expect(abs((read.rating?.score ?? 0) - 3.3) < 0.000_001, "6.6 of 10 is 3.3 of 5")
        #expect(read.rating?.count == 1059 && read.rating?.distribution == [320, 210, 180, 150, 199])

        let four = page.replacingOccurrences(of: "[320,210,180,150,199]", with: "[320,210,180,150]")
        let other = await RuleModuleClient.readReviews(four, baseURL: "https://example.com/", by: block)
        #expect(other.rating != nil && other.rating?.distribution == nil, "four buckets are not five stars'")
    }

    @Test("dates as sites write them")
    func dates() {
        let utc = TimeZone(identifier: "UTC")!
        func day(_ text: String) -> DateComponents? {
            RuleModuleClient.date(from: text).map { Calendar(identifier: .gregorian).dateComponents(in: utc, from: $0) }
        }
        #expect(day("2025-01-02 15:43:23")?.day == 2)
        #expect(day("2025-01-02T15:43:23Z")?.hour == 15)
        #expect(day("2025-01-02")?.month == 1)
        #expect(day("1735832603")?.year == 2025)
        #expect(day("1735832603000")?.year == 2025)
        #expect(day("3 年前") == nil && day("") == nil && day("12") == nil)
    }

    // MARK: - Which records

    @Test("a work with an ISBN is asked by it: the record whose ISBN is the work's, alone")
    func byISBN() async throws {
        let f = try await fixture(["search": search, "lookup": lookup, "reviews": reviews()])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(
                #"{"books":[{"title":"三体（全集）【典藏版】","author":"刘慈欣","href":"/b/9/z","id":9,"identifier":"\#(Self.isbn),\#(Self.isbn10)"}]}"#),
            "example.com/comments/9": .json(#"{"comments":[{"parent_id":null,"text":"按 ISBN 找到的","user":{"name":"甲"}}]}"#),
        ])
        let found = try #require(try await f.reviews.reviews(for: query(isbn: true)))
        #expect(found.reviews.map(\.text) == ["按 ISBN 找到的"], "its title is not the work's: the ISBN is what makes it the work")
        #expect(ModuleStub.urls == ["https://example.com/isbn/\(Self.isbn)", "https://example.com/comments/9?limit=100"])
    }

    @Test("without an ISBN, the uploads that are the same work are read, three at most, each review once")
    func sameWork() async throws {
        let f = try await fixture(["search": search, "reviews": reviews()])
        defer { f.cleanUp() }
        func comments(_ texts: [String]) -> ModuleStub.Reply {
            .json(#"{"comments":["# + texts.map { #"{"parent_id":null,"text":"\#($0)","user":{"name":"甲"}}"# }.joined(separator: ",") + "]}")
        }
        ModuleStub.install([
            "example.com/s": .json(#"""
            {"books":[{"title":"三体","author":"刘慈欣","href":"/b/1/a","id":1},
                      {"title":"三體 II","author":"劉慈欣","href":"/b/2/a","id":2},
                      {"title":"三體","author":"別人","href":"/b/3/a","id":3},
                      {"title":"三體","author":"劉慈欣 著","href":"/b/4/a","id":4},
                      {"title":"三體","author":"劉慈欣","href":"/b/5/a","id":5},
                      {"title":"三體","author":"劉慈欣","href":"/b/6/a","id":6}]}
            """#),
            "example.com/comments/1": comments(["一", "共同的"]),
            "example.com/comments/4": comments(["共同的", "四"]),
            "example.com/comments/5": comments(["五"]),
            "example.com/comments/6": comments(["不該被問到"]),
        ])
        let found = try #require(try await f.reviews.reviews(for: query()))
        #expect(found.reviews.map(\.text) == ["一", "共同的", "四", "五"])
        #expect(ModuleStub.urls.dropFirst() == ["https://example.com/comments/1?limit=100", "https://example.com/comments/4?limit=100",
                                                "https://example.com/comments/5?limit=100"],
                "another title, another author and the fourth upload are not asked")

        ModuleStub.install(["example.com/s": .json(#"{"books":[{"title":"三體","author":"劉慈欣","href":"/b/1/a","id":1}]}"#)])
        #expect(try await f.reviews.reviews(for: query(authors: ["未知作者"]))?.isEmpty == true)
        #expect(ModuleStub.urls.isEmpty, "a title alone is not a work: nothing leaves the device")
    }

    @Test("the module's own record is the work: asked as it is, whatever else shares its title")
    func ownRecord() async throws {
        let f = try await fixture(["search": search, "reviews": reviews()])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"""
            {"books":[{"title":"三體","author":"劉慈欣","href":"/b/1/a","id":1},
                      {"title":"三體","author":"劉慈欣","href":"/b/2/a","id":2}]}
            """#),
            "example.com/comments/2": .json(#"{"comments":[{"parent_id":null,"text":"第二筆的","user":{"name":"甲"}}]}"#),
        ])
        let own = SourceItemKey(instance: f.provider.instance, item: "https://example.com/b/2/a")
        let found = try #require(try await f.reviews.reviews(for: query(record: own)))
        #expect(found.reviews.map(\.text) == ["第二筆的"])
        #expect(ModuleStub.urls == ["https://example.com/s?q=%E4%B8%89%E9%AB%94", "https://example.com/comments/2?limit=100"])
    }

    @Test("a work's reviews answer again from the cache, an empty answer too; a failed request throws")
    func cacheAndFailure() async throws {
        let f = try await fixture(["search": search, "reviews": reviews(["cacheDuration": 3_600])])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"三體","author":"劉慈欣","href":"/b/1/a","id":1}]}"#),
            "example.com/comments/1": .json(#"{"comments":[]}"#),
        ])
        #expect(try await f.reviews.reviews(for: query())?.isEmpty == true)
        ModuleStub.install([:])
        #expect(try await f.reviews.reviews(for: query())?.isEmpty == true)
        #expect(ModuleStub.urls.isEmpty, "nobody reviewed it: not asked again within the hour")

        ModuleStub.install([
            "example.com/s": .json(#"{"books":[{"title":"三體","author":"劉慈欣","href":"/b/1/a","id":1}]}"#),
            "example.com/comments/1": .status(502),
        ])
        let other = WorkReviewQuery(title: "三體", authors: ["劉慈欣", "譯者"], contentKind: .text)
        await #expect(throws: (any Error).self) { try await f.reviews.reviews(for: other) }
    }

    @Test("a record that fails does not take the others' reviews with it, and the partial set is not kept")
    func partialFailure() async throws {
        let f = try await fixture(["search": search, "reviews": reviews(["cacheDuration": 3_600])])
        defer { f.cleanUp() }
        let books = #"""
        {"books":[{"title":"三體","author":"劉慈欣","href":"/b/1/a","id":1},
                  {"title":"三體","author":"劉慈欣","href":"/b/2/a","id":2}]}
        """#
        ModuleStub.install([
            "example.com/s": .json(books),
            "example.com/comments/1": .status(502),
            "example.com/comments/2": .json(#"{"comments":[{"parent_id":null,"text":"第二筆答了","user":{"name":"甲"}}]}"#),
        ])
        #expect(try await f.reviews.reviews(for: query())?.reviews.map(\.text) == ["第二筆答了"])
        ModuleStub.install([
            "example.com/s": .json(books),
            "example.com/comments/1": .json(#"{"comments":[{"parent_id":null,"text":"第一筆也答了","user":{"name":"乙"}}]}"#),
            "example.com/comments/2": .json(#"{"comments":[{"parent_id":null,"text":"第二筆答了","user":{"name":"甲"}}]}"#),
        ])
        #expect(try await f.reviews.reviews(for: query())?.reviews.map(\.text) == ["第一筆也答了", "第二筆答了"],
                "asked again: a set with a record missing was not kept as the work's")
        ModuleStub.install([:])
        #expect(try await f.reviews.reviews(for: query())?.reviews.count == 2)
        #expect(ModuleStub.urls.isEmpty, "the whole set is kept")
    }

    // MARK: - Which modules

    @Test("資料來源 decides which modules are asked, and in what order; a failed one gives way to the next")
    func order() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleReviews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "ModuleReviews-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Its own preferences: 停用 below must not stay in the test host's own defaults.
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder), appVersion: "3.0.1", officialFiles: { [] },
                                        preferences: defaults)
        for id in ["a", "b", "c"] { try await library.install(module(["search": search, "reviews": reviews()], id: id), from: nil) }
        try await library.install(module(["search": search], id: "plain"), from: nil)
        let order = MetadataFillOrderStore(defaults: defaults)
        order.save(MetadataFillOrder(entries: [
            .init(place: .module("c"), isEnabled: true), .init(place: .module("plain"), isEnabled: true),
            .init(place: .module("a"), isEnabled: false), .init(place: .module("b"), isEnabled: true),
            .init(place: .bookSources, isEnabled: true),
        ]))
        #expect(WorkReviews.modules(in: library, order: order).map(\.id) == ["c", "b"],
                "unchecked a is not asked; a module without reviews has none")

        var asked: [String] = []
        let found = await WorkReviews.load(query(), library: library, order: order) { module, _ in
            asked.append(module.id)
            if module.id == "c" { throw SourceFailure(kind: .rejected, status: 502, underlying: FetchError.httpError(502)) }
            return WorkReviewSet(moduleID: module.id, moduleTitle: module.title, reviews: [WorkReview(text: "有")], rating: nil)
        }
        #expect(asked == ["c", "b"] && found?.moduleID == "b")

        library.setEnabled(false, id: "b")
        let none = await WorkReviews.load(query(), library: library, order: order) { module, _ in
            WorkReviewSet(moduleID: module.id, moduleTitle: module.title, reviews: [], rating: nil)
        }
        #expect(none == nil, "停用 takes b out; c has no review of the work: no section")
    }

    // MARK: - What the page draws

    @Test("stars round to the nearest half; the orders the page offers are the ones its reviews can take")
    func drawing() {
        func stars(_ rating: Double) -> [String] { (1...5).map { WorkRatingStars.symbol(for: $0, rating: rating) } }
        #expect(stars(3) == ["star.fill", "star.fill", "star.fill", "star", "star"])
        #expect(stars(3.3) == ["star.fill", "star.fill", "star.fill", "star.leadinghalf.filled", "star"])
        #expect(stars(4.8) == Array(repeating: "star.fill", count: 5))

        let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = [WorkReview(text: "a"), WorkReview(text: "b")]
        #expect(WorkReviewOrder.available(for: plain) == [.site], "nothing to sort by: no 排序")
        let dated = [WorkReview(text: "舊", date: old, likes: 1), WorkReview(text: "無"), WorkReview(text: "新", date: new, likes: 5)]
        #expect(WorkReviewOrder.available(for: dated) == [.site, .newest, .mostHelpful])
        #expect(WorkReviewOrder.newest.sorted(dated).map(\.text) == ["新", "舊", "無"])
        #expect(WorkReviewOrder.mostHelpful.sorted(dated).map(\.text) == ["新", "舊", "無"])
        #expect(WorkReviewOrder.site.sorted(dated).map(\.text) == ["舊", "無", "新"])
    }
}
