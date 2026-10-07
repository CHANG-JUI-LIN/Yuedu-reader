import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora catalog cache", .serialized)
@MainActor
struct AozoraCatalogStoreTests {
    private func environment() throws -> (URL, UserDefaults, String) {
        let suite = "AozoraCatalogStoreTests.\(UUID().uuidString)"
        return (FileManager.default.temporaryDirectory.appendingPathComponent(suite), try #require(UserDefaults(suiteName: suite)), suite)
    }
    private func clean(_ directory: URL, _ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
    }
    private func manifest(_ data: Data, badHash: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sha256": badHash ? String(repeating: "0", count: 64) : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "workCount": 2])
    }

    @Test func cacheDailyCheckAndForcedRefresh() async throws {
        let (directory, defaults, suite) = try environment()
        defer { clean(directory, defaults, suite) }
        let data = try AozoraCatalogTests.fixture
        let manifest = try manifest(data)
        var requests: [String] = []
        var now = Date(timeIntervalSince1970: 100_000)
        let fetch: (URL) async throws -> Data = { url in
            requests.append(url.lastPathComponent)
            return url.lastPathComponent == "manifest.json" ? manifest : data
        }
        let store = AozoraCatalogStore(directory: directory, defaults: defaults, now: { now }, fetch: fetch)
        await store.load()
        #expect(store.catalog?.newWorks.count == 2)
        #expect(requests == ["manifest.json", "works.json"])
        await store.load()
        #expect(requests.count == 2)
        now.addTimeInterval(86_401)
        await store.load()
        #expect(requests == ["manifest.json", "works.json", "manifest.json"])
        await store.load(forceRefresh: true)
        #expect(requests.count == 4)
        let reopened = AozoraCatalogStore(directory: directory, defaults: defaults, now: { now }, fetch: { _ in
            Issue.record("Reading a cache must not wait for or request the network")
            throw URLError(.notConnectedToInternet)
        })
        await reopened.loadCached()
        #expect(reopened.catalog?.newWorks.count == 2)
    }

    @Test func hashMismatchKeepsAtomicCache() async throws {
        let (directory, defaults, suite) = try environment()
        defer { clean(directory, defaults, suite) }
        let data = try AozoraCatalogTests.fixture
        var advertised = try manifest(data)
        let store = AozoraCatalogStore(directory: directory, defaults: defaults, fetch: { url in
            url.lastPathComponent == "manifest.json" ? advertised : data
        })
        await store.load()
        let before = try Data(contentsOf: store.cacheURL)
        advertised = try manifest(data, badHash: true)
        await store.load(forceRefresh: true)
        guard case .failed(_, let cached) = store.state else { Issue.record("A hash mismatch must be visible"); return }
        #expect(cached?.newWorks.count == 2)
        #expect(try Data(contentsOf: store.cacheURL) == before)
    }

    @Test func changedHashReplacesCache() async throws {
        let (directory, defaults, suite) = try environment()
        defer { clean(directory, defaults, suite) }
        var data = try AozoraCatalogTests.fixture
        var advertised = try manifest(data)
        let store = AozoraCatalogStore(directory: directory, defaults: defaults, fetch: { url in
            url.lastPathComponent == "manifest.json" ? advertised : data
        })
        await store.load()
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "架空の物語", with: "更新した物語").utf8)
        advertised = try manifest(data)
        await store.load(forceRefresh: true)
        #expect(store.catalog?.worksByID["1"]?.title == "更新した物語")
        let reopened = AozoraCatalogStore(directory: directory, defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
        await reopened.loadCached()
        #expect(reopened.catalog?.worksByID["1"]?.title == "更新した物語")
    }

    @Test func absentCatalogIsUnavailable() async throws {
        let errors: [any Error] = [OPDSError.http(404), URLError(.notConnectedToInternet)]
        for error in errors {
            let (directory, defaults, suite) = try environment()
            defer { clean(directory, defaults, suite) }
            let store = AozoraCatalogStore(directory: directory, defaults: defaults, fetch: { _ in throw error })
            await store.load()
            guard case .unavailable = store.state else { Issue.record("No cache and no catalog must be unavailable"); continue }
            #expect(store.catalog == nil)
        }
    }
}
