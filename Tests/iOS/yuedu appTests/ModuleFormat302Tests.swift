import Foundation
import Testing
@testable import yuedu_app

/// Format 3.0.2, the parts of Forward's widget format that need no JavaScript: a module's `icon`,
/// its `globalParams` set once on its page, a parameter's `belongTo` and an `input`'s
/// `placeholders`. Every site here is made up.
@MainActor
@Suite("Module format 3.0.2", .serialized)
struct ModuleFormat302Tests {
    // MARK: - Fixture

    private func module(_ edit: (inout [String: Any]) -> Void = { _ in }, requiredVersion: String = "3.0.2") -> Data {
        var object: [String: Any] = [
            "id": "f302.test", "title": "新書站", "version": "1.0", "requiredVersion": requiredVersion,
            "hosts": ["example.com"],
            "modules": [[
                "id": "new", "title": "新書",
                "params": [
                    ["name": "sort", "type": "enumeration",
                     "enumOptions": [["title": "最新", "value": "new"], ["title": "類型", "value": "genre"]]],
                    ["name": "genre", "type": "input", "value": "all",
                     "belongTo": ["paramName": "sort", "value": ["genre"]],
                     "placeholders": [["title": "科幻", "value": "sf"], ["title": "推理", "value": "mystery"]]],
                    ["name": "page", "type": "page"],
                ],
                "request": ["url": "https://example.com/list?sort={{sort}}&genre={{genre}}&lang={{lang}}&p={{page}}"],
                "list": ["items": "$.books[*]", "title": "$.title", "url": "$.href"],
            ] as [String: Any]],
        ]
        edit(&object)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static let globals: [[String: Any]] = [
        ["name": "lang", "title": "語言", "type": "enumeration", "value": "zh",
         "enumOptions": [["title": "中文", "value": "zh"], ["title": "日本語", "value": "ja"]]],
    ]

    private func withGlobals(_ object: inout [String: Any]) {
        object["globalParams"] = Self.globals
        object["icon"] = "https://example.com/icon.png"
    }

    private func rejection(_ data: Data, appVersion: String = "3.0.2") -> RuleModuleRejection? {
        do {
            _ = try RuleModuleValidator.validate(data, appVersion: appVersion)
            return nil
        } catch {
            return error
        }
    }

    private func entryParams(_ object: inout [String: Any], _ edit: (inout [[String: Any]]) -> Void) {
        var modules = object["modules"] as! [[String: Any]]
        var params = modules[0]["params"] as! [[String: Any]]
        edit(&params)
        modules[0]["params"] = params
        object["modules"] = modules
    }

    // MARK: - Validator

    @Test("a 3.0.2 module with an icon, global parameters, belongTo and placeholders is accepted")
    func accepted() throws {
        let module = try RuleModuleValidator.validate(module(withGlobals), appVersion: "3.0.2")
        #expect(module.icon == "https://example.com/icon.png")
        #expect(module.globalParams?.first?.name == "lang")
        let genre = module.modules[0].params[1]
        #expect(genre.belongTo == RuleModule.BelongTo(paramName: "sort", value: ["genre"]))
        #expect(genre.placeholders?.map(\.value) == ["sf", "mystery"])
    }

    @Test("each 3.0.2 field needs requiredVersion 3.0.2")
    func needsVersion() {
        #expect(rejection(module(withGlobals, requiredVersion: "3.0.1"))
                == .needsRequiredVersion(field: "icon", minimum: "3.0.2"))
        // Without globals the list's `{{lang}}` would be undeclared: drop it to reach belongTo.
        let belongsOnly = module({ object in
            var modules = object["modules"] as! [[String: Any]]
            modules[0]["request"] = ["url": "https://example.com/list?sort={{sort}}&genre={{genre}}&p={{page}}"]
            object["modules"] = modules
            entryParams(&object) { $0[1]["placeholders"] = nil }
        }, requiredVersion: "3.0.1")
        #expect(rejection(belongsOnly, appVersion: "3.0.1")
                == .needsRequiredVersion(field: "modules[0].params[1].belongTo", minimum: "3.0.2"))
    }

    @Test("a list's store is sections of books with values its parameters take, on a home list only, under 3.0.2")
    func store() {
        // The fixture's list without its other 3.0.2 fields (a global, belongTo, placeholders), so
        // its store is what needs 3.0.2.
        func withStore(_ store: [[String: Any]]) -> (inout [String: Any]) -> Void {
            { object in
                var modules = object["modules"] as! [[String: Any]]
                modules[0]["request"] = ["url": "https://example.com/list?sort={{sort}}&genre={{genre}}&p={{page}}"]
                modules[0]["store"] = store
                object["modules"] = modules
                entryParams(&object) {
                    $0[1]["belongTo"] = nil
                    $0[1]["placeholders"] = nil
                }
            }
        }
        let good: [[String: Any]] = [["layout": "heroCards", "params": ["sort": "new"]], ["layout": "multiRow"]]
        #expect(rejection(module(withStore(good))) == nil)
        let module302 = try? RuleModuleValidator.validate(module(withStore(good)), appVersion: "3.0.2")
        #expect(module302?.modules[0].store?.map(\.layout) == ["heroCards", "multiRow"])
        #expect(rejection(module(withStore(good), requiredVersion: "3.0.1"))
            == .needsRequiredVersion(field: "modules[0].store", minimum: "3.0.2"))
        // A layout of lists, a reading card, an unknown layout; a parameter or option the list lacks.
        for bad in [[["layout": "collageCards"]], [["layout": "compactReadingCard"]], [["layout": "spiral"]],
                    [["layout": "row", "params": ["order": "new"]]], [["layout": "row", "params": ["sort": "old"]]],
                    [] as [[String: Any]]] {
            #expect(rejection(module(withStore(bad))) != nil, "\(bad)")
        }
        // Only a home list has a store.
        let onSearch = module { object in
            object["search"] = ["request": ["url": "https://example.com/s?q={{keyword}}"],
                                "list": ["items": "$.books[*]", "title": "$.title"], "store": good]
        }
        #expect(rejection(onSearch) != nil)
    }

    @Test("a store's shelves are the list with values its parameters take, or another list of the module's, each for some of its values")
    func storeShelves() throws {
        func withShelves(_ shelves: [[String: Any]], layout: String = "groupedShelves") -> (inout [String: Any]) -> Void {
            { object in
                var modules = object["modules"] as! [[String: Any]]
                modules[0]["request"] = ["url": "https://example.com/list?sort={{sort}}&genre={{genre}}&p={{page}}"]
                modules[0]["store"] = [["layout": "heroCards"], ["layout": layout, "shelves": shelves]]
                modules.append(["id": "old", "title": "舊書", "params": [["name": "page", "type": "page"]],
                                "request": ["url": "https://example.com/old?p={{page}}"],
                                "list": ["items": "$.books[*]", "title": "$.title"]])
                object["modules"] = modules
                entryParams(&object) {
                    $0[1]["belongTo"] = nil
                    $0[1]["placeholders"] = nil
                }
            }
        }
        let good: [[String: Any]] = [
            ["params": ["sort": "genre"], "belongTo": ["paramName": "sort", "value": ["genre"]]],
            ["params": ["sort": "new"]],
            ["list": "old"],
        ]
        #expect(rejection(module(withShelves(good))) == nil)
        let module = try RuleModuleValidator.validate(module(withShelves(good)), appVersion: "3.0.2")
        #expect(module.modules[0].store?.last?.shelves?.map(\.list) == [nil, nil, "old"])
        // Not drawn as shelves; none; an option the list lacks; another list that is not there or
        // lacks the value; belongTo by a parameter that is no choice, or a value it lacks.
        let bad: [(shelves: [[String: Any]], layout: String)] = [
            (good, "row"), ([], "groupedShelves"), ([["params": ["sort": "old"]]], "groupedShelves"),
            ([["list": "gone"]], "groupedShelves"), ([["list": "old", "params": ["sort": "new"]]], "groupedShelves"),
            ([["belongTo": ["paramName": "genre", "value": ["sf"]]]], "groupedShelves"),
            ([["belongTo": ["paramName": "sort", "value": ["old"]]]], "groupedShelves"),
        ]
        for (shelves, layout) in bad {
            #expect(rejection(self.module(withShelves(shelves, layout: layout))) != nil, "\(shelves) \(layout)")
        }

        // The page: 更多「新書」, a shelf each the store's values take, named by its option or its list.
        let page = ModuleStores.page(of: module.modules[0], in: module, language: "zh-Hant")
        let shelves = try #require(page.sections.last)
        #expect(shelves.layout == .groupedShelves)
        #expect(shelves.title == String(format: localized("書店：更多%@"), "新書"))
        guard case .lists(let cards) = shelves.binding else { Issue.record("shelves are lists"); return }
        // `sort` is `new` (its first option), so the shelf shown only for `genre` is left out.
        #expect(cards.map(\.title) == ["最新", "舊書"])
        #expect(cards.map(\.binding) == [.module(moduleID: "f302.test", entryID: "new"), .module(moduleID: "f302.test", entryID: "old")])
        #expect(cards.map(\.parameters) == [["sort": "new"], [:]])
    }

    @Test("a request may only use a global the module declares")
    func undeclaredGlobal() {
        #expect(rejection(module()) == .undeclaredTemplate(field: "modules[0].request.url", name: "lang"))
    }

    @Test("an icon is on the module's hosts, an http(s) address with nothing to fill")
    func iconHost() {
        #expect(rejection(module { withGlobals(&$0); $0["icon"] = "https://cdn.other.net/i.png" })
                == .hostNotAllowed(field: "icon", host: "cdn.other.net"))
        #expect(rejection(module { withGlobals(&$0); $0["icon"] = "ftp://example.com/i.png" }) == .invalidURL(field: "icon"))
        #expect(rejection(module { withGlobals(&$0); $0["icon"] = "https://example.com/{{lang}}.png" })
                == .undeclaredTemplate(field: "icon", name: "lang"))
    }

    @Test("a global is named apart from the lists' parameters and the names requests fill")
    func globalNames() {
        func renamed(_ name: String) -> Data {
            module { object in
                withGlobals(&object)
                var globals = Self.globals
                globals[0]["name"] = name
                object["globalParams"] = globals
            }
        }
        #expect(rejection(renamed("sort")) == .unknownValue(field: "globalParams[0].name", value: "sort"))
        #expect(rejection(renamed("keyword")) == .unknownValue(field: "globalParams[0].name", value: "keyword"))
        #expect(rejection(module { object in
            withGlobals(&object)
            object["globalParams"] = Self.globals + Self.globals
        }) == .unknownValue(field: "globalParams[1].name", value: "lang"))
    }

    @Test("a global is a setting: no paging, and no language to follow")
    func globalKinds() {
        #expect(rejection(module { object in
            withGlobals(&object)
            object["globalParams"] = Self.globals + [["name": "p2", "type": "page"]]
        }) == .unknownParamType(field: "globalParams[1].type", type: "page"))
        #expect(rejection(module { object in
            withGlobals(&object)
            var globals = Self.globals
            globals[0]["followsLanguage"] = true
            object["globalParams"] = globals
        }) == .unknownValue(field: "globalParams[0].followsLanguage", value: "true"))
    }

    @Test("belongTo names another parameter of the same list, and never leads back to itself")
    func belongToTargets() {
        #expect(rejection(module { withGlobals(&$0); entryParams(&$0) { $0[1]["belongTo"] = ["paramName": "genre", "value": ["x"]] } })
                == .unknownValue(field: "modules[0].params[1].belongTo", value: "genre"))
        #expect(rejection(module { withGlobals(&$0); entryParams(&$0) { $0[1]["belongTo"] = ["paramName": "lang", "value": ["ja"]] } })
                == .unknownValue(field: "modules[0].params[1].belongTo", value: "lang"))
        #expect(rejection(module { withGlobals(&$0); entryParams(&$0) { $0[0]["belongTo"] = ["paramName": "genre", "value": ["sf"]] } })
                == .unknownValue(field: "modules[0].params[0].belongTo", value: "genre"))
    }

    @Test("placeholders are an input's")
    func placeholdersOnInput() {
        #expect(rejection(module { withGlobals(&$0); entryParams(&$0) { $0[0]["placeholders"] = [["title": "x", "value": "x"]] } })
                == .unknownValue(field: "modules[0].params[0].placeholders", value: "enumeration"))
    }

    // MARK: - Values

    @Test("a hidden parameter sends its default; shown, the reader's own")
    func belongToValues() throws {
        let entry = try RuleModuleValidator.validate(module(withGlobals)).modules[0]
        let hidden = entry.values(["sort": "new", "genre": "sf"], position: 1, language: nil)
        #expect(hidden["genre"] == "all")
        #expect(entry.shownParams(in: ["sort": "new"], language: nil).map(\.name) == ["sort"])
        let shown = entry.values(["sort": "genre", "genre": "sf"], position: 1, language: nil)
        #expect(shown["genre"] == "sf")
        #expect(entry.shownParams(in: ["sort": "genre"], language: nil).map(\.name) == ["sort", "genre"])
    }

    @Test("a chain of belongTo settles: hidden behind a hidden parameter is hidden")
    func belongToChain() {
        let params = [
            RuleModule.Param(name: "a", type: "enumeration", enumOptions: [.init(title: "1", value: "1"), .init(title: "2", value: "2")]),
            RuleModule.Param(name: "b", type: "enumeration", enumOptions: [.init(title: "x", value: "x"), .init(title: "y", value: "y")],
                             belongTo: .init(paramName: "a", value: ["2"])),
            RuleModule.Param(name: "c", type: "input", value: "default", belongTo: .init(paramName: "b", value: ["y"])),
        ]
        // b is hidden (a is 1), so it sends x, and c behind it is hidden too.
        let values = RuleModule.Param.currentValues(of: params, in: ["a": "1", "b": "y", "c": "own"], language: nil)
        #expect(values == ["a": "1", "b": "x", "c": "default"])
        let open = RuleModule.Param.currentValues(of: params, in: ["a": "2", "b": "y", "c": "own"], language: nil)
        #expect(open == ["a": "2", "b": "y", "c": "own"])
    }

    /// The fixture with a `region` before `sort`, and `sort`'s 熱門 offered only in `en`.
    private func regionalOption(_ object: inout [String: Any], requires: Bool = true) {
        withGlobals(&object)
        entryParams(&object) { params in
            params.insert(["name": "region", "type": "enumeration", "value": "zh",
                           "enumOptions": [["title": "華語", "value": "zh"], ["title": "英語", "value": "en"]]], at: 0)
            var options = params[1]["enumOptions"] as! [[String: Any]]
            options.append(["title": "熱門", "value": "hot", "belongTo": ["paramName": "region", "value": ["en"]]])
            params[1]["enumOptions"] = options
        }
        var modules = object["modules"] as! [[String: Any]]
        modules[0]["request"] = ["url": "https://example.com/list?r={{region}}&sort={{sort}}&genre={{genre}}&lang={{lang}}&p={{page}}"]
        object["modules"] = modules
    }

    @Test("an option's belongTo names another parameter, never the default option nor a cycle, under 3.0.2")
    func optionBelongToValidation() throws {
        let entry = try RuleModuleValidator.validate(module { regionalOption(&$0) }).modules[0]
        #expect(entry.params[1].enumOptions?.last?.belongTo == RuleModule.BelongTo(paramName: "region", value: ["en"]))
        // On the option the parameter defaults to (`sort` has no value: its first, 最新).
        #expect(rejection(module { regionalOption(&$0); entryParams(&$0) { params in
            var options = params[1]["enumOptions"] as! [[String: Any]]
            options[0]["belongTo"] = ["paramName": "region", "value": ["en"]]
            params[1]["enumOptions"] = options
        } }) == .unknownValue(field: "modules[0].params[1].enumOptions[0].belongTo", value: "new"))
        // Naming a parameter the list does not have.
        #expect(rejection(module { regionalOption(&$0); entryParams(&$0) { params in
            var options = params[1]["enumOptions"] as! [[String: Any]]
            options[2]["belongTo"] = ["paramName": "nowhere", "value": ["en"]]
            params[1]["enumOptions"] = options
        } }) == .unknownValue(field: "modules[0].params[1].enumOptions[2].belongTo", value: "nowhere"))
        // `genre` is shown by `sort`; one of `sort`'s options shown by `genre` leads back.
        #expect(rejection(module { regionalOption(&$0); entryParams(&$0) { params in
            var options = params[1]["enumOptions"] as! [[String: Any]]
            options[2]["belongTo"] = ["paramName": "genre", "value": ["sf"]]
            params[1]["enumOptions"] = options
        } }) == .unknownValue(field: "modules[0].params[1].enumOptions[2].belongTo", value: "genre"))
        // On a parameter that follows 中繼資料語言偏好推薦, whose default is the reader's language.
        #expect(rejection(module { regionalOption(&$0); entryParams(&$0) { params in
            params[1]["followsLanguage"] = true
        } }) == .unknownValue(field: "modules[0].params[1].enumOptions[2].belongTo", value: "hot"))
    }

    @Test("an option its belongTo does not offer now is not listed, and sends the default")
    func optionBelongToValues() throws {
        let entry = try RuleModuleValidator.validate(module { regionalOption(&$0) }).modules[0]
        let sort = entry.params[1]
        let zh = RuleModule.Param.currentValues(of: entry.params, in: ["region": "zh", "sort": "hot"], language: nil)
        #expect(zh["sort"] == "new")
        #expect(sort.offeredOptions(among: zh).map(\.value) == ["new", "genre"])
        let en = RuleModule.Param.currentValues(of: entry.params, in: ["region": "en", "sort": "hot"], language: nil)
        #expect(en["sort"] == "hot")
        #expect(sort.offeredOptions(among: en).map(\.value) == ["new", "genre", "hot"])
        #expect(entry.values(["region": "zh", "sort": "hot"], position: 1, language: nil)["sort"] == "new")
    }

    @Test("the reader's global values are written into the module; one no option has is not")
    func applyingGlobals() throws {
        let module = try RuleModuleValidator.validate(module(withGlobals))
        #expect(module.globalValues(language: nil) == ["lang": "zh"])
        #expect(module.applyingGlobalValues(["lang": "ja"]).globalValues(language: nil) == ["lang": "ja"])
        #expect(module.applyingGlobalValues(["lang": "ko"]).globalValues(language: nil) == ["lang": "zh"])
        #expect(module.withGlobalValues(["sort": "new"], language: nil) == ["sort": "new", "lang": "zh"])
    }

    // MARK: - Library and requests

    @Test("a global value set on the module's page is kept, published and sent in each request")
    func globalsReachRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Format302-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "Format302-\(UUID().uuidString)")!
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.2", officialFiles: { [] }, availability: nil,
                                        preferences: defaults)
        try await library.install(module(withGlobals), from: nil)
        library.setGlobalValue("ja", name: "lang", id: "f302.test")
        let installed = try #require(library.module(id: "f302.test")).module
        #expect(installed.globalValues(language: nil) == ["lang": "ja"])
        #expect(library.imported.first?.module.globalValues(language: nil) == ["lang": "ja"])

        // Kept: a library read again (the next launch) publishes it the same.
        let again = RuleModuleLibrary(store: store, appVersion: "3.0.2", officialFiles: { [] }, availability: nil,
                                      preferences: defaults)
        await again.load()
        #expect(again.module(id: "f302.test")?.module.globalValues(language: nil) == ["lang": "ja"])

        ModuleStub.install(["example.com/list?sort=new&genre=all&lang=ja&p=1":
                                .json(#"{"books":[{"title":"甲","href":"https://example.com/b/1"}]}"#)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        let provider = ModuleProvider(module: installed, client: client, language: { "zh-Hant" })
        let page = try await provider.page(ofList: "new", parameters: ["sort": "new", "genre": "sf"], after: nil)
        #expect(ModuleStub.urls == ["https://example.com/list?sort=new&genre=all&lang=ja&p=1"])
        #expect(page.items(limit: 10).count == 1)

        // A changed global changes the row's inputs, so the Explore home loads it again.
        let section = HomeSection(layout: .row, binding: .module(moduleID: "f302.test", entryID: "new"))
        let before = provider.inputsKey(for: section)
        library.setGlobalValue(nil, name: "lang", id: "f302.test")
        let reset = ModuleProvider(module: try #require(library.module(id: "f302.test")).module, client: client)
        #expect(reset.inputsKey(for: section) != before)
        #expect(reset.module.globalValues(language: nil) == ["lang": "zh"])
    }
}

/// Format 3.0.2 on 作品詳情: a module book's own page (`detail`), its genre's books (`genre`,
/// else `search`) and the works its site relates to it (`related`). Every site is made up.
@MainActor
@Suite("Module format 3.0.2 detail", .serialized)
struct ModuleFormat302DetailTests {
    private func module(_ edit: (inout [String: Any]) -> Void) -> Data {
        var object: [String: Any] = [
            "id": "f302.detail", "title": "書站", "version": "1.0", "requiredVersion": "3.0.2",
            "hosts": ["example.com"],
            "modules": [[String: Any]](),
            "search": ["request": ["url": "https://example.com/s?q={{keyword}}"],
                       "list": ["items": "$.books[*]", "title": "$.title", "author": "$.author", "url": "$.href", "id": "$.id",
                                "tags": "$.tags[*]"]] as [String: Any],
        ]
        edit(&object)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static let detail: [String: Any] = [
        "request": ["url": "{{url}}.json"], "intro": "$.summary", "tags": "$.genres[*]", "cacheDuration": 3600,
    ]
    private static let related: [String: Any] = [
        "request": ["url": "https://example.com/related/{{id}}"],
        "list": ["items": "$.works[*]", "title": "$.title", "author": "$.author", "url": "$.href"],
    ]
    private static let genre: [String: Any] = [
        "params": [["name": "page", "type": "page"]],
        "request": ["url": "https://example.com/genre?tag={{tag}}&p={{page}}"],
        "list": ["items": "$.books[*]", "title": "$.title", "url": "$.href"],
    ]

    private func rejection(_ data: Data) -> RuleModuleRejection? {
        do {
            _ = try RuleModuleValidator.validate(data, appVersion: "3.0.2")
            return nil
        } catch {
            return error
        }
    }

    private func provider(_ data: Data) throws -> (ModuleProvider, RuleModuleClient, URL) {
        let module = try RuleModuleValidator.validate(data, appVersion: "3.0.2")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Format302D-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder), now: { Date() })
        return (ModuleProvider(module: module, client: client), client, folder)
    }

    // MARK: Validator

    @Test("detail, related and genre are accepted at 3.0.2 and need it")
    func accepted() {
        let all = module { $0["detail"] = Self.detail; $0["related"] = Self.related; $0["genre"] = Self.genre }
        #expect(rejection(all) == nil)
        let old = module { $0["requiredVersion"] = "3.0.1"; $0["genre"] = Self.genre }
        #expect(rejection(old) == .needsRequiredVersion(field: "genre", minimum: "3.0.2"))
    }

    @Test("each names what it is asked for: detail its {{url}}, genre its {{tag}}, related its record")
    func keys() {
        #expect(rejection(module { $0["detail"] = ["request": ["url": "https://example.com/d"], "intro": "$.s"] })
                == .missingField("detail.request.url {{url}}"))
        var genre = Self.genre
        genre["request"] = ["url": "https://example.com/genre?p={{page}}"]
        #expect(rejection(module { $0["genre"] = genre }) == .missingField("genre.request.url {{tag}}"))
        var related = Self.related
        related["request"] = ["url": "https://example.com/related"]
        #expect(rejection(module { $0["related"] = related }) == .missingField("related.request.url {{id}}"))
        // `{{id}}` needs a list that reads one.
        #expect(rejection(module { object in
            var search = object["search"] as! [String: Any]
            var list = search["list"] as! [String: Any]
            list["id"] = nil
            search["list"] = list
            object["search"] = search
            object["related"] = Self.related
        }) == .missingField("search.list.id"))
        // Related works' rules are rules: no JavaScript.
        var scripted = Self.related
        scripted["list"] = ["items": "$.works[*]", "title": "@js:result"]
        #expect(rejection(module { $0["related"] = scripted }) == .javaScript(field: "related.list.title"))
    }

    // MARK: Requests

    @Test("a genre opens the genre list with {{tag}}, a page at a time")
    func genrePage() async throws {
        let (provider, _, folder) = try provider(module { $0["genre"] = Self.genre })
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install([
            "example.com/genre?tag=%E7%A7%91%E5%B9%BB&p=1": .json(#"{"books":[{"title":"甲","href":"https://example.com/b/1"}]}"#),
        ])
        let page = try #require(try await provider.tagPage("科幻", after: nil))
        #expect(ModuleStub.urls == ["https://example.com/genre?tag=%E7%A7%91%E5%B9%BB&p=1"])
        #expect(page.items(limit: 10).count == 1)
        #expect(page.next?.value == "2")
    }

    @Test("a genre's page is the module list page's model, page by page; a module that opens none is missing")
    func genreListModel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Format302G-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.2", officialFiles: { [] })
        try await library.install(module { $0["genre"] = Self.genre }, from: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        ModuleStub.install([
            "example.com/genre?tag=%E7%A7%91%E5%B9%BB&p=1": .json(#"{"books":[{"title":"甲","href":"https://example.com/b/1"}]}"#),
            "example.com/genre?tag=%E7%A7%91%E5%B9%BB&p=2": .json(#"{"books":[{"title":"乙","href":"https://example.com/b/2"}]}"#),
        ])
        let model = ModuleListModel(route: .tag("科幻", moduleID: "f302.detail"), library: library, client: client)
        await model.load()
        #expect(model.state == .loaded)
        await model.loadMore()
        #expect(model.entries.count == 2)

        let none = ModuleListModel(route: .tag("科幻", moduleID: "missing"), library: library, client: client)
        await none.load()
        #expect(none.state == .missing)
    }

    @Test("without a genre list, a genre opens what search finds for the word")
    func tagFallsBackToSearch() async throws {
        let (provider, _, folder) = try provider(module { _ in })
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install(["example.com/s?q=%E6%8E%A8%E7%90%86": .json(#"{"books":[{"title":"乙","href":"https://example.com/b/2"}]}"#)])
        let page = try #require(try await provider.tagPage("推理", after: nil))
        #expect(ModuleStub.urls == ["https://example.com/s?q=%E6%8E%A8%E7%90%86"])
        #expect(page.items(limit: 10).count == 1)
        #expect(provider.opensTags)
    }

    @Test("a book's page gives its description and tags, once within its cacheDuration")
    func bookDetail() async throws {
        let (provider, _, folder) = try provider(module { $0["detail"] = Self.detail })
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install(["example.com/b/1.json": .json(#"{"summary":"一段簡介","genres":["科幻","太空"]}"#)])
        let detail = try #require(try await provider.bookDetail(url: "https://example.com/b/1"))
        #expect(detail.intro == "一段簡介")
        #expect(detail.tags == ["科幻", "太空"])
        _ = try await provider.bookDetail(url: "https://example.com/b/1")
        #expect(ModuleStub.urls == ["https://example.com/b/1.json"])
    }

    @Test("a module without detail asks nothing for a book's page")
    func noDetail() async throws {
        let (provider, _, folder) = try provider(module { _ in })
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install([:])
        #expect(try await provider.bookDetail(url: "https://example.com/b/1") == nil)
        #expect(ModuleStub.urls.isEmpty)
    }

    @Test("related works are asked of the page's own record by its id; the work itself is left out")
    func relatedOfOwnRecord() async throws {
        let (provider, client, folder) = try provider(module { $0["related"] = Self.related })
        defer { try? FileManager.default.removeItem(at: folder) }
        ModuleStub.install([
            "example.com/s?q=%E4%B8%89%E9%AB%94": .json(#"{"books":[{"title":"三體","author":"劉慈欣","href":"https://example.com/b/3","id":"77"}]}"#),
            "example.com/related/77": .json(#"{"works":[{"title":"球狀閃電","author":"劉慈欣","href":"https://example.com/b/4"},{"title":"三體","author":"劉慈欣","href":"https://example.com/b/3"}]}"#),
        ])
        let own = SourceItemKey(instance: provider.instance, item: "https://example.com/b/3")
        let query = WorkReviewQuery(title: "三體", authors: ["劉慈欣"], contentKind: .text, record: own)
        let found = try #require(try await WorkRelated.related(of: query, in: provider, client: client))
        #expect(found.entries.count == 1)
        #expect(ModuleStub.urls.contains("https://example.com/related/77"))
        if case .item(_, let summary, _)? = found.entries.first { #expect(summary.title == "球狀閃電") } else {
            Issue.record("not an item: \(String(describing: found.entries.first))")
        }
    }

    @Test("a module's item carries its tags to 作品詳情")
    func summaryTags() throws {
        let entry = try RuleModuleValidator.validate(module { _ in }, appVersion: "3.0.2").search!
        let item = RuleListItem(name: "甲", author: "某人", bookUrl: "https://example.com/b/1", coverUrl: "", intro: "",
                                wordCount: "", lastChapter: "", kind: "", tags: ["科幻", "太空"])
        guard case .item(_, let summary, _)? = ModuleProvider.entry(item, of: entry, instance: ModuleProvider.instanceKey(moduleID: "x"),
                                                                    hasURLRule: true, hosts: RuleModuleHosts(["example.com"])) else {
            Issue.record("no item")
            return
        }
        #expect(summary.tags == ["科幻", "太空"])
    }
}
