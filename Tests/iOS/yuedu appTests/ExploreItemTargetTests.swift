import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified library 5c, decision 5: what a home item opens is the page its source's own
/// screens already open, pushed by value on Explore's one stack.
@MainActor
@Suite("Explore item targets")
struct ExploreItemTargetTests {
    @Test func copyPushesExploresReaderRoute() {
        let id = UUID()
        guard case .push(let push) = ExploreItemTarget(.copy(id), aozoraIndex: nil) else {
            Issue.record("a copy opens the reader")
            return
        }
        #expect(push == .reader(PublicLibraryReaderRoute(bookID: id)))
    }

    @Test func remoteItemsPushTheBookPage() {
        let entry = OPDSEntry(id: "urn:book:1", title: "書一")
        guard case .push(let opds) = ExploreItemTarget(.opdsEntry(entry, connectionID: "calibre-1"), aozoraIndex: nil) else {
            Issue.record("an OPDS entry opens its book page")
            return
        }
        #expect(opds == .remoteBook(RemoteLibraryBookRoute(entry: entry, connectionID: "calibre-1")))

        let file = WebDAVBrowseClient.Entry(url: URL(string: "https://dav.test/books/a.epub")!, name: "a.epub",
                                            isDirectory: false, size: 1)
        guard case .push(let webDAV) = ExploreItemTarget(.webDAVFile(file, connectionID: "dav-1"), aozoraIndex: nil) else {
            Issue.record("a WebDAV file opens its book page")
            return
        }
        #expect(webDAV == .remoteBook(RemoteLibraryBookRoute(entry: file, connectionID: "dav-1")))
    }

    @Test func onlineBookPushesItsFrozenSnapshot() {
        let book = OnlineBook(name: "書名", author: "作者", intro: "", coverUrl: "", bookUrl: "https://src.test/b/1",
                              tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: "S")
        guard case .push(let push) = ExploreItemTarget(.onlineBook(FrozenOnlineBook(book: book)), aozoraIndex: nil) else {
            Issue.record("a search result opens its detail page")
            return
        }
        #expect(push == .explore(.book(book)))
    }

    @Test func publicLibraryBooksOpenTheCarousel() throws {
        let book = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Jane Austen")
        guard case .publicLibraryBook(let gutenberg) = ExploreItemTarget(.gutenberg(book), aozoraIndex: nil) else {
            Issue.record("a Gutenberg book opens the carousel")
            return
        }
        #expect(gutenberg.id == PublicLibraryBook.gutenberg(book).id)

        let index = AozoraCatalogIndex.preview
        let work = try #require(index.newWorks.first)
        guard case .publicLibraryBook(let aozora) = ExploreItemTarget(.aozora(work), aozoraIndex: index) else {
            Issue.record("an Aozora work opens the carousel")
            return
        }
        #expect(aozora.id == "aozora:" + work.id)
        #expect(ExploreItemTarget(.aozora(work), aozoraIndex: nil) == nil, "no catalog, nothing to show it with")
    }

    @Test func pushAppendsTheRouteItself() {
        var path = NavigationPath()
        ExplorePush.reader(PublicLibraryReaderRoute(bookID: UUID())).append(to: &path)
        ExplorePush.explore(.sourceManager).append(to: &path)
        #expect(path.count == 2)
    }

    @Test func feedRoutesNameTheirView() {
        let list = OPDSFeedRoute(catalogID: "c", url: "https://opds.test/", title: "T")
        let storefront = OPDSFeedRoute(catalogID: "c", url: "https://opds.test/", title: "T", presentation: .storefront)
        #expect(list.presentation == .list)
        #expect(list != storefront, "one route opens one view")
    }

    @Test func storeRoutesCompareByWhatTheyShow() throws {
        let index = AozoraCatalogIndex.preview
        #expect(PublicLibraryRoute.collection(id: "chinese") == .collection(id: "chinese"))
        #expect(PublicLibraryRoute.collection(id: "chinese") != .collection(id: "fiction"))
        #expect(PublicLibraryRoute.categories(index) == .categories(nil))
        let works = index.newWorks
        var other = try #require(works.first)
        other.id = "2"
        #expect(PublicLibraryRoute.aozoraWorks(title: "新着", works: works, index: index)
            == .aozoraWorks(title: "新着", works: works, index: index))
        #expect(PublicLibraryRoute.aozoraWorks(title: "新着", works: works, index: index)
            != .aozoraWorks(title: "新着", works: works + [other], index: index))
        #expect(PublicLibraryRoute.aozoraCatalog(.authors, index) != .aozoraCatalog(.titles, index))
    }
}
