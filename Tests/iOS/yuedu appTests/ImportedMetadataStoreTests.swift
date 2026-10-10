import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1b: the per-copy sidecar store.
@Suite("Imported metadata store", .serialized)
struct ImportedMetadataStoreTests {
    @Test("a sidecar round-trips")
    func roundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = sample(UUID(), tags: ["科幻"])

        store.write(metadata)
        store.waitForPendingWritesForTesting()

        #expect(store.read(copyID: metadata.copyID) == metadata)
    }

    @Test("a later write merges: identifiers are unioned, a value of the same field and place is replaced")
    func merge() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let epub = sample(id, tags: ["科幻"], identifiers: [.normalized(.isbn13, "9787536692930")!])
        var aozoraKey = SourceItemKey(instance: SourceInstanceKey(type: .aozora, id: "builtin.aozora"), item: "000789")
        var aozora = ImportedMetadata(
            copyID: id, sourceItem: aozoraKey,
            identifiers: [.normalized(.aozoraWork, "000789")!],
            values: [MetadataValue(field: .language, value: .texts(["ja"]), provider: aozoraKey.instance, sourceItem: aozoraKey, fetchedAt: Date(timeIntervalSince1970: 0))]
        )

        store.write(epub)
        store.write(aozora)
        store.waitForPendingWritesForTesting()
        let merged = try #require(store.read(copyID: id))

        #expect(merged.sourceItem == aozoraKey)
        #expect(Set(merged.identifiers) == Set(epub.identifiers + aozora.identifiers))
        #expect(merged.values.contains { $0.field == .tags })
        #expect(merged.values.contains { $0.field == .language && $0.provider.type == .aozora })

        aozoraKey.item = "000789"
        aozora.values = [MetadataValue(field: .language, value: .texts(["ja-Jpan"]), provider: aozoraKey.instance, sourceItem: aozoraKey, fetchedAt: Date(timeIntervalSince1970: 1))]
        store.write(aozora)
        store.waitForPendingWritesForTesting()
        let replaced = try #require(store.read(copyID: id))
        #expect(replaced.values.filter { $0.field == .language && $0.provider.type == .aozora }.map(\.value) == [.texts(["ja-Jpan"])])
    }

    @Test("an empty capture writes no file")
    func emptyWritesNothing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()

        store.write(ImportedMetadata(copyID: id, sourceItem: .copy(id), identifiers: [], values: []))
        store.waitForPendingWritesForTesting()

        #expect(store.read(copyID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).json").path))
    }

    @Test("a sidecar that does not decode is kept aside before it is written over")
    func corruptIsKeptAside() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{ not json".utf8)
        try original.write(to: directory.appendingPathComponent("\(id.uuidString).json"))

        store.write(sample(id, tags: ["科幻"]))
        store.waitForPendingWritesForTesting()

        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        #expect(try backups.map { try Data(contentsOf: $0) } == [original])
        #expect(store.read(copyID: id)?.values.isEmpty == false)
    }

    @Test("a sidecar that cannot be read is never written over")
    func unreadableIsNeverWrittenOver() throws {
        let (store, directory) = try makeStore()
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("original".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        store.write(sample(id, tags: ["科幻"]))
        store.waitForPendingWritesForTesting()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("removing all but a set keeps the listed copies and corrupt backups")
    func removeNotIn() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = UUID()
        let gone = UUID()
        store.write(sample(kept, tags: ["a"]))
        store.write(sample(gone, tags: ["b"]))
        store.waitForPendingWritesForTesting()
        let backup = directory.appendingPathComponent("\(gone.uuidString).corrupt-1.json")
        try Data("x".utf8).write(to: backup)

        store.remove(notIn: [kept])
        store.waitForPendingWritesForTesting()

        #expect(store.read(copyID: kept) != nil)
        #expect(store.read(copyID: gone) == nil)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: - Helpers

    private func makeStore() throws -> (ImportedMetadataStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-metadata-\(UUID().uuidString)", isDirectory: true)
        return (ImportedMetadataStore(directory: directory), directory)
    }

    private func sample(_ id: UUID, tags: [String], identifiers: [ExternalIdentifier] = []) -> ImportedMetadata {
        let key = SourceItemKey.copy(id)
        return ImportedMetadata(
            copyID: id, sourceItem: key, identifiers: identifiers,
            values: [MetadataValue(field: .tags, value: .texts(tags), provider: key.instance, sourceItem: key, fetchedAt: Date(timeIntervalSince1970: 0))]
        )
    }
}
