import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5c-3: the home's default sections, saved once; its 範圍; and the pages its
/// tiles, row headers and chips open.
@MainActor
@Suite("Explore home root", .serialized)
struct ExploreHomeTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExploreHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func bindings(_ page: HomePage) -> [String] {
        page.sections.map {
            switch $0.binding {
            case .myLibrary: "myLibrary"
            case .continueReading: "continueReading"
            case .latest: "latest"
            case .gutenbergCollection: "featured"
            default: "other"
            }
        }
    }

    @Test("the defaults follow the reader's mode, are saved at the first read, and never replace a saved page")
    func defaultsSavedOnce() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("explore_home.json")

        let sources = HomePageStore(fileURL: url)
        #expect(sources.page == nil)
        let saved = sources.pageOrDefaults(mode: .bookSources, publicLibrariesAvailable: true)
        let featured = PublicLibraryCollection.all.count
        #expect(bindings(saved) == ["continueReading", "latest"] + Array(repeating: "featured", count: featured))
        sources.waitForPendingWritesForTesting()

        // Read again in another mode: the saved page stands.
        let reopened = HomePageStore(fileURL: url)
        #expect(reopened.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true) == saved)
    }

    @Test("a new install starts with 繼續閱讀; China gets no public-library section; no default has 我的書庫")
    func defaultsByReader() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let newInstall = HomePageStore(fileURL: folder.appendingPathComponent("a.json"))
        let featured = PublicLibraryCollection.all.count
        #expect(bindings(newInstall.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true))
                == ["continueReading"] + Array(repeating: "featured", count: featured) + ["latest"])

        let china = HomePageStore(fileURL: folder.appendingPathComponent("b.json"))
        #expect(bindings(china.pageOrDefaults(mode: .bookSources, publicLibrariesAvailable: false))
                == ["continueReading", "latest"])
        newInstall.waitForPendingWritesForTesting()
        china.waitForPendingWritesForTesting()
    }

    @Test("範圍 is stored as a string; one this build cannot read is 全部")
    func scopeRoundTrip() {
        let key = SourceInstanceKey(type: .bookSource, id: "https://src.test/a:b")
        #expect(ExploreScope(rawValue: ExploreScope.source(key).rawValue) == .source(key))
        #expect(ExploreScope(rawValue: "") == .all)
        #expect(ExploreScope(rawValue: "later:x") == .all)
        #expect(ExploreScope(rawValue: "webDAV:") == .all)
    }

    @Test("a stored 範圍 holds while its source is there: an explore source, a saved connection, a library outside China")
    func scopeAvailability() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: "ExploreHomeTests-\(UUID().uuidString)"))
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false, defaults: defaults)
        let calibre = connections.add(name: "Calibre", url: "https://calibre.test/opds", username: nil, password: nil,
                                      kind: .calibre)

        var explore = BookSource()
        explore.bookSourceUrl = "https://src.test"
        explore.exploreUrl = "分類::https://src.test/c"
        explore.enabledExplore = true
        var searchOnly = BookSource()
        searchOnly.bookSourceUrl = "https://only.test"
        searchOnly.enabledExplore = false

        func available(_ type: ProviderType, _ id: String, libraries: Bool = true) -> Bool {
            ExploreHomeScope.isAvailable(SourceInstanceKey(type: type, id: id), sources: [explore, searchOnly],
                                         connections: connections, librariesAvailable: libraries)
        }
        #expect(available(.bookSource, "https://src.test"))
        #expect(!available(.bookSource, "https://only.test"))
        #expect(!available(.bookSource, "https://gone.test"))
        #expect(available(.calibre, calibre.id))
        #expect(!available(.opds, calibre.id), "a connection is offered as what it is")
        #expect(!available(.webDAV, "removed"))
        #expect(available(.gutenberg, PublicLibraryID.gutenberg.rawValue))
        #expect(!available(.aozora, PublicLibraryID.aozora.rawValue, libraries: false))
        #expect(!available(.library, "local"), "the shelf has no page in Explore")
    }

    @Test("a tile pushes its source's own page; the shelf and a removed connection push nothing")
    func tilePages() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: "ExploreHomeTests-\(UUID().uuidString)"))
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false, defaults: defaults)
        let opds = connections.add(name: "Feed", url: "https://feed.test/opds", username: nil, password: nil, kind: .opds)

        #expect(ExplorePlace.page(of: SourceInstanceKey(type: .bookSource, id: "https://src.test"), name: "S",
                                  connections: connections) == .explore(.source(sourceURL: "https://src.test")))
        #expect(ExplorePlace.page(of: SourceInstanceKey(type: .opds, id: opds.id), name: "Feed", connections: connections)
                == .feed(OPDSFeedRoute(catalogID: opds.id, url: opds.url, title: "Feed")))
        #expect(ExplorePlace.page(of: SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue), name: "",
                                  connections: connections) == .publicLibrary(.gutenbergHome))
        #expect(ExplorePlace.page(of: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue), name: "",
                                  connections: connections) == .publicLibrary(.aozoraHome))
        #expect(ExplorePlace.page(of: .localLibrary, name: "", connections: connections) == nil)
        #expect(ExplorePlace.page(of: SourceInstanceKey(type: .webDAV, id: "removed"), name: "", connections: connections) == nil)
    }

    private func row(_ binding: HomeSectionBinding, source: SourceInstanceKey, parameters: [String: String] = [:]) -> HomeModel.Row {
        let section = HomeSection(layout: .row, binding: binding, parameters: parameters)
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                             sourceName: "來源", policy: .local, state: .idle)
    }

    @Test("查看全部 pushes the whole of what a row starts; rows drawn from every source have none")
    func rowShowAll() {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        #expect(ExplorePlace.showAll(row(.gutenbergCollection(id: "chinese"), source: gutenberg), aozoraIndex: nil)
                == .publicLibrary(.collection(id: "chinese")))
        #expect(ExplorePlace.showAll(row(.continueReading, source: .localLibrary), aozoraIndex: nil) == nil)
        #expect(ExplorePlace.showAll(row(.related, source: .localLibrary), aozoraIndex: nil) == nil)

        // A book source's 「最新」 is the category picked for it; none picked, no page.
        let source = SourceInstanceKey(type: .bookSource, id: "https://src.test")
        let category = ExploreCategoryReference(sourceURL: "https://src.test", title: "最新", url: "https://src.test/new")
        var section = HomeSection(layout: .row, binding: .latest)
        section.setLatestCategory(category, forSourceURL: "https://src.test")
        #expect(ExplorePlace.showAll(row(.latest, source: source, parameters: section.parameters), aozoraIndex: nil)
                == .explore(.sourceCategory(category)))
        #expect(ExplorePlace.showAll(row(.latest, source: source), aozoraIndex: nil) == nil)

        // A WebDAV library's newest files come from every folder; no page lists them.
        #expect(ExplorePlace.showAll(row(.latest, source: SourceInstanceKey(type: .webDAV, id: "d")),
                                     aozoraIndex: nil) == nil)
        // Aozora's pages need its catalog.
        #expect(ExplorePlace.showAll(row(.aozoraNew, source: SourceInstanceKey(type: .aozora, id: "aozora")),
                                     aozoraIndex: nil) == nil)
    }

    @Test("a chip opens the feed or folder it names; the shelf's groups open nothing yet")
    func chipPages() {
        let opds = row(.opdsFeed(connectionID: "c", url: "https://feed.test/opds"), source: SourceInstanceKey(type: .opds, id: "c"))
        #expect(ExplorePlace.page(of: CollectionLocation(id: "https://feed.test/new", title: "新書"), in: opds, aozoraIndex: nil)
                == .feed(OPDSFeedRoute(catalogID: "c", url: "https://feed.test/new", title: "新書")))
        let dav = row(.latest, source: SourceInstanceKey(type: .webDAV, id: "d"))
        #expect(ExplorePlace.page(of: CollectionLocation(id: "https://dav.test/books/", title: "books"), in: dav, aozoraIndex: nil)
                == .folder(WebDAVDirectoryRoute(connectionID: "d", url: URL(string: "https://dav.test/books/")!, title: "books")))
        #expect(ExplorePlace.page(of: CollectionLocation(id: "group/小說", title: "小說"),
                                  in: row(.continueReading, source: .localLibrary), aozoraIndex: nil) == nil)
    }
}
