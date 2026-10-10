import Combine
import Foundation
import Testing
@testable import yuedu_app

// Unified library 2d: WebDAV indexing — the crawl, its store, its coordinator, and the work
// index's second input.

/// A server tree for the fake lister: folder URL → its entries.
private struct Tree {
    static let root = URL(string: "https://dav.example/books/")!
    var folders: [URL: [WebDAVBrowseClient.Entry]] = [:]

    /// `depth` levels of `width` folders, each holding `books` EPUBs and one image.
    static func make(depth: Int, width: Int, books: Int) -> Tree {
        var tree = Tree()
        func fill(_ url: URL, level: Int) {
            var entries: [WebDAVBrowseClient.Entry] = (0..<books).map { index in
                WebDAVBrowseClient.Entry(url: url.appendingPathComponent("book-\(index).epub"), name: "book-\(index).epub",
                                         isDirectory: false, size: 1_000, etag: "\"e\(index)\"")
            }
            entries.append(WebDAVBrowseClient.Entry(url: url.appendingPathComponent("cover.jpg"), name: "cover.jpg", isDirectory: false, size: 10))
            if level < depth {
                for folder in 0..<width {
                    let child = url.appendingPathComponent("f\(folder)", isDirectory: true)
                    entries.append(WebDAVBrowseClient.Entry(url: child, name: "f\(folder)", isDirectory: true, size: 0))
                    fill(child, level: level + 1)
                }
            }
            tree.folders[url] = entries
        }
        fill(root, level: 0)
        return tree
    }

    var lister: @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry] {
        let folders = folders
        return { url in
            guard let entries = folders[url] else { throw OPDSError.http(404) }
            return entries
        }
    }
}

private final class Saves: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [WebDAVIndexState] = []
    func append(_ state: WebDAVIndexState) { lock.withLock { states.append(state) } }
    var all: [WebDAVIndexState] { lock.withLock { states } }
}

@Suite("WebDAV indexer")
struct WebDAVIndexerTests {
    private func indexer(_ tree: Tree, limits: WebDAVIndexLimits, saves: Saves = Saves(),
                         list: (@Sendable (URL) async throws -> [WebDAVBrowseClient.Entry])? = nil) -> WebDAVIndexer {
        WebDAVIndexer(connectionID: "c", root: Tree.root, limits: limits, list: list ?? tree.lister,
                      save: { saves.append($0) }, now: { Date(timeIntervalSinceReferenceDate: 0) })
    }

    private func fresh() -> WebDAVIndexState { WebDAVIndexState(connectionID: "c", root: Tree.root) }

    @Test("a crawl lists every folder within the depth and keeps only book files")
    func crawl() async {
        let tree = Tree.make(depth: 2, width: 2, books: 3)
        let state = await indexer(tree, limits: .init(maxDepth: 10, foldersPerBatch: 2, maxFiles: 1_000, recrawlInterval: 0))
            .run(from: fresh(), stopAfterBatch: { false })
        #expect(state.records.count == 7 * 3, "1 + 2 + 4 folders, three EPUBs each; images skipped")
        #expect(state.outcome == .completed(21))
        #expect(state.frontier.isEmpty && state.inProgress.isEmpty)
        #expect(state.records.allSatisfy { !$0.record.acquisitions.isEmpty })
        #expect(state.records.contains { $0.record.key.item == "f1/f0/book-2.epub" && $0.etag == "\"e2\"" })
    }

    @Test("depth and file limits hold")
    func limits() async {
        let tree = Tree.make(depth: 3, width: 2, books: 1)
        let shallow = await indexer(tree, limits: .init(maxDepth: 1, foldersPerBatch: 10, maxFiles: 1_000, recrawlInterval: 0))
            .run(from: fresh(), stopAfterBatch: { false })
        #expect(shallow.records.count == 3, "the root and its two folders")

        let capped = await indexer(tree, limits: .init(maxDepth: 10, foldersPerBatch: 10, maxFiles: 4, recrawlInterval: 0))
            .run(from: fresh(), stopAfterBatch: { false })
        #expect(capped.outcome == .limitReached(4))
        #expect(capped.records.count == 4)
    }

