import Foundation
// Covers `HTTPRequestConvertible` and the stream callback, forwarded by `CountingHTTPClient`
// to the real client. Readium marks them Sendable from 4.0 (4.0.0-alpha.1); remove
// `@preconcurrency` when the app moves to Readium 4.
@preconcurrency import ReadiumShared
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
            let remoteRecords = store.remoteRecords
            let folders = FolderCounter()
            let saves = FolderCounter()
            var limits = WebDAVIndexLimits.standard
            limits.maxDepth = 20
            limits.maxFiles = 1_000_000
            let indexer = WebDAVIndexer(
                connectionID: name, root: root, limits: limits,
                list: { url in folders.increment(); return try await client.list(url) },
                save: { saves.increment(); remoteRecords.save($0) },
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

    @Test("reading the OPF and cover of real EPUBs over ranges (2e)")
    func fillBenchmark() async throws {
        // Upload 50 EPUBs of about 1 MB each (a cover, an ISBN, 1 MB of stored padding).
        let folder = base.appendingPathComponent("fill-\(UUID().uuidString.prefix(8))/")
        var mkcol = URLRequest(url: folder)
        mkcol.httpMethod = "MKCOL"
        _ = try await URLSession.shared.data(for: mkcol)
        for index in 0..<50 {
            var put = URLRequest(url: folder.appendingPathComponent("book-\(index).epub"))
            put.httpMethod = "PUT"
            _ = try await URLSession.shared.upload(for: put, from: try await FillFixtures.epub(padding: 1_000_000))
        }
        let files = try await client(root: folder).list(folder).filter(\.isImportableBook)
        let counting = CountingHTTPClient(RemoteLibraryHTTPClient(baseURL: folder))
        var state = WebDAVIndexState(connectionID: "bench", root: folder)
        state.records = files.compactMap { entry in
            SourceRecord.derived(from: entry, connectionID: "bench", root: folder).map {
                IndexedFile(record: $0, etag: entry.etag, lastModified: entry.lastModified, size: entry.size)
            }
        }
        let covers = FileManager.default.temporaryDirectory.appendingPathComponent("BenchCovers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: covers) }
        let filler = WebDAVMetadataFiller(connectionID: "bench", limits: .standard, read: { url in
            try await PublicationSession.remotePackageMetadata(remoteURL: url, httpClient: counting, coverByteLimit: WebDAVFillLimits.standard.coverByteLimit)
        }, coverDirectory: covers, save: { _ in }, now: { Date() })
        let start = clock.now
        let result = await filler.run(from: state, stopAfterBatch: { false })
        let elapsed = clock.now - start
        let read = result.records.filter { $0.filled == .read }.count
        let withISBN = result.records.filter { $0.identifiers?.contains { $0.scheme == .isbn13 } == true }.count
        print("⏱ WebDAV fill against \(folder.absoluteString)\n  \(read) of \(files.count) EPUBs read (\(withISBN) with ISBN, "
            + "\(result.records.filter { $0.cover != nil }.count) covers) in \(ms(elapsed)) ms, \(ms(elapsed / max(read, 1))) ms a book; "
            + "\(counting.requests / max(read, 1)) requests and \(counting.bytes / max(read, 1) / 1024) KB a book, file ~\(files.first.map { $0.size / 1024 } ?? 0) KB")
        #expect(read == files.count)
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

/// Counts requests and bytes on their way to a real client.
private final class CountingHTTPClient: HTTPClient, @unchecked Sendable {
    private let base: any HTTPClient
    private let lock = NSLock()
    private var requestCount = 0
    private var byteCount = 0
    init(_ base: any HTTPClient) { self.base = base }
    var requests: Int { lock.withLock { requestCount } }
    var bytes: Int { lock.withLock { byteCount } }

    /// `@concurrent`, like the Readium client it wraps: the non-Sendable `consume` then stays
    /// in one isolation domain instead of crossing from the caller's.
    @concurrent func stream(request: any HTTPRequestConvertible, consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        lock.withLock { requestCount += 1 }
        return await base.stream(request: request) { [weak self] chunk, progress in
            self?.lock.withLock { self?.byteCount += chunk.count }
            return consume(chunk, progress)
        }
    }
}
