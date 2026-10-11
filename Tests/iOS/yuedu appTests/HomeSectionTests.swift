import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5a: the home's sections and their file (Phase 5 plan, 5a).
@Suite("Home sections")
struct HomeSectionTests {
    private let category = ExploreCategoryReference(sourceURL: "https://source.example", title: "排行", url: "/rank")

    private func allBindings() -> [HomeSectionBinding] {
        [
            .myLibrary, .continueReading,
            .latest,
            .sourceCategories([category]),
            .opdsFeed(connectionID: "c1", url: "https://opds.example/new"),
            .gutenbergCollection(id: "chinese"), .gutenbergFeed(url: "https://gutenberg.example/feed"),
            .aozoraNew, .aozoraIndex(kind: "authors"), .related,
        ]
    }

    @Test("every binding and layout survives encoding")
    func roundTrip() throws {
        let sections = allBindings().map { HomeSection(layout: .row, title: "標題", binding: $0, parameters: ["sort": "new"]) }
            + [HomeSection(layout: .tiles, binding: .myLibrary, isEnabled: false),
               HomeSection(layout: HomeSectionLayout(.waterfall), binding: .sourceCategories([category]))]
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

    @Test("fields a section leaves out read as their defaults")
    func defaults() throws {
        let json = """
        {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","binding":{"type":"continueReading"}}
        """
        let section = try JSONDecoder().decode(HomeSection.self, from: Data(json.utf8))
        #expect(section.title == "")
        #expect(section.isEnabled)
        #expect(section.parameters.isEmpty)
        #expect(section.binding == .continueReading)
    }

    @Test("a custom-page block reads as a source-categories section with its own id, layout and title")
    func componentAsSection() {
        let component = CustomExploreComponent(kind: .ranking, title: "榜", categories: [category])
        let section = HomeSection(component: component)
        #expect(section.id == component.id)
        #expect(section.layout.componentKind == .ranking)
        #expect(section.title == "榜")
        #expect(section.binding == .sourceCategories([category]))
    }

    // MARK: - Defaults (design §13.3, lines 700–704)

    private func kinds(_ page: HomePage) -> [String] {
        page.sections.map {
            switch $0.binding {
            case .myLibrary: "library"
            case .continueReading: "continue"
            case .latest: "latest"
            case .gutenbergCollection: "featured"
            default: "other"
            }
        }
    }

    private var featured: [String] { Array(repeating: "featured", count: PublicLibraryCollection.all.count) }

    // 我的書庫 left the defaults in 5d-1 (settled decision 12): 範圍 holds the libraries.
    @Test("book-source readers start from 繼續閱讀 → 最新 → 精選")
    func bookSourceDefaults() {
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: true)
        #expect(kinds(page) == ["continue", "latest"] + featured)
    }

    @Test("public-library readers and new installs start from 繼續閱讀 → 精選 → 最新")
    func publicLibraryDefaults() {
        let page = HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true)
        #expect(kinds(page) == ["continue"] + featured + ["latest"])
        let lists = page.sections.compactMap { section -> String? in
            if case .gutenbergCollection(let id) = section.binding { return id }
            return nil
        }
        #expect(lists == PublicLibraryCollection.all.map(\.id))
    }

    @Test("China gets no public-library section")
    func chinaDefaults() {
        for mode in ExploreMode.allCases {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: false)
            #expect(!kinds(page).contains("featured"))
        }
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: false)
        #expect(kinds(page) == ["continue", "latest"])
    }

    @Test("every default section is enabled, untitled and has its own id")
    func defaultSectionShape() {
        let page = HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true)
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
        let page = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: true)
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

    @Test("the custom-page file is not touched")
    func customPagesUntouched() throws {
        let (folder, cleanup) = try makeFolder()
        defer { cleanup() }
        let pagesURL = folder.appendingPathComponent("custom_explore_pages.json")
        let pages = CustomExplorePageStore(fileURL: pagesURL)
        pages.createPage(named: "我的頁")
        let before = try Data(contentsOf: pagesURL)

        let store = HomePageStore(fileURL: folder.appendingPathComponent("explore_home.json"))
        store.save(HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true))
        store.waitForPendingWritesForTesting()
        #expect(try Data(contentsOf: pagesURL) == before)
        #expect(try files(in: folder) == ["custom_explore_pages.json", "explore_home.json"])
    }
}
