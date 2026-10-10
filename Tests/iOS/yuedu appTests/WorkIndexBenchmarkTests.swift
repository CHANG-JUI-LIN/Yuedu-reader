import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1c: design §10.4's numbers — 2,000 copies and 5,000 remote records. Run
/// with `TEST_RUNNER_YUEDU_WORKS_BENCHMARK=1`; it measures and asserts nothing about time.
///
/// Phase 1 indexes copies only, so the 5,000 remote records go to the pure builder; the
/// service is measured on the 2,000 copies.
@MainActor
@Suite("Work index benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_WORKS_BENCHMARK"] == "1"))
struct WorkIndexBenchmarkTests {
    @Test("build, load and search at design scale")
    func benchmark() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkIndexBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = folder.appendingPathComponent("books_meta.json")
        var generator = SplitMix64(seed: 10_10)

        // 2,000 copies: 1,400 titles, so some appear twice; 40% carry an ISBN in their sidecar.
        let books = (0..<2_000).map { index -> ReadingBook in
            let title = Self.title(index % 1_400)
            return ReadingBook(title: title, author: Self.author(index % 300), source: "local_epub", contentFilename: "\(index).epub")
        }
        try JSONEncoder().encode(books).write(to: shelf)
        let sidecars = ImportedMetadataStore(besideShelfFile: shelf)
        for (index, book) in books.enumerated() where index % 5 < 2 {
            let isbn = ExternalIdentifier.normalized(.isbn13, Self.isbn(index % 1_400))
            sidecars.write(ImportedMetadata(copyID: book.id, sourceItem: .copy(book.id), identifiers: [isbn].compactMap { $0 }, values: [
                MetadataValue(field: .language, value: .texts([index % 7 == 0 ? "zh-Hant" : "zh-Hans"]),
                              provider: .localLibrary, sourceItem: .copy(book.id), fetchedAt: Date()),
            ]))
        }
        sidecars.waitForPendingWritesForTesting()
        let store = BookStore(metadataFileURL: shelf)
        #expect(store.readingBooks.count == 2_000)

        let directory = folder.appendingPathComponent("Works", isDirectory: true)
        let noContext: @MainActor ([ReadingBook]) -> SourceRecordContext = { _ in
            SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
        }
        let clock = ContinuousClock()

        let cold = WorkIndexService(store: store, directory: directory, makeContext: noContext)
        var start = clock.now
        #expect(await cold.refresh())
        let coldTime = clock.now - start
        WorkIndexService.waitForPendingSavesForTesting()
        let size = try Data(contentsOf: directory.appendingPathComponent("index.json")).count

        let warm = WorkIndexService(store: store, directory: directory, makeContext: noContext)
        start = clock.now
        #expect(await warm.refresh())
        let warmTime = clock.now - start
        let loadTime = clock.measure { _ = WorkIndexService.load(directory.appendingPathComponent("index.json")) }

        var results = 0
        let searchTime = clock.measure { results = warm.search("第500部").count }

        // The pure builder with 5,000 remote records on top.
        var entries = try #require(cold.index?.entries)
        let opds = SourceInstanceKey(type: .opds, id: "bench")
        for index in 0..<5_000 {
            let titleIndex = Int(generator.next() % 3_000)
            let record = SourceRecord(
                key: SourceItemKey(instance: opds, item: "urn:entry:\(index)"), title: Self.title(titleIndex),
                authors: [Self.author(titleIndex % 300)], language: "zh-Hans", contentKind: .text,
                identifiers: Set([ExternalIdentifier.normalized(.isbn13, Self.isbn(titleIndex))].compactMap { $0 }),
                copyID: nil, acquisitions: [.download(format: "epub")]
            )
            entries.append(WorkIndexEntry(record: record, language: LanguageTag("zh-Hans")))
        }
        var works = 0
        let builderTime = clock.measure { works = WorkIndex.build(entries: entries).works.count }
        let full = WorkIndex.build(entries: entries)
        let fullSearchTime = clock.measure { _ = full.search("第500部") }

        let titles = entries.map(\.record.title)
        let foldTime = clock.measure { for title in titles { _ = WorkMatchKey.title(title) } }

        print("""
        ⏱ works benchmark (copies=2000, remote=5000)
          WorkMatchKey.title ×\(titles.count): \(Self.ms(foldTime)) ms
          service cold refresh (snapshot + sidecar reads + build): \(Self.ms(coldTime)) ms, works=\(cold.index?.works.count ?? 0), index.json=\(size) bytes
          service warm refresh (load + stat, no rebuild): \(Self.ms(warmTime)) ms
          works.index.load (decode index.json): \(Self.ms(loadTime)) ms
          works.search.local (2000 copies): \(Self.ms(searchTime)) ms, results=\(results)
          pure build (7000 entries): \(Self.ms(builderTime)) ms, works=\(works)
          pure search (7000 entries): \(Self.ms(fullSearchTime)) ms
        """)
    }

    private static func title(_ index: Int) -> String { "第\(index)部小說：星海\(index % 97)" }
    private static func author(_ index: Int) -> String { "作者\(index)" }

    /// A valid ISBN-13 for each index.
    private static func isbn(_ index: Int) -> String {
        let stem = "978" + String(format: "%09d", index)
        let sum = stem.enumerated().reduce(0) { $0 + Int(String($1.element))! * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
        return stem + String((10 - sum % 10) % 10)
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
    }
}
