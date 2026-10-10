import Foundation
import Testing
@testable import yuedu_app

/// Unified library 2a: what `OPDSBrowseModel` shows and requests, written against the model
/// before it browsed through a provider. Moving the fetch into `OPDSProvider` and
/// `GutenbergProvider` must leave every one of these unchanged.
@MainActor
@Suite("OPDS browse model behavior", .serialized)
struct OPDSBrowseModelBehaviorTests {
    @Test("a removed connection shows the existing message")
    func removedConnection() async {
        let model = OPDSBrowseModel(route: OPDSFeedRoute(catalogID: "removed-\(UUID().uuidString)", url: "https://opds.example/", title: "Gone"))
        await model.load()
        #expect(model.loadError == localized("書庫連線已移除，請重新加入伺服器。"))
        #expect(!model.didLoad)
    }

    @Test("a failure shows the failure's own text", arguments: [
        OPDSError.authenticationFailed as Error, OPDSError.http(500), OPDSError.loginPage, URLError(.notConnectedToInternet), URLError(.timedOut),
    ])
    func failureText(_ failure: Error) async {
        let model = OPDSBrowseModel(route: gutenbergRoute) { _ in throw failure }
        await model.load()
        #expect(model.loadError == failure.localizedDescription)
        #expect(!model.didLoad)
    }

    @Test("a Gutenberg search goes to Gutenberg's search URL")
    func gutenbergSearch() async {
        var requested: [URL] = []
        let model = OPDSBrowseModel(route: gutenbergRoute) { url in
            requested.append(url)
            return OPDSFeed()
        }
        await model.load(query: "  dune ")
        #expect(requested == [PublicLibrary.gutenbergSearchURL(query: "dune")])
        #expect(model.didLoad)
    }

    @Test("a catalog whose root has no search says so; one with a template searches through it")
    func catalogSearch() async throws {
        let store = RemoteLibraryConnectionStore.shared
        let connection = store.add(name: "Behavior fixture", url: "https://opds.example/root", username: nil, password: nil, kind: .opds)
        defer { store.remove(connection) }
        let route = OPDSFeedRoute(catalogID: connection.id, url: "https://opds.example/root", title: "Root")

        let plain = OPDSBrowseModel(route: route) { _ in OPDSFeed() }
        await plain.load()
        await plain.load(query: "abc")
        #expect(plain.loadError == localized("此目錄不支援搜尋"))

        var requested: [URL] = []
        let templated = OPDSBrowseModel(route: route) { url in
            requested.append(url)
            var feed = OPDSFeed()
            feed.search = .template("https://opds.example/search?q={searchTerms}", baseURL: URL(string: "https://opds.example/root")!)
            return feed
        }
        await templated.load()
        await templated.load(query: "三體")
        #expect(requested.first == URL(string: "https://opds.example/root"))
        #expect(requested.last == OPDSClient.resolveSearchTemplate("https://opds.example/search?q={searchTerms}",
                                                                    baseURL: URL(string: "https://opds.example/root")!, query: "三體"))
        #expect(templated.loadError == nil)
    }

    @Test("a failed next page keeps the entries and shows the error")
    func failedNextPage() async {
        let next = URL(string: "https://www.gutenberg.org/ebooks/search.opds/?start_index=26")!
        var entry = OPDSEntry(id: "urn:1", title: "A")
        entry.navigationURL = URL(string: "https://www.gutenberg.org/ebooks/1")
        let model = OPDSBrowseModel(route: gutenbergRoute) { url in
            if url == next { throw URLError(.networkConnectionLost) }
            var feed = OPDSFeed()
            feed.entries = [entry]
            feed.nextPageURL = next
            return feed
        }
        await model.load()
        await model.loadMore()
        #expect(model.entries.map(\.id) == ["urn:1"])
        #expect(model.failedWhileLoadingMore)
        #expect(model.loadError == URLError(.networkConnectionLost).localizedDescription)
    }

    private var gutenbergRoute: OPDSFeedRoute {
        OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue, url: "https://www.gutenberg.org/ebooks/search.opds/", title: "Gutenberg")
    }
}
