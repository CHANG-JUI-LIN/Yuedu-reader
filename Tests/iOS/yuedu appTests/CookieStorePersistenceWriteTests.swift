import Foundation
import Testing
@testable import yuedu_app

/// crashlytics_fa6a505e…: MetricKit flagged 1 GB of background writes from `CookieStore.save()`.
/// Every `didFinish` in the source web page synced every WebKit cookie, one `set` per domain,
/// and each `set` rewrote the whole JSON file — whether or not anything had changed.
@Suite("CookieStore persistence writes", .serialized)
struct CookieStorePersistenceWriteTests {

    private func makeStore() -> (CookieStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-store-\(UUID().uuidString).json")
        return (CookieStore(fileURL: url), url)
    }

    private func entries(_ tag: String) -> [(url: String, cookie: String)] {
        [
            ("https://a-\(tag).example.com", "sid=1; token=abc"),
            ("https://b-\(tag).example.com", "uid=2"),
            ("https://c-\(tag).example.com", "cf_clearance=xyz; lang=zh"),
        ]
    }

    @Test("a multi-domain batch writes the file once")
    func batchWritesOnce() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let batch = entries(UUID().uuidString)

        store.set(batch)

        #expect(store.persistedWriteCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.get(url: batch[1].url).contains("uid=2"))
    }

    @Test("the same batch again does not touch the file")
    func unchangedBatchSkipsWrite() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let batch = entries(UUID().uuidString)

        store.set(batch)
        let modified = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        store.set(batch)
        // Same pairs in a different order are the same cookies.
        store.set(batch.reversed().map { ($0.url, $0.cookie
            .components(separatedBy: "; ").reversed().joined(separator: "; ")) })

        #expect(store.persistedWriteCount == 1)
        let modifiedAfter = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(modified == modifiedAfter)
    }

    @Test("set(url:cookie:) skips the write when the merged value is unchanged")
    func singleSetSkipsUnchanged() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = "https://single-\(UUID().uuidString).example.com"

        store.set(url: host, cookie: "a=1; b=2")
        store.set(url: host, cookie: "b=2")
        #expect(store.persistedWriteCount == 1)

        store.set(url: host, cookie: "b=3")
        #expect(store.persistedWriteCount == 2)
        #expect(store.get(url: host).contains("b=3"))
    }

    @Test("a changed cookie in a batch is persisted and survives a reload")
    func changedBatchPersists() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = "https://reload-\(UUID().uuidString).example.com"

        store.set([(host, "sid=old")])
        store.set([(host, "sid=new")])
        #expect(store.persistedWriteCount == 2)

        // Clear the session jar so `get` reads the reloaded file, not HTTPCookieStorage.
        for cookie in HTTPCookieStorage.shared.cookies(for: URL(string: host)!) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        let reloaded = CookieStore(fileURL: url)
        for cookie in HTTPCookieStorage.shared.cookies(for: URL(string: host)!) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        #expect(reloaded.get(url: host) == "sid=new")
    }
}
