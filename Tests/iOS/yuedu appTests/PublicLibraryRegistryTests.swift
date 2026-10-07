import Foundation
import Testing
@testable import yuedu_app

@Suite("Public library registry", .serialized)
struct PublicLibraryRegistryTests {
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
