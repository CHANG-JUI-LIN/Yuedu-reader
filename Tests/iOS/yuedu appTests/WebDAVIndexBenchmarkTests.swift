import Foundation
import Testing
@testable import yuedu_app

/// Unified library 2d: the numbers behind `WebDAVIndexLimits`, measured against a real WebDAV
/// server. Run with `TEST_RUNNER_YUEDU_WEBDAV_BENCHMARK_URL=<server root>`; the server holds
/// `wide10`, `wide100` and `wide1000` (one folder of that many files) and `t1k`, `t5k` and
/// `t20k` (trees of about 1,000, 5,000 and 20,000 books). It measures and asserts nothing
/// about time.
@MainActor
@Suite("WebDAV index benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_WEBDAV_BENCHMARK_URL"] != nil))
struct WebDAVIndexBenchmarkTests {
    private let base = URL(string: ProcessInfo.processInfo.environment["YUEDU_WEBDAV_BENCHMARK_URL"] ?? "http://127.0.0.1/")!
    private let clock = ContinuousClock()

    @Test("one folder's listing, and whole crawls at three sizes")
    func benchmark() async throws {
        var lines: [String] = []

        for size in [10, 100, 1_000] {
            let folder = base.appendingPathComponent("wide\(size)/")
            let client = client(root: folder)
            _ = try await client.list(folder)  // warm the connection
            var entries = 0
            let start = clock.now
            for _ in 0..<5 { entries = try await client.list(folder).count }
            lines.append("PROPFIND Depth 1, \(size) children: \(ms((clock.now - start) / 5)) ms (\(entries) entries)")
        }

        for name in ["t1k", "t5k", "t20k"] {
            let root = base.appendingPathComponent("\(name)/")
            let client = client(root: root)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVBench-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
            let folders = FolderCounter()
            let saves = FolderCounter()
            var limits = WebDAVIndexLimits.standard
            limits.maxDepth = 20
            limits.maxFiles = 1_000_000
            let indexer = WebDAVIndexer(
                connectionID: name, root: root, limits: limits,
                list: { url in folders.increment(); return try await client.list(url) },
                save: { saves.increment(); store.remoteRecords.save($0) },
                now: { Date() }
            )
            var start = clock.now
            let state = await indexer.run(from: WebDAVIndexState(connectionID: name, root: root), stopAfterBatch: { false })
            let crawl = clock.now - start
            store.remoteRecords.waitForPendingWritesForTesting()

            let file = folder.appendingPathComponent("Works/remote/\(name).json")
            let bytes = try Data(contentsOf: file).count
            start = clock.now
            _ = store.remoteRecords.state(connectionID: name)
            let load = clock.now - start

            let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"), makeContext: { _ in
                SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
            })
            start = clock.now
            _ = await service.refresh()
            let refresh = clock.now - start

            lines.append("\(name): \(state.records.count) books in \(folders.count) folders, \(saves.count) saves; crawl \(ms(crawl)) ms "
                + "(\(ms(crawl / max(folders.count, 1))) ms a folder); state file \(bytes / 1024) KB, load \(ms(load)) ms; "
                + "work index refresh \(ms(refresh)) ms, works=\(service.index?.works.count ?? 0)")
            #expect(state.outcome == .completed(state.records.count))
        }
        print("⏱ WebDAV benchmark against \(base.absoluteString)\n  " + lines.joined(separator: "\n  "))
    }

    private func client(root: URL) -> WebDAVBrowseClient {
        WebDAVBrowseClient(serverUrl: root.absoluteString, username: "", password: "",
                           httpClient: RemoteLibraryHTTPClient(baseURL: root))
    }

    private func ms(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
    }
}

private final class FolderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
