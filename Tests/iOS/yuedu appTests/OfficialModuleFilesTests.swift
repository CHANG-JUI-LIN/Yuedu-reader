import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Module ecosystem plan, M3: the bundled Bangumi and AniList files, read through the real
/// client from their sites' saved replies, and the filler's one-match rule that reaches every
/// module (guardrail 5).
@MainActor
@Suite("Official module files", .serialized)
struct OfficialModuleFilesTests {
    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let fixtures = tests.appendingPathComponent("Fixtures")
    private static let repoFiles = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Assets", isDirectory: true)
    private static let userAgent = "yuedureader/Yuedu (iOS) (+https://yuedureader.com/support)"

    private struct Fixture {
        let folder: URL
        let client: RuleModuleClient
    }

    private func makeFixture() -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialFiles-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder))
        return Fixture(folder: folder, client: client)
    }

    private func official(_ id: String) throws -> RuleModule {
        let loaded = OfficialRuleModules.load(OfficialRuleModules.files(in: Self.repoFiles), appVersion: RuleModuleVersion.app)
        return try #require(loaded.first { $0.module.id == id }).module
    }

    /// AniList's one endpoint, with or without the path's slash.
    private func aniListReplies(_ json: String) -> [String: ModuleStub.Reply] {
        ["graphql.anilist.co": .json(json), "graphql.anilist.co/": .json(json)]
    }

    private func reply(_ path: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    private func items(_ entries: [CollectionEntry]) -> [(record: SourceRecord, summary: WorkSummary)] {
        entries.compactMap { entry in
            guard case .item(let record, let summary, _) = entry else { return nil }
            return (record, summary)
        }
    }

    private func query(_ title: String, _ authors: [String], kind: ContentKind = .comic) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: title, authors: authors, identifiers: [], copySource: .localLibrary,
                          missing: [.intro, .tags], contentKind: kind)
    }

    // MARK: - The defaults

    @Test("every list the defaults name is one of its bundled module's, and its row is named by the list")
    func defaultsNameBundledLists() throws {
        let lists = HomePageDefaults.officialModuleLists(languages: ["zh", "ja", "en"], publicLibrariesAvailable: true)
        #expect(Set(lists.map(\.moduleID)) == ["bangumi", "narou", "anilist"])
        for list in lists {
            let module = try official(list.moduleID)
            #expect(module.modules.contains { $0.id == list.entryID }, "\(list.moduleID) has \(list.entryID)")
        }
        let aniList = ModuleProvider(module: try official("anilist").localized(for: "en"))
        let section = HomeSection(layout: .row, binding: .module(moduleID: "anilist", entryID: "trending-manga"))
        #expect(aniList.rowName(for: section) == "Trending Manga", "the list's title in the app's language")
        let unknown = HomeSection(layout: .row, binding: .module(moduleID: "anilist", entryID: "gone"))
        #expect(aniList.rowName(for: unknown) == "AniList", "a list it no longer has keeps the module's name")
    }

    // MARK: - Bangumi

    @Test("Bangumi: its search sends a JSON body as this app, and lists the work, its volumes and their kinds")
    func bangumiSearch() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.bgm.tv/v0/search/subjects": .json(try reply("Bangumi/bangumi-search.json"))])
        let provider = ModuleProvider(module: try official("bangumi"), client: f.client)

        let found = items(try #require(try await provider.search("葬送のフリーレン")).entries)
        let body = try JSONSerialization.jsonObject(with: Data(try #require(ModuleStub.bodies.first).utf8)) as? [String: Any]
        #expect(body?["keyword"] as? String == "葬送のフリーレン")
        #expect(ModuleStub.userAgents == [Self.userAgent], "Bangumi asks every client to name itself")
        #expect(Array(found.map(\.summary.title).prefix(2)) == ["葬送的芙莉莲", "葬送のフリーレン (1)"],
                "its Chinese name, else its own (a volume has no Chinese name)")
        #expect(found[0].record.key.item == "https://bgm.tv/subject/305429")
        #expect(found[0].record.authors == ["山田鐘人"], "原作 before 作者")
        #expect(found.allSatisfy { $0.record.contentKind == .comic })
        guard case .remote(let cover, _) = found[0].summary.cover else { Issue.record("no cover"); return }
        #expect(cover.host == "lain.bgm.tv")
    }

    @Test("Bangumi: the rankings are series only, by rank, twenty at a time; manga are comics, novels text")
    func bangumiRankings() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.bgm.tv/v0/subjects": .json(try reply("Bangumi/bangumi-browse-rank.json"))])
        let provider = ModuleProvider(module: try official("bangumi"), client: f.client)

        let manga = try await provider.page(ofList: "manga-rank", parameters: [:], after: nil)
        #expect(ModuleStub.urls == ["https://api.bgm.tv/v0/subjects?type=1&cat=1001&series=true&sort=rank&limit=20&offset=0"])
        #expect(ModuleStub.userAgents == [Self.userAgent])
        let ranked = items(manga.entries)
        #expect(Array(ranked.map(\.summary.title).prefix(2)) == ["灌篮高手 完全版", "剑风传奇"])
        #expect(ranked[1].record.authors == ["三浦建太郎（365-）"])
        #expect(ranked.allSatisfy { $0.record.contentKind == .comic })
        #expect(manga.next == CollectionCursor(value: "5"))

        ModuleStub.install(["api.bgm.tv/v0/subjects": .json(try reply("Bangumi/bangumi-browse-rank.json"))])
        let novels = try await provider.page(ofList: "novel-rank", parameters: [:], after: nil)
        #expect(ModuleStub.urls.first?.contains("cat=1002") == true)
        #expect(items(novels.entries).allSatisfy { $0.record.contentKind == .text })
    }

    // MARK: - AniList

    @Test("AniList: GraphQL with the keyword as a variable; English titles, a novel is text")
    func aniListSearch() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(aniListReplies(try reply("AniList/anilist-search.json")))
        let provider = ModuleProvider(module: try official("anilist"), client: f.client)

        let found = items(try #require(try await provider.search(#"Frieren "Beyond""#)).entries)
        let body = try JSONSerialization.jsonObject(with: Data(try #require(ModuleStub.bodies.first).utf8)) as? [String: Any]
        #expect((body?["variables"] as? [String: String])?["s"] == #"Frieren "Beyond""#, "escaped inside the JSON body")
        #expect((body?["query"] as? String)?.contains("isAdult:false") == true)
        #expect(found.map(\.summary.title) == ["Frieren: Beyond Journey’s End", "Sousou no Frieren Anthology",
                                               "Frieren: Beyond Journey’s End ~Prelude~"],
                "English, else romaji when it has no English title")
        #expect(found.map(\.record.contentKind) == [.comic, .comic, .text])
        #expect(found[0].record.key.item == "https://anilist.co/manga/118586")
        #expect(found[0].record.authors == ["Kanehito Yamada"])
    }

    @Test("AniList: trending light novels, page by page")
    func aniListTrending() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(aniListReplies(try reply("AniList/anilist-trending-novels.json")))
        let provider = ModuleProvider(module: try official("anilist"), client: f.client)

        let page = try await provider.page(ofList: "trending-novels", parameters: [:], after: nil)
        let sent = try JSONSerialization.jsonObject(with: Data(try #require(ModuleStub.bodies.first).utf8)) as? [String: String]
        #expect(sent?["query"]?.contains("Page(page:1,") == true)
        #expect(sent?["query"]?.contains("format_in:[NOVEL]") == true)
        let trending = items(page.entries)
        #expect(trending.first?.summary.title == "Mushoku Tensei: Jobless Reincarnation")
        #expect(trending.first?.record.authors == ["Rifujin na Magonote"])
        #expect(trending.allSatisfy { $0.record.contentKind == .text })
        #expect(page.next == CollectionCursor(value: "2"))
    }

    // MARK: - Fill

    @Test("a comic copy is filled by the one Bangumi work it is, by its Chinese name; not a novel copy, not another author")
    func bangumiFill() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let bangumi = try official("bangumi")
        let search = try #require(bangumi.search)
        ModuleStub.install(["api.bgm.tv/v0/search/subjects": .json(try reply("Bangumi/bangumi-search.json"))])
        let provider = ModuleProvider(module: bangumi, client: f.client)
        let found = try #require(try await provider.searchItems("葬送的芙莉蓮"))
        let work = try #require(found.first)
        let key = SourceItemKey(instance: provider.instance, item: "w")

        let result = ModuleFillProvider.result(from: found, of: search, query: query("葬送的芙莉蓮", ["山田鐘人"]), record: { _ in key })
        #expect(result.values[.intro] == .text(OnlineBookDetailPresentationPolicy.sanitizeIntro(work.intro, indentParagraphs: false)),
                "the whole summary, matched by its 中文名 in Traditional characters")
        #expect(result.values[.tags] == .texts(["旅行", "寿命论", "奇幻", "治愈", "勇者"]))
        #expect(result.sourceItem == key)

        #expect(ModuleFillProvider.result(from: found, of: search, query: query("葬送的芙莉蓮", ["山田鐘人"], kind: .text),
                                          record: { _ in key }).values.isEmpty, "a novel copy is not the manga")
        #expect(ModuleFillProvider.result(from: found, of: search, query: query("葬送的芙莉蓮", ["別人"]),
                                          record: { _ in key }).values.isEmpty)
        var twice = work
        twice.bookUrl = "https://bgm.tv/subject/1"
        #expect(ModuleFillProvider.result(from: found + [twice], of: search, query: query("葬送的芙莉蓮", ["山田鐘人"]),
                                          record: { _ in key }).values.isEmpty, "two works by that name: neither")
        #expect(ModuleFillProvider.result(from: found + [work], of: search, query: query("葬送的芙莉蓮", ["山田鐘人"]),
                                          record: { _ in key }).values.count == 2, "one work listed twice is one")
    }

    @Test("AniList fills an English copy whole; a Japanese copy of the same work gets no English summary or tags")
    func aniListFill() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let module = try official("anilist")
        let search = try #require(module.search)
        ModuleStub.install(aniListReplies(try reply("AniList/anilist-search.json")))
        let found = try #require(try await ModuleProvider(module: module, client: f.client).searchItems("Frieren"))
        let key = SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "anilist"), item: "w")

        let english = ModuleFillProvider.result(from: found, of: search, query: query("Frieren: Beyond Journey's End", ["Kanehito Yamada"]),
                                                record: { _ in key })
        guard case .text(let intro) = english.values[.intro] else { Issue.record("no intro"); return }
        #expect(intro.count > WorkSummary.blurbLimit, "not cut to a row's blurb")
        #expect(!intro.contains("<br>"))
        #expect(english.values[.tags] == .texts(["Adventure", "Drama", "Fantasy"]))

        let japanese = ModuleFillProvider.result(from: found, of: search, query: query("葬送のフリーレン", ["Kanehito Yamada"]),
                                                 record: { _ in key })
        #expect(japanese.values.isEmpty, "matched by its native title, but every value is in another script")
        #expect(japanese.sourceItem == nil)
    }

    @Test("a Japanese summary is left out for a copy whose title has no kana")
    func japaneseSummary() {
        let entry = RuleModule.Entry(id: nil, title: nil, request: RuleModule.Request(url: "https://example.com/s?q={{keyword}}"),
                                     list: RuleModule.ListRules(items: "li", title: "h3"))
        let item = RuleListItem(name: "三体", author: "劉慈欣", bookUrl: "", coverUrl: "",
                                intro: "地球の文明が三体世界と接触する物語です。", wordCount: "", lastChapter: "", kind: "")
        let key = SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "m"), item: "w")
        #expect(ModuleFillProvider.result(from: [item], of: entry, query: query("三體", ["劉慈欣"], kind: .text),
                                          record: { _ in key }).values.isEmpty)
        var kana = item
        kana.name = "三体　ぜんぶ"
        #expect(ModuleFillProvider.result(from: [kana], of: entry, query: query("三体　ぜんぶ", ["劉慈欣"], kind: .text),
                                          record: { _ in key }).values[.intro] != nil)
    }

    @Test("a comic is asked only of a module whose search can list comics; Open Library and 來源配置 take text only")
    func comicCopies() async throws {
        let comic = query("葬送の", ["山田鐘人"])
        #expect(ModuleFillProvider(provider: ModuleProvider(module: try official("bangumi"))).canLookUp(comic))
        #expect(ModuleFillProvider(provider: ModuleProvider(module: try official("anilist"))).canLookUp(comic))
        var plain = try official("bangumi")
        plain.search?.list.contentKind = nil
        #expect(!ModuleFillProvider(provider: ModuleProvider(module: plain)).canLookUp(comic))
        #expect(ModuleFillProvider(provider: ModuleProvider(module: plain)).canLookUp(query("葬送の", ["山田鐘人"], kind: .text)))

        var withISBN = comic
        withISBN.identifiers = [try #require(ExternalIdentifier.normalized(.isbn13, "9784091294562"))]
        let openLibrary = ModuleFillProvider(provider: ModuleProvider(module: try official("openlibrary")))
        #expect(!openLibrary.canLookUp(withISBN))
        withISBN.contentKind = .text
        #expect(openLibrary.canLookUp(withISBN))
        let sources = BookSourceFillProvider(search: { _, _, _ in .init(origins: [], answered: 0, queried: 0) }, hasSources: { true })
        #expect(!sources.canLookUp(comic))
        #expect(sources.canLookUp(query("葬送の", ["山田鐘人"], kind: .text)))
    }

    // MARK: - Localizations

    @Test("a module is shown in the app's language when it has one of the same script, else as written")
    func localizations() throws {
        let bangumi = try official("bangumi")
        #expect(bangumi.localized(for: "en").title == "Bangumi")
        #expect(bangumi.localized(for: "en").modules.map(\.title) == ["Top Manga", "Top Novels"])
        #expect(bangumi.localized(for: "zh-Hans").modules.first?.title == "漫画排行")
        #expect(bangumi.localized(for: "zh-Hant").modules.first?.title == "漫畫排行", "as written: zh-Hans is another script")
        #expect(bangumi.localized(for: "en-GB").modules.first?.title == "Top Manga")
        #expect(bangumi.localized(for: "fr") == bangumi)
        let anilist = try official("anilist")
        #expect(anilist.localized(for: "ja").title == "AniList", "a localization without a title keeps the module's")
        #expect(anilist.localized(for: "ja").modules.first?.title == "人気のマンガ")

        // Every official file speaks the app's five languages.
        for module in [bangumi, anilist, try official("openbd")] {
            #expect(Set((module.localizations ?? [:]).keys) == ["zh-Hans", "en", "ja", "ko"], "\(module.id)")
            for (language, text) in module.localizations ?? [:] {
                #expect(text.description?.isEmpty == false, "\(module.id) \(language)")
                #expect(Set((text.entries ?? [:]).keys) == Set(module.modules.compactMap(\.id)), "\(module.id) \(language)")
            }
        }
    }

    @Test("the library shows its modules localized")
    func libraryLocalizes() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = OfficialRuleModules.files(in: Self.repoFiles)
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder), appVersion: RuleModuleVersion.app,
                                        officialFiles: { files }, availability: nil, language: "en")
        await library.load()
        #expect(library.module(id: "bangumi")?.module.modules.first?.title == "Top Manga")
    }

    @Test("localizations: a language tag, entries the module has, and requiredVersion 3.0")
    func localizationRules() {
        func file(_ localizations: String, required: String = "3.0") -> Data {
            Data("""
            {"id":"m","title":"模組","version":"1.0","requiredVersion":"\(required)","hosts":["example.com"],
             "modules":[{"id":"new","title":"新書","request":{"url":"https://example.com/"},"list":{"items":"li","title":"h3"}}],
             "localizations":\(localizations)}
            """.utf8)
        }
        #expect(throws: Never.self) { try RuleModuleValidator.validate(file(#"{"en":{"entries":{"new":{"title":"New"}}}}"#), appVersion: "3.0") }
        #expect(throws: RuleModuleRejection.unknownValue(field: "localizations", value: "英文")) {
            try RuleModuleValidator.validate(file(#"{"英文":{"title":"M"}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.unknownValue(field: "localizations.en.entries", value: "gone")) {
            try RuleModuleValidator.validate(file(#"{"en":{"entries":{"gone":{"title":"G"}}}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.needsRequiredVersion(field: "localizations", minimum: "3.0")) {
            try RuleModuleValidator.validate(file(#"{"en":{"title":"M"}}"#, required: "2.0"), appVersion: "3.0")
        }
    }

    // MARK: - openBD (M4)

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
    }

    private func isbnQuery(_ isbn: String, title: String = "バイリンガル", missing: Set<MetadataField> = [.cover, .intro, .publisher])
        throws -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: title, authors: [], identifiers: [try #require(ExternalIdentifier.normalized(.isbn13, isbn))],
                          copySource: .localLibrary, missing: missing)
    }

    @Test("openBD: a Japanese ISBN is looked up; the record that is the copy's gives its cover, description and publisher")
    func openBDLookup() async throws {
        let f = makeFixture()
        let covers = f.folder.appendingPathComponent("covers")
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.openbd.jp/v1/get": .json(try reply("OpenBD/openbd-get-cover-description.json")),
                            "cover.openbd.jp/9784750320236.jpg": .image(png())])
        let filler = ModuleFillProvider(provider: ModuleProvider(module: try official("openbd"), client: f.client), coverDirectory: covers)
        #expect(filler.grade == .a, "by its ISBN the record is the copy's")

        let query = try isbnQuery("9784750320236")
        #expect(filler.canLookUp(query))
        let result = try await filler.lookUp(query)
        #expect(ModuleStub.urls == ["https://api.openbd.jp/v1/get?isbn=9784750320236", "https://cover.openbd.jp/9784750320236.jpg"])
        #expect(ModuleStub.userAgents.first == Self.userAgent)
        #expect(result.values[.publisher] == .text("明石書店"))
        guard case .text(let intro) = result.values[.intro] else { Issue.record("no intro: \(result.values)"); return }
        #expect(intro.hasPrefix("自然環境の中で英語を体得した"), "the long description (03), not the table of contents (04)")
        #expect(result.values[.cover] == .text("module-openbd-9784750320236.jpg"))
        #expect(FileManager.default.fileExists(atPath: covers.appendingPathComponent("module-openbd-9784750320236.jpg").path))
        #expect(result.sourceItem?.instance == ModuleProvider.instanceKey(moduleID: "openbd"))
        #expect(result.identifiers.isEmpty)
    }

    @Test("openBD: no cover listed, no cover request; a record of another ISBN is not the copy's; other ISBNs never leave")
    func openBDBounds() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.openbd.jp/v1/get": .json(try reply("OpenBD/openbd-get.json"))])
        let filler = ModuleFillProvider(provider: ModuleProvider(module: try official("openbd"), client: f.client),
                                        coverDirectory: f.folder.appendingPathComponent("covers"))
        let result = try await filler.lookUp(try isbnQuery("9784040729183"))
        #expect(ModuleStub.urls == ["https://api.openbd.jp/v1/get?isbn=9784040729183"], "its cover is empty: nothing more is asked")
        #expect(result.values == [.publisher: .text("KADOKAWA")])

        ModuleStub.install(["api.openbd.jp/v1/get": .json(try reply("OpenBD/openbd-get.json"))])
        #expect(try await filler.lookUp(try isbnQuery("9784750320236")).values.isEmpty, "the reply's record is another book")

        #expect(!filler.canLookUp(try isbnQuery("9787536692930")), "a Chinese ISBN is not openBD's")
        #expect(!filler.canLookUp(try isbnQuery("9784040729183", missing: [.language])), "nothing it can give is missing")
        var comic = try isbnQuery("9784040729183")
        comic.contentKind = .comic
        #expect(!filler.canLookUp(comic), "its lookup lists books, not comics")
        #expect(!filler.canLookUp(MetadataFillQuery(copyID: UUID(), title: "三體", authors: ["劉慈欣"], identifiers: [],
                                                    copySource: .localLibrary, missing: [.intro])), "no search: a title is never sent")
    }

    @Test("lookup: it asks by {{isbn}}, reads the record's ISBN, takes prefixes of digits, and needs format 3.0")
    func lookupRules() {
        func file(_ lookup: String, required: String = "3.0") -> Data {
            Data("""
            {"id":"m","title":"模組","version":"1.0","requiredVersion":"\(required)","hosts":["example.com"],"modules":[],
             "lookup":\(lookup)}
            """.utf8)
        }
        let good = #"{"request":{"url":"https://example.com/isbn/{{isbn}}"},"isbnPrefixes":["9784"],"list":{"items":"$[*]","title":"$.t","isbn":"$.i"}}"#
        #expect(throws: Never.self) { try RuleModuleValidator.validate(file(good), appVersion: "3.0") }
        #expect(throws: RuleModuleRejection.missingField("lookup.request.url {{isbn}}")) {
            try RuleModuleValidator.validate(file(#"{"request":{"url":"https://example.com/isbn"},"list":{"items":"$[*]","title":"$.t","isbn":"$.i"}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.emptyRule(field: "lookup.list.isbn")) {
            try RuleModuleValidator.validate(file(#"{"request":{"url":"https://example.com/{{isbn}}"},"list":{"items":"$[*]","title":"$.t"}}"#), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.unknownValue(field: "lookup.isbnPrefixes", value: "978-4")) {
            try RuleModuleValidator.validate(file(good.replacingOccurrences(of: "9784", with: "978-4")), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.needsRequiredVersion(field: "lookup", minimum: "3.0")) {
            try RuleModuleValidator.validate(file(good, required: "2.0"), appVersion: "3.0")
        }
        let searchWithPrefixes = Data("""
            {"id":"m","title":"模組","version":"1.0","requiredVersion":"3.0","hosts":["example.com"],"modules":[],
             "search":{"request":{"url":"https://example.com/s?q={{keyword}}"},"isbnPrefixes":["9784"],"list":{"items":"li","title":"h3"}}}
            """.utf8)
        #expect(throws: RuleModuleRejection.unknownValue(field: "search.isbnPrefixes", value: "9784"), "only a lookup is asked by ISBN") {
            try RuleModuleValidator.validate(searchWithPrefixes, appVersion: "3.0")
        }
    }

    @Test("a module with only a lookup is a 資料來源 place")
    func lookupFills() throws {
        let openBD = try official("openbd")
        #expect(openBD.search == nil && openBD.canFill)
        let order = MetadataFillOrder(entries: [MetadataFillOrder.Entry(place: .module("openbd"), isEnabled: true)])
        #expect(order.providers(modules: [openBD]).map(\.key) == [ModuleProvider.instanceKey(moduleID: "openbd")])
    }


    // MARK: - なろう

    @Test("なろう: search by keyword as this app, all-ages only; each work's page from its ncode, read in the app")
    func narouSearch() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.syosetu.com/novelapi/api": .json(try reply("Narou/narou-api-search.json"))])
        let module = try official("narou")
        let provider = ModuleProvider(module: module, client: f.client)

        let page = try #require(try await provider.search("無職転生"))
        let url = try #require(ModuleStub.urls.first.flatMap(URLComponents.init(string:)))
        #expect(url.host == "api.syosetu.com" && url.path == "/novelapi/api/", "novelapi has no R18 work; novel18api is not a host")
        #expect(url.queryItems?.first { $0.name == "word" }?.value == "無職転生")
        #expect(ModuleStub.userAgents == [Self.userAgent])
        let found = items(page.entries)
        #expect(found.count == 3, "the count the reply opens with is no work")
        #expect(found[0].summary.title.hasPrefix("無職転生"))
        #expect(found[0].record.authors == ["理不尽な孫の手"])
        #expect(found[0].record.key.item == "https://ncode.syosetu.com/N9669BK/")
        #expect(found[0].summary.blurb?.isEmpty == false)
        guard case .item(_, _, .moduleBook(let book)) = page.entries[0] else { Issue.record("not a book the module reads"); return }
        #expect(book.reference == ModuleBookReference(moduleID: "narou", bookURL: "https://ncode.syosetu.com/N9669BK/"))
        #expect(module.reading == ModuleReadingTests.narouReading, "the rules the reading tests read なろう's saved pages with")
        #expect(module.hosts.allSatisfy { !$0.contains("novel18") })
    }

    @Test("なろう: the weekly ranking counts its works from 1, twenty a page, so no work is listed twice")
    func narouRanking() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["api.syosetu.com/novelapi/api": .json(try reply("Narou/narou-api-weekly.json"))])
        let provider = ModuleProvider(module: try official("narou"), client: f.client)

        let first = try await provider.page(ofList: "weekly", parameters: [:], after: nil)
        let query = try #require(ModuleStub.urls.first.flatMap(URLComponents.init(string:))?.queryItems)
        #expect(query.first { $0.name == "order" }?.value == "weeklypoint")
        #expect(query.first { $0.name == "st" }?.value == "1")
        #expect(query.first { $0.name == "lim" }?.value == "20")
        #expect(items(first.entries).count == 5)
        #expect(first.next == CollectionCursor(value: "6"), "the next page starts after the fifth work, not at it")

        ModuleStub.install(["api.syosetu.com/novelapi/api": .json(try reply("Narou/narou-api-weekly.json"))])
        _ = try await provider.page(ofList: "completed", parameters: [:], after: nil)
        let completed = try #require(ModuleStub.urls.first.flatMap(URLComponents.init(string:))?.queryItems)
        #expect(completed.first { $0.name == "type" }?.value == "er", "finished serials")
    }

    @Test("a paging parameter's value is where the first page starts: a whole number, format 3.0")
    func pagingStart() throws {
        func file(_ value: String, required: String = "3.0") -> Data {
            Data("""
            {"id":"m","title":"模組","version":"1.0","requiredVersion":"\(required)","hosts":["example.com"],
             "modules":[{"id":"new","title":"新書","params":[{"name":"offset","type":"offset","value":\(value)}],
              "request":{"url":"https://example.com/?st={{offset}}"},"list":{"items":"li","title":"h3"}}]}
            """.utf8)
        }
        let module = try RuleModuleValidator.validate(file("1"), appVersion: "3.0")
        #expect(module.modules[0].firstPosition == 1)
        #expect(module.modules[0].position(after: 1, itemCount: 20) == 21)
        #expect(throws: RuleModuleRejection.unknownValue(field: "modules[0].params[0].value", value: "-1")) {
            try RuleModuleValidator.validate(file("-1"), appVersion: "3.0")
        }
        #expect(throws: RuleModuleRejection.needsRequiredVersion(field: "modules[0].params[0].value", minimum: "3.0")) {
            try RuleModuleValidator.validate(file("1", required: "2.0"), appVersion: "3.0")
        }
    }

    // MARK: - Open Library

    @Test("Open Library: its search as this app, twenty works; each author once, a cover by id or none, one language or none")
    func openLibrarySearch() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["openlibrary.org/search.json": .json(try reply("OpenLibrary/openlibrary-search.json"))])
        let provider = ModuleProvider(module: try official("openlibrary"), client: f.client)

        let page = try #require(try await provider.search("the three-body problem"))
        let url = try #require(ModuleStub.urls.first.flatMap(URLComponents.init(string:)))
        #expect(url.host == "openlibrary.org" && url.path == "/search.json")
        #expect(url.queryItems?.first { $0.name == "q" }?.value == "the three-body problem")
        #expect(url.queryItems?.first { $0.name == "limit" }?.value == "20")
        #expect(ModuleStub.userAgents == [Self.userAgent], "the app's User-Agent, never the user's email")

        let found = items(page.entries)
        #expect(found.map(\.summary.title) == ["三体", "Three-Body Problem Series", "The Three Body Problem",
                                               "The three body problem", "The Three-Body Problem Trilogy"])
        #expect(found[0].record.key.item == "https://openlibrary.org/works/OL17267881W")
        #expect(found[0].record.authors == ["刘慈欣", "Vincent Schmitt", "Gwennaël Gaffric", "Marc Simonetti"])
        #expect(found[0].record.language == nil, "a work in twelve languages is in none of them")
        #expect(found[2].record.language == "en")
        #expect(found[0].record.identifiers.contains(ExternalIdentifier.normalized(.isbn13, "1427265836")!))
        #expect(found[0].record.acquisitions == [.viewOnly], "data only: 只有資料")
        guard case .remote(let cover, _) = found[0].summary.cover else { Issue.record("no cover: \(found[0].summary.cover)"); return }
        #expect(cover.absoluteString == "https://covers.openlibrary.org/b/id/9157544-M.jpg")
        guard case .generated = found[3].summary.cover else { Issue.record("a work without cover_i has no cover address"); return }
        #expect(found[4].record.authors.isEmpty)

        ModuleStub.install([:])
        #expect(try await provider.search("三体") == nil, "Open Library refuses a query under 3 characters: not sent")
        #expect(ModuleStub.urls.isEmpty)
    }

    private func olRedirects(cover id: String, size: String) -> [String: ModuleStub.Reply] {
        let padded = String(repeating: "0", count: 10 - id.count) + id
        let archive = "archive.org/download/\(size.lowercased())_covers_0010/\(size.lowercased())_covers_0010_24.zip/\(padded)-\(size).jpg"
        return [
            "covers.openlibrary.org/b/id/\(id)-\(size).jpg": .redirect("https://\(archive)"),
            archive: .redirect("https://ia801609.us.archive.org/view_archive.php?file=\(padded)-\(size).jpg"),
            "ia801609.us.archive.org/view_archive.php": .image(png()),
        ]
    }

    @Test("Open Library: an ISBN finds the copy's edition; its own cover, through archive.org; an English description is not given to a Chinese book")
    func openLibraryLookup() async throws {
        let f = makeFixture()
        let covers = f.folder.appendingPathComponent("covers")
        defer { try? FileManager.default.removeItem(at: f.folder) }
        var replies = olRedirects(cover: "10246665", size: "L")
        replies["openlibrary.org/search.json"] = .json(try reply("OpenLibrary/openlibrary-isbn.json"))
        replies["openlibrary.org/works/OL17267881W.json"] = .json(try reply("OpenLibrary/openlibrary-work-typed.json"))
        ModuleStub.install(replies)
        let filler = ModuleFillProvider(provider: ModuleProvider(module: try official("openlibrary"), client: f.client),
                                        coverDirectory: covers)
        #expect(filler.grade == .a)

        let query = try isbnQuery("9787536692930", title: "三体", missing: [.cover, .intro, .tags])
        let result = try await filler.lookUp(query)
        let asked = try #require(ModuleStub.urls.first.flatMap(URLComponents.init(string:)))
        #expect(asked.queryItems?.first { $0.name == "q" }?.value == "isbn:9787536692930")
        #expect(result.values[.cover] == .text("module-openlibrary-9787536692930.jpg"), "the edition's cover, by its id")
        #expect(ModuleStub.urls.contains("https://covers.openlibrary.org/b/id/10246665-L.jpg?default=false"))
        #expect(result.values[.intro] == nil, "its description is English")
        #expect(result.values[.tags] == nil, "its subjects are English and Spanish")
        #expect(ModuleStub.urls.contains("https://openlibrary.org/works/OL17267881W.json"), "the description is the work's page")
        #expect(ModuleStub.userAgents.first == Self.userAgent)
        #expect(result.sourceItem?.instance == ModuleProvider.instanceKey(moduleID: "openlibrary"))
    }

    @Test("Open Library: an English copy found by title and author gets the work's description and subjects; a plain-string description too")
    func openLibraryTitleFill() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install([
            "openlibrary.org/search.json": .json(try reply("OpenLibrary/openlibrary-search-fox.json")),
            "openlibrary.org/works/OL45804W.json": .json(try reply("OpenLibrary/openlibrary-work-string.json")),
        ])
        let filler = ModuleFillProvider(provider: ModuleProvider(module: try official("openlibrary"), client: f.client))
        let result = try await filler.lookUp(query("Fantastic Mr Fox", ["Roald Dahl"], kind: .text))
        guard case .text(let intro) = result.values[.intro] else { Issue.record("no intro: \(result.values)"); return }
        #expect(intro.hasPrefix("The main character of Fantastic Mr. Fox"))
        #expect(result.values[.tags] == .texts(["Animals", "Hunger", "Juvenile fiction", "Foxes", "Fiction"]),
                "short subjects, at most five; Staff Picks is a list, not a genre")
        #expect(ModuleStub.urls.count == 2, "one search, and the page of the one work that is the copy's")
        #expect(ModuleStub.urls.last == "https://openlibrary.org/works/OL45804W.json")
    }

    @Test("AI 推薦 looks a work up through the Open Library module: one search by title and author, the work's page for its blurb; turned off, nothing is asked")
    func openLibraryRecommendation() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let suite = "OfficialFiles-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let files = OfficialRuleModules.files(in: Self.repoFiles)
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: f.folder.appendingPathComponent("library")),
                                        appVersion: RuleModuleVersion.app, officialFiles: { files }, availability: nil,
                                        language: "en", preferences: preferences)
        ModuleStub.install([
            "openlibrary.org/search.json": .json(try reply("OpenLibrary/openlibrary-search-fox.json")),
            "openlibrary.org/works/OL45804W.json": .json(try reply("OpenLibrary/openlibrary-work-string.json")),
        ])
        let resolver = ModuleRecommendationResolver(library: library, client: f.client)
        let work = AIRecommendation.Work(title: "Fantastic Mr Fox", author: "Roald Dahl", reason: "")
        let found = try #require(try await resolver.match(work))
        #expect(found.record.key == SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "openlibrary"),
                                                  item: "https://openlibrary.org/works/OL45804W"),
                "the work whose title and author match, not the film's book")
        #expect(found.cover == .remote(try #require(URL(string: "https://covers.openlibrary.org/b/id/6498519-M.jpg")), headers: [:]))
        #expect(found.blurb?.hasPrefix("The main character of Fantastic Mr. Fox") == true)
        #expect(ModuleStub.urls.count == 2)
        let search = try #require(ModuleStub.urls.first.flatMap { URLComponents(string: $0) })
        #expect(search.queryItems?.first { $0.name == "q" }?.value == "Fantastic Mr Fox Roald Dahl")

        ModuleStub.install([:])
        library.setEnabled(false, id: OfficialRuleModules.openLibraryID)
        #expect(try await resolver.match(work) == nil)
        #expect(ModuleStub.urls.isEmpty, "停用 turns AI 推薦's lookups off with the rest")
    }

    @Test("Open Library is an official module, listed after openBD")
    func openLibraryListed() throws {
        #expect(OfficialRuleModules.ids.firstIndex(of: "openlibrary") == OfficialRuleModules.ids.firstIndex(of: "openbd").map { $0 + 1 })
        let module = try official("openlibrary")
        #expect(module.lookup?.isbnPrefixes == nil, "every ISBN: it is a catalogue of the world's books")
        #expect(module.hosts.contains("*.archive.org"))
    }
}