    @Test("stopping after a batch saves the frontier; resuming finishes with the same result")
    func pauseAndResume() async {
        let tree = Tree.make(depth: 2, width: 3, books: 2)
        let limits = WebDAVIndexLimits(maxDepth: 10, foldersPerBatch: 3, maxFiles: 1_000, recrawlInterval: 0)
        let saves = Saves()
        let paused = await indexer(tree, limits: limits, saves: saves).run(from: fresh(), stopAfterBatch: { true })
        #expect(paused.outcome == .paused(.background))
        #expect(paused.isCrawling)
        #expect(paused.inProgress.count == 3 * 2, "one batch of three folders")
        #expect(saves.all.last == paused, "what was found is saved before stopping")

        let resumed = await indexer(tree, limits: limits).run(from: paused, stopAfterBatch: { false })
        let whole = await indexer(tree, limits: limits).run(from: fresh(), stopAfterBatch: { false })
        #expect(Set(resumed.records) == Set(whole.records))
        #expect(resumed.records.count == 13 * 2)
    }

    @Test("an empty library is empty, not a failure; a failure keeps the frontier")
    func emptyAndFailed() async {
        let empty = Tree(folders: [Tree.root: []])
        let none = await indexer(empty, limits: .standard).run(from: fresh(), stopAfterBatch: { false })
        #expect(none.outcome == .empty)

        let tree = Tree.make(depth: 1, width: 2, books: 1)
        let failing: @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry] = { url in
            if url == Tree.root { return try await tree.lister(url) }
            throw OPDSError.authenticationFailed
        }
        let failed = await indexer(tree, limits: .standard, list: failing).run(from: fresh(), stopAfterBatch: { false })
        guard case .failed(let kind, let message) = failed.outcome else {
            Issue.record("expected a failure, got \(String(describing: failed.outcome))")
            return
        }
        #expect(kind == .authentication)
        #expect(message == OPDSError.authenticationFailed.localizedDescription)
        #expect(failed.frontier.count == 2, "the next start resumes where it stopped")
        #expect(failed.records.isEmpty && failed.inProgress.count == 1)
        #expect(failed.visibleFiles.count == 1, "what was found so far stays visible")
    }

    @Test("cancellation stops at once and keeps the frontier")
    func cancellation() async {
        let tree = Tree.make(depth: 2, width: 2, books: 1)
        let cancelling: @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry] = { url in
            if url != Tree.root { throw CancellationError() }
            return try await tree.lister(url)
        }
        let state = await indexer(tree, limits: .standard, list: cancelling).run(from: fresh(), stopAfterBatch: { false })
        #expect(state.outcome == nil, "the caller records why it stopped")
        #expect(state.isCrawling)
    }
}

@Suite("Remote record store", .serialized)
struct RemoteRecordStoreTests {
    private func makeStore() throws -> (RemoteRecordStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteRecords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (RemoteRecordStore(directory: folder), folder)
    }

    private func state(_ id: String, files: Int) -> WebDAVIndexState {
        var state = WebDAVIndexState(connectionID: id, root: Tree.root)
        state.records = (0..<files).map { index in
            IndexedFile(record: SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .webDAV, id: id), item: "b\(index).epub"),
                                             title: "b\(index)", authors: [], language: nil, contentKind: .text, identifiers: [],
                                             copyID: nil, acquisitions: [.download(format: "epub")]),
                        etag: nil, lastModified: nil, size: 1)
        }
        state.lastCompletedAt = Date(timeIntervalSinceReferenceDate: 100)
        state.outcome = .completed(files)
        return state
    }

    @Test("states round-trip; every connection's files are listed; a save bumps the revision")
    func roundTrip() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = store.revision
        store.save(state("a", files: 2))
        store.save(state("b", files: 3))
        store.waitForPendingWritesForTesting()
        #expect(store.revision != before)
        #expect(store.state(connectionID: "a") == state("a", files: 2))
        #expect(store.allVisibleFiles().count == 5)
        #expect(store.connectionIDs() == ["a", "b"])
    }

    @Test("a file that does not decode is discarded; one that cannot be read is never written over")
    func damaged() throws {
        let (store, folder) = try makeStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent("u.json").path)
            try? FileManager.default.removeItem(at: folder)
        }
        try Data("{ nope".utf8).write(to: folder.appendingPathComponent("c.json"))
        #expect(store.state(connectionID: "c") == nil)
        store.save(state("c", files: 1))
        store.waitForPendingWritesForTesting()
        #expect(store.state(connectionID: "c")?.records.count == 1, "rebuilt over the bad file")

        let unreadable = folder.appendingPathComponent("u.json")
        try Data("original".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect(store.state(connectionID: "u") == nil)
        store.save(state("u", files: 1))
        store.waitForPendingWritesForTesting()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        #expect(try Data(contentsOf: unreadable) == Data("original".utf8))
    }

    @Test("a removed connection's index is gone, and a late save does not bring it back")
    func removal() throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.save(state("a", files: 1))
        store.remove(connectionID: "a")
        store.save(state("a", files: 2))
        store.waitForPendingWritesForTesting()
        #expect(store.state(connectionID: "a") == nil)
        #expect(store.allVisibleFiles().isEmpty)
    }
}

