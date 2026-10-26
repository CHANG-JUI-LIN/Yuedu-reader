import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5a: the home's sections and their file (Phase 5 plan, 5a).
@Suite("Home sections")
struct HomeSectionTests {
    private let category = ExploreCategoryReference(sourceURL: "https://source.example", title: "排行", url: "/rank")

    private func allBindings() -> [HomeSectionBinding] {
        [
            .myLibrary, .continueReading, .bookshelf,
            .latest,
            .sourceCategories([category]),
            .opdsFeed(connectionID: "c1", url: "https://opds.example/new"),
            .gutenbergCollection(id: "chinese"), .gutenbergFeed(url: "https://gutenberg.example/feed"),
            .gutenbergShelf(id: "popular"),
            .aozoraNew, .aozoraIndex(kind: "authors"), .related, .nextInSeries, .subscriptionArticles,
        ]
    }

    @Test("every binding and layout survives encoding")
    func roundTrip() throws {
        let sections = allBindings().map { HomeSection(layout: .row, title: "標題", binding: $0, parameters: ["sort": "new"]) }
            + [HomeSection(layout: .tiles, binding: .myLibrary, isEnabled: false),
               HomeSection(layout: HomeSectionLayout(.waterfall), binding: .sourceCategories([category]))]
            + [HomeSectionLayout.band, .largeRow, .heroGrid, .rankedRow].map { HomeSection(layout: $0, subtitle: "副標", binding: .latest) }
            + [HomeSectionLayout.categoryCards, .collageCards].map { HomeSection(layout: $0, binding: .gutenbergLists) }
        let page = HomePage(sections: sections)
        let decoded = try JSONDecoder().decode(HomePage.self, from: JSONEncoder().encode(page))
        #expect(decoded == page)
        #expect(decoded.sections.allSatisfy { $0.binding.isKnown && $0.layout.isKnown })
    }

    @Test("a binding and a layout from a later build are kept and written back unchanged")
    func unknownKept() throws {
        let json = """
        {"schemaVersion":1,"sections":[
          {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"spotlight","title":"",
           "binding":{"type":"moduleFeed","module":"com.example.m","params":{"n":3,"tags":["a",true,null],"w":1.5}},
           "isEnabled":true,"parameters":{}}
        ]}
        """
        let page = try JSONDecoder().decode(HomePage.self, from: Data(json.utf8))
        let section = try #require(page.sections.first)
        #expect(!section.binding.isKnown)
        #expect(!section.layout.isKnown)
        #expect(section.layout.rawValue == "spotlight")

        let reencoded = try JSONEncoder().encode(page)
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let written = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        #expect(original == written)
    }

    @Test("a section's own subtitle is kept, and one left empty is not written (schema 3)")
    func subtitle() throws {
        let section = HomeSection(layout: .band, title: "本週", subtitle: "編輯挑的漫畫", binding: .latest)
        #expect(try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section)).subtitle == "編輯挑的漫畫")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HomeSection(layout: .row, binding: .latest)))
        #expect((plain as? [String: Any])?["subtitle"] == nil)
        #expect(HomePage(sections: [section]).schemaVersion == 3)
    }

    @Test("fields a section leaves out read as their defaults")
    func defaults() throws {
        let json = """
        {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","binding":{"type":"continueReading"}}
        """
        let section = try JSONDecoder().decode(HomeSection.self, from: Data(json.utf8))
        #expect(section.title == "")
        #expect(section.subtitle == "")
        #expect(section.isEnabled)
        #expect(section.parameters.isEmpty)
        #expect(section.binding == .continueReading)
    }

    // MARK: - Defaults (design §13.3, lines 700–704)

    private func kinds(_ page: HomePage) -> [String] {
        page.sections.map {
            switch $0.binding {
            case .myLibrary: "library"
            case .continueReading: "continue"
            case .latest: "latest"
            case .gutenbergLists: "featured"
            case .gutenbergShelf("popular"): "popular"
            case .nextInSeries: "next"
            case .forYou: "forYou"
            default: "other"
            }
        }
    }

    /// 精選書單: the bundled lists as one section of cards (專題集合, decision 37), since
    /// 2026-10-13 in place of a row per list.
    private var featured: [String] { ["featured"] }

