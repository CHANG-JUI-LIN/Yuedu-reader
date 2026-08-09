import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader style asset store", .serialized)
struct ReaderStyleAssetStoreTests {
    @Test("identical imports deduplicate by normalized content hash")
    func deduplicatesImports() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let png = try #require(UIImage(systemName: "star")?.pngData())

        let first = try await store.importImage(data: png, suggestedName: "first.png")
        let second = try await store.importImage(data: png, suggestedName: "second.png")

        #expect(first.id == second.id)
        #expect(await store.assets().count == 1)
        #expect(await store.cachedImage(for: first.id) != nil)
    }

    @Test("deleting a referenced asset reports every owner")
    func protectsReferences() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let png = try #require(UIImage(systemName: "circle")?.pngData())
        let asset = try await store.importImage(data: png, suggestedName: "circle.png")
        await store.replaceReferences([
            asset.id: [.chapterLayer("layer-1"), .regexRule("rule-1")]
        ])

        await #expect(throws: ReaderStyleAssetStoreError.assetInUse(
            assetID: asset.id,
            references: [.chapterLayer("layer-1"), .regexRule("rule-1")]
        )) {
            try await store.delete(asset.id, removingReferences: false)
        }
    }

    @Test("reference scopes combine without erasing other editors")
    func referenceScopesCombine() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let assetID = readerStyleFixtureUUID(44)

        await store.replaceReferences(
            [assetID: [.chapterLayer("Chapter")]],
            scope: "chapter"
        )
        await store.replaceReferences(
            [assetID: [.regexRule("Dialogue")]],
            scope: "regex"
        )

        #expect(Set(await store.references(for: assetID)) == Set([
            .chapterLayer("Chapter"),
            .regexRule("Dialogue"),
        ]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderStyleAssetStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