// MARK: - Coordinator

@MainActor
private final class FakeNetwork: NetworkPathProviding {
    let subject: CurrentValueSubject<Bool, Never>
    init(_ allowed: Bool) { subject = CurrentValueSubject(allowed) }
    var allowsBackgroundWork: Bool { subject.value }
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

@MainActor
@Suite("WebDAV index coordinator", .serialized)
struct WebDAVIndexCoordinatorTests {
    @MainActor
    private final class Context {
        let folder: URL
        let connections: OPDSCatalogStore
        let records: RemoteRecordStore
        let network: FakeNetwork
        let coordinator: WebDAVIndexCoordinator
        let defaults: UserDefaults

        init(onWiFi: Bool = true, tree: Tree = .make(depth: 1, width: 2, books: 2)) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndexCoordinator-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: "index-coordinator-\(UUID().uuidString)")!
            connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false, defaults: defaults)
            records = RemoteRecordStore(directory: folder.appendingPathComponent("remote"))
            network = FakeNetwork(onWiFi)
            let lister = tree.lister
            coordinator = WebDAVIndexCoordinator(connections: connections, network: network,
                                                 limits: .init(maxDepth: 10, foldersPerBatch: 1, maxFiles: 1_000, recrawlInterval: 3_600),
                                                 makeLister: { _, _ in lister })
        }

        func addWebDAV(indexes: Bool? = nil) -> OPDSCatalog {
            var connection = connections.add(name: "DAV", url: Tree.root.absoluteString, username: nil, password: nil, kind: .webDAV)
            connection.indexesBooks = indexes
            connections.update(connection, password: nil)
            return connection
        }

        func cleanup() {
            records.waitForPendingWritesForTesting()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test("an added WebDAV library is indexed while active on Wi-Fi, and shows its count")
    func indexes() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let connection = context.addWebDAV()
        await context.coordinator.attach(store: context.records)
        #expect(context.records.connectionIDs().isEmpty, "nothing runs before the app is active")

        context.coordinator.setActive(true)
        await context.coordinator.waitForIdleForTesting()
        context.records.waitForPendingWritesForTesting()
        #expect(context.records.state(connectionID: connection.id)?.records.count == 3 * 2)
        #expect(context.coordinator.statuses[connection.id] == .indexed(6))

        // A completed crawl is not repeated within the interval.
        context.coordinator.setActive(false)
        context.coordinator.setActive(true)
        await context.coordinator.waitForIdleForTesting()
        #expect(context.coordinator.statuses[connection.id] == .indexed(6))
    }

    @Test("nothing runs off Wi-Fi, and the row says why")
    func offWiFi() async throws {
        let context = try Context(onWiFi: false)
        defer { context.cleanup() }
        let connection = context.addWebDAV()
        await context.coordinator.attach(store: context.records)
        context.coordinator.setActive(true)
        await context.coordinator.waitForIdleForTesting()
        #expect(context.records.connectionIDs().isEmpty)
        #expect(context.coordinator.statuses[connection.id] == .pausedNotOnWiFi)

        context.network.subject.send(true)
        await Task.yield()
        await context.coordinator.waitForIdleForTesting()
        #expect(context.coordinator.statuses[connection.id] == .indexed(6))
    }

    @Test("a connection turned off, and the copy of the backup account, are not indexed")
    func disabled() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let off = context.addWebDAV(indexes: false)
        await context.coordinator.attach(store: context.records)
        context.coordinator.setActive(true)
        await context.coordinator.waitForIdleForTesting()
        #expect(context.records.state(connectionID: off.id) == nil)
        #expect(context.coordinator.statuses[off.id] == nil)

        context.defaults.set(true, forKey: "remote_library_webdav_migrated")
        context.defaults.set(Tree.root.absoluteString, forKey: "webdav_url")
        let copied = context.addWebDAV()
        #expect(context.connections.isBackupAccountCopy(copied))
        #expect(!context.connections.indexesBooks(copied), "a pre-2d copy of the backup account stays off")
    }

    @Test("removing a connection removes its index")
    func removal() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let connection = context.addWebDAV()
        await context.coordinator.attach(store: context.records)
        context.coordinator.setActive(true)
        await context.coordinator.waitForIdleForTesting()
        context.records.waitForPendingWritesForTesting()
        #expect(context.records.state(connectionID: connection.id) != nil)

        context.connections.remove(connection)
        await Task.yield()
        await context.coordinator.waitForIdleForTesting()
        context.records.waitForPendingWritesForTesting()
        #expect(context.records.state(connectionID: connection.id) == nil)
        #expect(context.coordinator.statuses[connection.id] == nil)
    }
}