    // 我的書庫 left the defaults in 5d-1 (settled decision 12): 範圍 holds the libraries.
    // 為你推薦 after 系列下一本 for everyone since Discovery Phase 7a (maintainer's decision 4).
    @Test("book-source readers start from 繼續閱讀 → 系列下一本 → 為你推薦 → 最新 → 古騰堡熱門 → 精選")
    func bookSourceDefaults() {
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: true, languages: [])
        #expect(kinds(page) == ["continue", "next", "forYou", "latest", "popular"] + featured)
    }

    @Test("public-library readers and new installs start from 繼續閱讀 → 系列下一本 → 為你推薦 → 古騰堡熱門 → 精選 → 最新")
    func publicLibraryDefaults() {
        let page = HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true, languages: [])
        #expect(kinds(page) == ["continue", "next", "forYou", "popular"] + featured + ["latest"])
        #expect(!page.sections.contains { if case .gutenbergCollection = $0.binding { true } else { false } })
        // After Apple Books' home (2026-10-25): the download ranking ranked, the lists as cards.
        #expect(page.sections[3].layout == .rankedRow)
        #expect(page.sections[4].layout == .categoryCards)
    }

    @Test("a Gutenberg shelf is kept by id and read on the endpoint this build uses")
    func gutenbergShelf() {
        for endpoint in [GutenbergEndpoint.xml, .opds2Development] {
            #expect(GutenbergShelf.shelf(id: "popular", endpoint: endpoint)?.url == endpoint.popularURL)
            #expect(GutenbergShelf.shelf(id: "latest", endpoint: endpoint)?.url == endpoint.latestURL)
            #expect(GutenbergShelf.shelf(id: "ja", endpoint: endpoint)?.url == endpoint.languageURL("ja"))
        }
        #expect(GutenbergShelf.shelf(id: "Popular") == nil)
        #expect(GutenbergShelf.shelf(id: "") == nil)
        #expect(HomeSection(layout: .row, binding: .gutenbergShelf(id: "popular")).displayTitle(sourceName: "") == localized("熱門"))
    }

    @Test("China gets no public-library section")
    func chinaDefaults() {
        for mode in ExploreMode.allCases {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: false, languages: [])
            #expect(!kinds(page).contains("featured"))
            #expect(!kinds(page).contains("popular"))
        }
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: false, languages: [])
        #expect(kinds(page) == ["continue", "next", "forYou", "latest"])
    }

    // The official modules' lists in the reader's languages (maintainer, 2026-10-21).
    private typealias List = HomePageDefaults.ModuleList

    // The maintainer, 2026-10-25, after Apple Books' home: one band, on the first list with
    // covers; a ranking with covers ranked under them; なろう's, with none, a ranked list.
    @Test("each reading language takes its official modules' lists: Chinese Bangumi, Japanese なろう, English AniList")
    func officialModuleListsByLanguage() {
        let bangumi = [List(moduleID: "bangumi", entryID: "novel-rank", layout: .band),
                       List(moduleID: "bangumi", entryID: "manga-rank", layout: .rankedRow)]
        let narou = [List(moduleID: "narou", entryID: "weekly", layout: .rankedList)]
        let aniList = [List(moduleID: "anilist", entryID: "trending-novels", layout: .band),
                       List(moduleID: "anilist", entryID: "trending-manga", layout: .heroGrid)]
        #expect(HomePageDefaults.officialModuleLists(languages: ["zh"], publicLibrariesAvailable: true) == bangumi)
        #expect(HomePageDefaults.officialModuleLists(languages: ["ja"], publicLibrariesAvailable: true) == narou)
        #expect(HomePageDefaults.officialModuleLists(languages: ["en"], publicLibrariesAvailable: true) == aniList)
        #expect(HomePageDefaults.officialModuleLists(languages: ["ko"], publicLibrariesAvailable: true).isEmpty)
        #expect(HomePageDefaults.officialModuleLists(languages: ["ja", "zh-Hant", "zh"], publicLibrariesAvailable: true)
            == narou + bangumi, "in the languages' order, each list once; なろう never takes the band")
    }

    @Test("the page has one band: a later language's first list is a plain row")
    func officialModuleListsOneBand() {
        let lists = HomePageDefaults.officialModuleLists(languages: ["zh", "en"], publicLibrariesAvailable: true)
        #expect(lists.map(\.layout) == [.band, .rankedRow, .row, .heroGrid])
        #expect(lists.filter { $0.layout == .band }.count == 1)
    }

    @Test("なろう stays off the defaults where the public libraries are hidden")
    func officialModuleListsInChina() {
        #expect(HomePageDefaults.officialModuleLists(languages: ["ja"], publicLibrariesAvailable: false).isEmpty)
        #expect(HomePageDefaults.officialModuleLists(languages: ["zh"], publicLibrariesAvailable: false).count == 2)
    }

    @Test("the official modules' lists follow 為你推薦 for a new install, 最新 for a book-source reader")
    func officialModuleListsPlace() {
        let newInstall = HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        #expect(kinds(newInstall) == ["continue", "next", "forYou", "other", "other", "popular"] + featured + ["latest"])
        let sources = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: true, languages: ["zh"])
        #expect(kinds(sources) == ["continue", "next", "forYou", "latest", "other", "other", "popular"] + featured)
        #expect(newInstall.sections[3].binding == .module(moduleID: "bangumi", entryID: "novel-rank"))
        #expect(newInstall.sections[3].layout == .band)
    }

    @Test("every default section is enabled, untitled and has its own id")
    func defaultSectionShape() {
        let page = HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh", "ja", "en"])
        #expect(page.sections.allSatisfy { $0.isEnabled && $0.title.isEmpty && $0.parameters.isEmpty })
        #expect(Set(page.sections.map(\.id)).count == page.sections.count)
        #expect(page.schemaVersion == HomePage.currentSchemaVersion)
    }
}

