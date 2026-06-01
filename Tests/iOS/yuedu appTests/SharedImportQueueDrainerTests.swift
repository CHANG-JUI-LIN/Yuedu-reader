import Foundation
import Testing
@testable import yuedu_app

/// Records the payloads handed to the injected import/fetch closures so tests can
/// assert what the drainer pulled off the App Group queues.
private final class CallRecorder {
    var jsonPayloads: [Data] = []
    var fetchedURLs: [URL] = []
}

@MainActor
struct SharedImportQueueDrainerTests {

    /// A throwaway App Group store, isolated per test via a unique suite name.
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "test.shared-import.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
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

        #expect(outcome == .init(importedCount: 8, failureCount: 0))
        #expect(recorder.jsonPayloads.count == 2)
        // Queue must be cleared so it isn't re-imported on the next launch.
        #expect(defaults.array(forKey: SharedImportQueueDrainer.bookSourcesQueueKey) == nil)
        #expect(drainer.lastOutcome == .init(importedCount: 8, failureCount: 0))
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

        #expect(outcome == .init(importedCount: 2, failureCount: 0))
        #expect(recorder.fetchedURLs.map(\.absoluteString)
                == ["https://example.com/a.json", "https://example.com/b.json"])
        #expect(defaults.array(forKey: SharedImportQueueDrainer.sourceURLsQueueKey) == nil)
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
        #expect(outcome == .init(importedCount: 2, failureCount: 1))
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