/// Holds the lister on one folder until opened, and counts listings.
private actor ListGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var release: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func list(_ url: URL, holdOn held: URL, tree: Tree) async throws -> [WebDAVBrowseClient.Entry] {
        calls += 1
        if url == held {
            hasEntered = true
            entered?.resume()
            await withCheckedContinuation { release = $0 }
        }
        return try await tree.lister(url)
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

@MainActor
@Suite("WebDAV index coordinator lifecycle", .serialized)
struct WebDAVIndexLifecycleTests {
    private func context(gate: ListGate, tree: Tree) throws -> (OPDSCatalogStore, RemoteRecordStore, FakeNetwork, WebDAVIndexCoordinator, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndexLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false,
                                           defaults: UserDefaults(suiteName: "index-lifecycle-\(UUID().uuidString)")!)
        let records = RemoteRecordStore(directory: folder.appendingPathComponent("remote"))
        let network = FakeNetwork(true)
        let coordinator = WebDAVIndexCoordinator(
            connections: connections, network: network,
            limits: .init(maxDepth: 10, foldersPerBatch: 1, maxFiles: 1_000, recrawlInterval: 3_600),
            makeLister: { _, _ in { url in try await gate.list(url, holdOn: Tree.root, tree: tree) } }
        )
        return (connections, records, network, coordinator, folder)
    }

    @Test("entering the background finishes the batch in hand and records a pause; returning resumes")
    func background() async throws {
        let gate = ListGate()
        let tree = Tree.make(depth: 1, width: 2, books: 1)
        let (connections, records, _, coordinator, folder) = try context(gate: gate, tree: tree)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = connections.add(name: "DAV", url: Tree.root.absoluteString, username: nil, password: nil, kind: .webDAV)
        await coordinator.attach(store: records)
        coordinator.setActive(true)
        await gate.waitUntilEntered()

        coordinator.setActive(false)
        await gate.open()
        await coordinator.waitForIdleForTesting()
        records.waitForPendingWritesForTesting()
        let paused = try #require(records.state(connectionID: connection.id))
        #expect(paused.outcome == .paused(.background))
        #expect(paused.isCrawling)
        #expect(await gate.calls == 1, "only the batch in hand (one folder) ran")

        coordinator.setActive(true)
        await coordinator.waitForIdleForTesting()
        records.waitForPendingWritesForTesting()
        #expect(records.state(connectionID: connection.id)?.outcome == .completed(3))
        #expect(await gate.calls == 3, "the two remaining folders, not the first again")
    }

    @Test("losing Wi-Fi mid-crawl stops at once, records a pause, and lists nothing more")
    func wifiLost() async throws {
        let gate = ListGate()
        let tree = Tree.make(depth: 1, width: 2, books: 1)
        let (connections, records, network, coordinator, folder) = try context(gate: gate, tree: tree)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = connections.add(name: "DAV", url: Tree.root.absoluteString, username: nil, password: nil, kind: .webDAV)
        await coordinator.attach(store: records)
        coordinator.setActive(true)
        await gate.waitUntilEntered()

        network.subject.send(false)
        // The change reaches the coordinator through a main-actor task; yield until it has.
        for _ in 0..<100 where coordinator.stopReasonForTesting == nil { await Task.yield() }
        #expect(coordinator.stopReasonForTesting == .notOnWiFi)
        await gate.open()
        await coordinator.waitForIdleForTesting()
        records.waitForPendingWritesForTesting()

        #expect(records.state(connectionID: connection.id)?.outcome == .paused(.notOnWiFi))
        #expect(await gate.calls == 1)
        #expect(coordinator.statuses[connection.id] == .pausedNotOnWiFi)
    }
}