@Suite("Home page store", .serialized)
@MainActor
struct HomePageStoreTests {
    private func makeFolder() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { try? FileManager.default.removeItem(at: folder) })
    }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test("no file is no page, and opening the store writes nothing")
    func emptyUntilSaved() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"))
        store.waitForPendingWritesForTesting()
        #expect(store.page == nil)
        #expect(!store.isReadOnly)
        #expect(try files(in: folder).isEmpty)
    }

    @Test("a saved page survives a relaunch")
    func roundTrip() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let url = folder.appendingPathComponent("explore_home.json")
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: true, languages: [])
        let store = HomePageStore(fileURL: url)
        store.save(page)
        store.waitForPendingWritesForTesting()
        #expect(HomePageStore(fileURL: url).page == page)
    }

    @Test("a file that does not decode is kept aside before it is written over")
    func corruptKeptAside() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let url = folder.appendingPathComponent("explore_home.json")
        try Data("{not json".utf8).write(to: url)

        let store = HomePageStore(fileURL: url)
        #expect(store.page == nil)
        #expect(!store.isReadOnly)
        let aside = try files(in: folder).filter { $0.hasPrefix("explore_home.corrupt-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside[0])) == Data("{not json".utf8))

        // A second launch before any write finds the copy it already made.
        _ = HomePageStore(fileURL: url)
        #expect(try files(in: folder).filter { $0.hasPrefix("explore_home.corrupt-") }.count == 1)

        store.save(HomePage(sections: []))
        store.waitForPendingWritesForTesting()
        #expect(HomePageStore(fileURL: url).page == HomePage(sections: []))
    }

    @Test("a file that cannot be read is never written over")
    func unreadableNotWritten() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        // A folder where the file should be: it exists and cannot be read as data.
        let url = folder.appendingPathComponent("explore_home.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let store = HomePageStore(fileURL: url)
        #expect(store.isReadOnly)
        store.save(HomePage(sections: []))
        store.waitForPendingWritesForTesting()
        #expect(store.page == HomePage(sections: []))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test("a newer build's file is read section by section and never written over")
    func newerBuildReadOnly() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let url = folder.appendingPathComponent("explore_home.json")
        let json = """
        {"schemaVersion":\(HomePage.currentSchemaVersion + 1),"sections":[
          {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","binding":{"type":"continueReading"}},
          {"id":"not-a-uuid","layout":"row","binding":{"type":"related"}},
          {"id":"7C2D9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"tiles","binding":{"type":"myLibrary"}}
        ]}
        """
        try Data(json.utf8).write(to: url)

        let store = HomePageStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(store.page?.sections.map(\.binding) == [.continueReading, .myLibrary])
        store.save(HomePage(sections: []))
        store.waitForPendingWritesForTesting()
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    @Test("the custom-page file is read, never written")
    func customPagesUntouched() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let pagesURL = folder.appendingPathComponent("custom_explore_pages.json")
        let before = try JSONEncoder().encode([CustomExplorePage(name: "我的頁")])
        try before.write(to: pagesURL)

        let store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"))
        store.save(HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true, languages: []))
        store.waitForPendingWritesForTesting()
        #expect(try Data(contentsOf: pagesURL) == before)
        #expect(try files(in: folder) == ["custom_explore_pages.json", "explore_home.json"])
    }
}
