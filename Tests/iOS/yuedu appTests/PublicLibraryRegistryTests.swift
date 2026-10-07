import Foundation
import Testing
@testable import yuedu_app

@Suite("Public library registry", .serialized)
struct PublicLibraryRegistryTests {
    @Test func builtInListsShowThumbnailsButNeverFullCovers() {
        let inline = URL(string: "data:image/png;base64,iVBORw0KGgo=")!
        let small = URL(string: "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg")!
        let medium = URL(string: "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg")!
        let gutenberg = "builtin.gutenberg"
        // XML feeds: the embedded thumbnail.
        let embedded = OPDSEntry(id: "a", title: "A", thumbnailURL: inline)
        #expect(PublicLibrary.listCoverURL(for: embedded, connectionID: gutenberg) == inline)
        // OPDS 2: the small remote thumbnail, not the medium cover.
        let remote = OPDSEntry(id: "b", title: "B", thumbnailURL: small, coverURL: medium)
        #expect(PublicLibrary.listCoverURL(for: remote, connectionID: gutenberg) == small)
        let coverOnly = OPDSEntry(id: "c", title: "C", coverURL: medium)
        #expect(PublicLibrary.listCoverURL(for: coverOnly, connectionID: gutenberg) == nil)
        #expect(PublicLibrary.listCoverURL(for: OPDSEntry(id: "d", title: "D"), connectionID: gutenberg) == nil)
        // Other catalogs keep their thumbnail-or-cover behavior.
        #expect(PublicLibrary.listCoverURL(for: coverOnly, connectionID: "saved-catalog") == medium)
        #expect(PublicLibrary.listCoverURL(for: remote, connectionID: "saved-catalog") == small)
    }

    @Test func builtInConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let store = OPDSCatalogStore(storageDirectory: directory, importLegacyWebDAV: false)
        let catalog = try #require(store.connection(id: "builtin.gutenberg"))
        #expect(catalog.url == "https://www.gutenberg.org/ebooks.opds/")
        #expect(catalog.name == "Project Gutenberg")
        #expect(store.catalogs.isEmpty)
        var edited = catalog
        edited.name = "Changed"
        store.update(edited, password: nil)
        store.remove(catalog)
        #expect(store.connection(id: catalog.id) == catalog)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("opds_catalogs.json").path))
        let saved = store.add(name: "Saved", url: "https://example.com/opds", username: nil, password: nil)
        defer { store.remove(saved) }
        let data = try Data(contentsOf: directory.appendingPathComponent("opds_catalogs.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("builtin.gutenberg"))
        #expect(OPDSCatalogStore.presets.first?.url == catalog.url)
    }

    @Test func searchEncodesQueryWithoutChangingItsMeaning() {
        for query in ["中文 書 & 詩", "猫+犬", "a&b=c?#/", "日本語"] {
            let url = PublicLibrary.gutenbergSearchURL(query: query)
            #expect(url.host == "www.gutenberg.org")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "query", value: query)])
            #expect(!url.absoluteString.contains("+"))
        }
    }

    @Test func shelvesFollowInterfaceLanguage() {
        for (language, query) in [("zh-Hant", "l.zh"), ("zh-Hans", "l.zh"), ("ja", "l.ja"), ("ko", "l.ko")] {
            let shelves = GutenbergShelf.shelves(language: language)
            #expect(shelves.count == 4)
            #expect(URLComponents(url: shelves[2].url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "query", value: query)) == true)
            #expect(shelves[2].url.absoluteString.contains("sort_order=downloads"))
        }
        #expect(GutenbergShelf.shelves(language: "en").count == 3)
        #expect(GutenbergShelf.shelves(language: "fr").count == 3)
    }
}