@MainActor
@Suite("Backup account copy", .serialized)
struct BackupAccountCopyTests {
    @Test("a pre-2d copy of the backup account is written off, and stays off when the backup account changes")
    func staysOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "backup-copy-\(UUID().uuidString)")!
        defaults.set(true, forKey: "remote_library_webdav_migrated")
        defaults.set("https://backup.example/dav/", forKey: "webdav_url")
        // A connection saved by a build before 2d: no indexing flag.
        let saved = [OPDSCatalog(name: "backup", url: "https://backup.example/dav/", kind: .webDAV),
                     OPDSCatalog(name: "books", url: "https://books.example/dav/", kind: .webDAV)]
        try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("opds_catalogs.json"))

        let store = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false, defaults: defaults)
        #expect(store.catalogs[0].indexesBooks == false, "written down at load")
        #expect(store.catalogs[1].indexesBooks == nil)
        #expect(!store.indexesBooks(store.catalogs[0]))
        #expect(store.indexesBooks(store.catalogs[1]))

        defaults.set("https://other.example/dav/", forKey: "webdav_url")
        let reloaded = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false, defaults: defaults)
        #expect(!reloaded.indexesBooks(reloaded.catalogs[0]), "a changed backup account does not turn it on")
    }
}

// MARK: - The work index's second input

@MainActor
@Suite("Work index remote records", .serialized)
struct WorkIndexRemoteRecordsTests {
    @Test("indexed WebDAV files join the index, and the shelf copy of the same file joins its record")
    func joins() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkIndexRemote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false)
        let dav = connections.add(name: "DAV", url: Tree.root.absoluteString, username: nil, password: nil, kind: .webDAV)

        var state = WebDAVIndexState(connectionID: dav.id, root: Tree.root)
        let files = ["三體.epub", "紅樓夢.epub"].map { name in
            IndexedFile(record: SourceRecord.derived(from: WebDAVBrowseClient.Entry(url: Tree.root.appendingPathComponent(name), name: name,
                                                                                    isDirectory: false, size: 1),
                                                     connectionID: dav.id, root: Tree.root)!,
                        etag: "\"1\"", lastModified: nil, size: 1)
        }
        state.records = files
        store.remoteRecords.save(state)
        store.remoteRecords.waitForPendingWritesForTesting()

        var copy = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "x.epub")
        copy.remoteSource = RemoteBookReference(connectionID: dav.id, entryID: Tree.root.appendingPathComponent("三體.epub").absoluteString,
                                                format: RemoteLibraryFormat(url: Tree.root.appendingPathComponent("三體.epub"), fileExtension: "epub",
                                                                            mimeType: "application/epub+zip"))
        store.saveReadingBook(copy)
        let context: @MainActor ([ReadingBook]) -> SourceRecordContext = { _ in
            SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { $0 == dav.id ? .webDAV : nil }, webDAVRoot: { _ in Tree.root })
        }
        let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"), makeContext: context)
        #expect(await service.refresh())
        let index = try #require(service.index)
        #expect(index.works.count == 2)
        let joined = try #require(index.work(containing: .copy(copy.id)))
        #expect(joined.members.contains(files[0].record.key))
        #expect(joined.links.contains { $0.evidence == .sameSourceItem })

        // A new crawl result is seen on the next refresh; an incremental index equals a fresh one.
        state.records.removeLast()
        store.remoteRecords.save(state)
        store.remoteRecords.waitForPendingWritesForTesting()
        #expect(await service.refresh())
        #expect(service.index?.works.count == 1)
        let fresh = WorkIndexService(store: store, directory: folder.appendingPathComponent("fresh"), makeContext: context)
        #expect(await fresh.refresh())
        #expect(fresh.index == service.index)
    }

    @Test("a WebDAV index saved while the work index is built drops the result")
    func staleRemote() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkIndexRemoteStale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"), makeContext: { _ in
            SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
        })
        service.willApplyForTesting = { store.remoteRecords.save(WebDAVIndexState(connectionID: "x", root: Tree.root)) }
        #expect(await service.refresh() == false)
        store.remoteRecords.waitForPendingWritesForTesting()
    }
}
