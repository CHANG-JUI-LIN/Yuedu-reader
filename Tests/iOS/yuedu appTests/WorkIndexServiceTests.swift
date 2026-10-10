import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1c: the index of the copies on this device — on demand, applied only to
/// an unchanged shelf, incremental, rebuilt from nothing when its file is bad.
@MainActor
@Suite("Work index service", .serialized)
struct WorkIndexServiceTests {
    private let isbnX = ExternalIdentifier.normalized(.isbn13, "9787536692930")!

    @Test("nothing is built until asked")
    func onDemand() throws {
        let context = try Context()
        defer { context.cleanup() }
        context.store.saveReadingBook(context.book("三體"))

        #expect(context.service.index == nil)
        #expect(context.service.search("三體").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: context.indexURL.path))
    }

    @Test("copies sharing a sidecar ISBN are one work, and the index is saved")
    func build() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let a = context.book("三體"), b = context.book("The Three-Body Problem", author: "Liu Cixin")
        context.store.saveReadingBook(a)
        context.store.saveReadingBook(b)
        context.sidecar(a.id, identifiers: [isbnX], language: "zh-Hans")
        context.sidecar(b.id, identifiers: [isbnX], language: "zh-Hans")

        #expect(await context.service.refresh())

        let index = try #require(context.service.index)
        #expect(index.works.count == 1)
        #expect(index.works[0].editions.map(\.id) == ["text/zh-Hans"])
        #expect(context.service.search("三体").count == 1)
        WorkIndexService.waitForPendingSavesForTesting()
        #expect(FileManager.default.fileExists(atPath: context.indexURL.path))
    }

    @Test("a result built while the shelf changed is dropped")
    func staleSnapshot() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.store.saveReadingBook(context.book("三體"))
        context.service.willApplyForTesting = { context.store.saveReadingBook(context.book("紅樓夢")) }

        #expect(await context.service.refresh() == false)
        #expect(context.service.index == nil)

        context.service.willApplyForTesting = nil
        #expect(await context.service.refresh())
        #expect(context.service.index?.works.count == 2)
    }

    @Test("after adding and removing copies, the incremental index equals a full rebuild")
    func incremental() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let a = context.book("三體"), b = context.book("三體", author: "劉慈欣 著"), c = context.book("紅樓夢", author: "曹雪芹")
        for book in [a, b, c] { context.store.saveReadingBook(book) }
        #expect(await context.service.refresh())
        #expect(context.service.index?.works.count == 2)

        context.store.delete(bookId: b.id)
        let d = context.book("红楼梦", author: "曹雪芹")
        context.store.saveReadingBook(d)
        context.sidecar(a.id, identifiers: [isbnX])
        #expect(await context.service.refresh())

        let fresh = WorkIndexService(store: context.store, directory: context.root.appendingPathComponent("fresh"), makeContext: Context.noContext)
        #expect(await fresh.refresh())
        #expect(context.service.index == fresh.index)
        #expect(context.service.index?.works.count == 2)
    }

    @Test("a sidecar written after the first build is noticed")
    func lateSidecar() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let a = context.book("三體"), b = context.book("The Three-Body Problem", author: "Liu Cixin")
        context.store.saveReadingBook(a)
        context.store.saveReadingBook(b)
        context.sidecar(a.id, identifiers: [isbnX])
        #expect(await context.service.refresh())
        #expect(context.service.index?.works.count == 2)

        // Calibre, Aozora and remote imports write their sidecar after the copy is saved,
        // and that changes no shelf revision.
        context.sidecar(b.id, identifiers: [isbnX])
        #expect(await context.service.refresh())
        #expect(context.service.index?.works.count == 1)
    }

    @Test("a saved index is loaded as it is, and a bad one is discarded and rebuilt")
    func persistence() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.store.saveReadingBook(context.book("三體"))
        #expect(await context.service.refresh())
        WorkIndexService.waitForPendingSavesForTesting()
        let built = try #require(context.service.index)
        let saved = try Data(contentsOf: context.indexURL)

        let reloaded = WorkIndexService(store: context.store, directory: context.root, makeContext: Context.noContext)
        #expect(await reloaded.refresh())
        WorkIndexService.waitForPendingSavesForTesting()
        #expect(reloaded.index == built)
        #expect(try Data(contentsOf: context.indexURL) == saved, "nothing changed, so nothing was written")

        try Data("{ not an index".utf8).write(to: context.indexURL)
        let rebuilt = WorkIndexService(store: context.store, directory: context.root, makeContext: Context.noContext)
        #expect(await rebuilt.refresh())
        WorkIndexService.waitForPendingSavesForTesting()
        #expect(rebuilt.index == built)
        guard case .loaded = WorkIndexService.load(context.indexURL) else {
            Issue.record("the rebuilt index was not saved")
            return
        }
    }

    @Test("an index file that cannot be read is never written over")
    func unreadable() async throws {
        let context = try Context()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: context.indexURL.path)
            context.cleanup()
        }
        context.store.saveReadingBook(context.book("三體"))
        try FileManager.default.createDirectory(at: context.root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: context.indexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: context.indexURL.path)

        #expect(await context.service.refresh())
        WorkIndexService.waitForPendingSavesForTesting()

        #expect(context.service.index?.works.count == 1, "the index lives in memory")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: context.indexURL.path)
        #expect(try Data(contentsOf: context.indexURL) == Data("original".utf8))
    }

    @Test("a copy's language comes from its own file before any other place")
    func languagePriority() {
        let copy = UUID()
        let record = SourceRecord(key: .copy(copy), title: "x", authors: [], language: nil, contentKind: .text,
                                  identifiers: [], copyID: copy, acquisitions: [])
        let calibre = SourceInstanceKey(type: .calibre, id: "wireless:lib")
        func value(_ language: String, _ provider: SourceInstanceKey) -> MetadataValue {
            MetadataValue(field: .language, value: .texts([language]), provider: provider, sourceItem: nil, fetchedAt: .distantPast)
        }
        let metadata = ImportedMetadata(copyID: copy, sourceItem: .copy(copy), identifiers: [],
                                        values: [value("zho", calibre), value("en", .localLibrary)])
        #expect(WorkIndexService.language(in: metadata, for: record) == LanguageTag("en"))
    }

    // MARK: - Helpers

    @MainActor
    private final class Context {
        let root: URL
        let store: BookStore
        let service: WorkIndexService
        var indexURL: URL { root.appendingPathComponent("index.json") }

        static let noContext: @MainActor ([ReadingBook]) -> SourceRecordContext = { _ in
            SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
        }

        init() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkIndexServiceTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
            root = folder.appendingPathComponent("Works", isDirectory: true)
            service = WorkIndexService(store: store, directory: root, makeContext: Self.noContext)
        }

        func book(_ title: String, author: String = "劉慈欣") -> ReadingBook {
            ReadingBook(title: title, author: author, source: "local_epub", contentFilename: "\(UUID().uuidString).epub")
        }

        func sidecar(_ copy: UUID, identifiers: [ExternalIdentifier], language: String? = nil) {
            let values = language.map {
                [MetadataValue(field: .language, value: .texts([$0]), provider: .localLibrary, sourceItem: .copy(copy), fetchedAt: Date())]
            } ?? []
            store.importedMetadata.write(ImportedMetadata(copyID: copy, sourceItem: .copy(copy), identifiers: identifiers, values: values))
            store.importedMetadata.waitForPendingWritesForTesting()
        }

        func cleanup() {
            store.flushPendingMetadataSave()
            store.waitForQueuedWrites()
            store.importedMetadata.waitForPendingWritesForTesting()
            WorkIndexService.waitForPendingSavesForTesting()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }
}
