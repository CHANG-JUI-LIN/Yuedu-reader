import Foundation
import Testing
@testable import yuedu_app

/// Records the payloads handed to the injected import/fetch closures so tests can
/// assert what the drainer pulled off the App Group queues.
private final class CallRecorder {
    var jsonPayloads: [Data] = []
    var fetchedURLs: [URL] = []
    var importedBookFileExtensions: [String] = []
}

@MainActor
struct SharedImportQueueDrainerTests {

    /// A throwaway App Group store, isolated per test via a unique suite name.
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "test.shared-import.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makePayloadDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func queuePayload(
        _ payload: SharedImportQueueDrainer.QueuedPayload,
        in defaults: UserDefaults
    ) throws {
        defaults.set(
            [try JSONEncoder().encode(payload)],
            forKey: SharedImportQueueDrainer.payloadQueueKey
        )
    }

    @Test("drains queued JSON payloads, sums imported counts, and clears the queue")
    func drainsJSONQueue() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            [Data("[a]".utf8), Data("[b,c]".utf8)],
            forKey: SharedImportQueueDrainer.bookSourcesQueueKey
        )

        let recorder = CallRecorder()
        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { data in
                recorder.jsonPayloads.append(data)
                return data.count          // [a]=3, [b,c]=5  → 8 total
            },
            fetchURL: { _ in Data() }
        )

        let outcome = await drainer.drain()

        #expect(outcome == .init(importedCount: 8, failureCount: 0, importedBookSourceCount: 8))
        #expect(recorder.jsonPayloads.count == 2)
        // Queue must be cleared so it isn't re-imported on the next launch.
        #expect(defaults.array(forKey: SharedImportQueueDrainer.bookSourcesQueueKey) == nil)
        #expect(drainer.lastOutcome == .init(importedCount: 8, failureCount: 0, importedBookSourceCount: 8))
    }

    @Test("drains queued source URLs by fetching then importing each")
    func drainsURLQueue() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["https://example.com/a.json", "https://example.com/b.json"],
            forKey: SharedImportQueueDrainer.sourceURLsQueueKey
        )

        let recorder = CallRecorder()
        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { _ in 1 },
            fetchURL: { url in
                recorder.fetchedURLs.append(url)
                return Data("[]".utf8)
            }
        )

        let outcome = await drainer.drain()

        #expect(outcome == .init(importedCount: 2, failureCount: 0, importedBookSourceCount: 2))
        #expect(recorder.fetchedURLs.map(\.absoluteString)
                == ["https://example.com/a.json", "https://example.com/b.json"])
        #expect(defaults.array(forKey: SharedImportQueueDrainer.sourceURLsQueueKey) == nil)
    }

    @Test("generic JSON replace rules route to replace-rule importer")
    func genericReplaceRuleJSONRoutesByContent() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payloadDirectory = try makePayloadDirectory()
        defer { try? FileManager.default.removeItem(at: payloadDirectory) }

        let filename = "rules.json"
        let fileURL = payloadDirectory.appendingPathComponent(filename)
        try Data(#"[{"name":"ads","pattern":"廣告","replacement":""}]"#.utf8).write(to: fileURL)
        try queuePayload(
            .init(storageKind: .file, relativePath: filename, suggestedFilename: filename),
            in: defaults
        )

        struct WrongRoute: Error {}
        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            payloadDirectoryURL: payloadDirectory,
            importData: { _ in throw WrongRoute() },
            fetchURL: { _ in Data() },
            importBookFile: { _ in throw WrongRoute() },
            importOPMLData: { _ in throw WrongRoute() },
            importLegadoRSSData: { _ in throw WrongRoute() },
            importReplaceRuleData: { data in
                #expect(String(data: data, encoding: .utf8)?.contains("廣告") == true)
                return 1
            }
        )

        let outcome = await drainer.drain()

        #expect(outcome.importedCount == 1)
        #expect(outcome.importedReplaceRuleCount == 1)
        #expect(outcome.importedBookSourceCount == 0)
        #expect(outcome.failureCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("generic book JSON routes to local book importer instead of book source")
    func genericBookJSONRoutesToBookImporter() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payloadDirectory = try makePayloadDirectory()
        defer { try? FileManager.default.removeItem(at: payloadDirectory) }

        let filename = "novel.json"
        let fileURL = payloadDirectory.appendingPathComponent(filename)
        try Data(#"{"title":"測試小說","chapters":["第一章"]}"#.utf8).write(to: fileURL)
        try queuePayload(
            .init(storageKind: .file, relativePath: filename, suggestedFilename: filename),
            in: defaults
        )

        struct WrongRoute: Error {}
        let recorder = CallRecorder()
        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            payloadDirectoryURL: payloadDirectory,
            importData: { _ in throw WrongRoute() },
            fetchURL: { _ in Data() },
            importBookFile: { url in
                recorder.importedBookFileExtensions.append(url.pathExtension)
                return 1
            },
            importOPMLData: { _ in throw WrongRoute() },
            importLegadoRSSData: { _ in throw WrongRoute() },
            importReplaceRuleData: { _ in throw WrongRoute() }
        )

        let outcome = await drainer.drain()

        #expect(outcome.importedCount == 1)
        #expect(outcome.importedBookCount == 1)
        #expect(outcome.importedBookSourceCount == 0)
        #expect(outcome.failureCount == 0)
        #expect(recorder.importedBookFileExtensions == ["json"])
    }

    @Test("generic remote URL fetches then routes Legado RSS JSON")
    func genericRemoteURLRoutesFetchedRSSJSON() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try queuePayload(
            .init(storageKind: .remoteURL, remoteURLString: "https://example.com/rss-sources.json"),
            in: defaults
        )

        struct WrongRoute: Error {}
        let recorder = CallRecorder()
        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { _ in throw WrongRoute() },
            fetchURL: { url in
                recorder.fetchedURLs.append(url)
                return Data(#"[{"sourceName":"Feed","sourceUrl":"https://example.com/feed.xml"}]"#.utf8)
            },
            importBookFile: { _ in throw WrongRoute() },
            importOPMLData: { _ in throw WrongRoute() },
            importLegadoRSSData: { data in
                #expect(String(data: data, encoding: .utf8)?.contains("sourceName") == true)
                return 1
            },
            importReplaceRuleData: { _ in throw WrongRoute() }
        )

        let outcome = await drainer.drain()

        #expect(recorder.fetchedURLs.map(\.absoluteString) == ["https://example.com/rss-sources.json"])
        #expect(outcome.importedCount == 1)
        #expect(outcome.importedRSSCount == 1)
        #expect(outcome.importedBookSourceCount == 0)
        #expect(outcome.failureCount == 0)
    }

    @Test("a failing import is counted and the queue is not retried")
    func importFailureClearsQueue() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        struct Boom: Error {}
        defaults.set([Data("[bad]".utf8)], forKey: SharedImportQueueDrainer.bookSourcesQueueKey)

        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { _ in throw Boom() },
            fetchURL: { _ in Data() }
        )

        let first = await drainer.drain()
        #expect(first == .init(importedCount: 0, failureCount: 1))
        #expect(defaults.array(forKey: SharedImportQueueDrainer.bookSourcesQueueKey) == nil)

        // A second drain finds an empty queue → no repeated failure toast.
        let second = await drainer.drain()
        #expect(second == .init(importedCount: 0, failureCount: 0))
    }

    @Test("processes both queues and counts an invalid URL as a failure")
    func mixedQueuesWithInvalidURL() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([Data("[]".utf8)], forKey: SharedImportQueueDrainer.bookSourcesQueueKey)
        defaults.set(["https://example.com/ok.json", ""], forKey: SharedImportQueueDrainer.sourceURLsQueueKey)

        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { _ in 1 },
            fetchURL: { _ in Data("[]".utf8) }
        )

        let outcome = await drainer.drain()

        // JSON blob (+1) and the valid URL (+1) import; the empty URL fails (+1).
        #expect(outcome == .init(importedCount: 2, failureCount: 1, importedBookSourceCount: 2))
    }

    @Test("empty queues produce no outcome so no toast is shown")
    func emptyQueuesProduceNoOutcome() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let drainer = SharedImportQueueDrainer(
            defaults: defaults,
            importData: { _ in 1 },
            fetchURL: { _ in Data() }
        )

        let outcome = await drainer.drain()

        #expect(outcome == .init(importedCount: 0, failureCount: 0))
        #expect(drainer.lastOutcome == nil)
    }
}
