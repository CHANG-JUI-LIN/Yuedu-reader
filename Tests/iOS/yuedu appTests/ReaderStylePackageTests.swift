import CryptoKit
import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader style packages", .serialized)
struct ReaderStylePackageTests {
    @Test("manifest and referenced assets round trip")
    func roundTrip() async throws {
        let sourceRoot = try readerStyleTemporaryDirectory()
        let destinationRoot = try readerStyleTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let sourceStore = ReaderStyleAssetStore(rootURL: sourceRoot)
        let data = try #require(UIImage(systemName: "book")?.pngData())
        let asset = try await sourceStore.importImage(data: data, suggestedName: "book.png")
        let style = ChapterTitleStyle.default
        let payload = try ReaderStylePackagePayload.encode(
            style,
            kind: .chapterTitle,
            assetIDs: [asset.id]
        )

        let archive = try await ReaderStylePackage.export(payload, assetStore: sourceStore)
        let destinationStore = ReaderStyleAssetStore(rootURL: destinationRoot)
        let imported = try await ReaderStylePackage.import(archive, assetStore: destinationStore)

        #expect(try imported.decode(ChapterTitleStyle.self) == style)
        #expect(await destinationStore.cachedImage(for: asset.id) != nil)
        #expect(await destinationStore.assets().map(\.id) == [asset.id])
    }

    @Test("archive paths cannot leave extraction root")
    func rejectsTraversal() {
        #expect(throws: ReaderStylePackageError.unsafePath("../escape.png")) {
            try ReaderStylePackage.validateEntryPaths(["../escape.png"])
        }
        #expect(throws: ReaderStylePackageError.unsafePath("assets\\..\\escape.png")) {
            try ReaderStylePackage.validateEntryPaths(["assets\\..\\escape.png"])
        }
        #expect(throws: ReaderStylePackageError.unsafePath("/tmp/escape.png")) {
            try ReaderStylePackage.validateEntryPaths(["/tmp/escape.png"])
        }
    }

    @Test("missing referenced asset aborts export")
    func rejectsMissingExportAsset() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingID = readerStyleFixtureUUID(90)
        let payload = try ReaderStylePackagePayload.encode(
            ChapterTitleStyle.default,
            kind: .chapterTitle,
            assetIDs: [missingID]
        )

        await #expect(throws: ReaderStylePackageError.missingAsset(missingID)) {
            try await ReaderStylePackage.export(
                payload,
                assetStore: ReaderStyleAssetStore(rootURL: root)
            )
        }
    }

    @Test("hash mismatch leaves destination assets unchanged")
    func hashMismatchIsAtomic() async throws {
        let destinationRoot = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let destinationStore = ReaderStyleAssetStore(rootURL: destinationRoot)
        let originalData = try #require(UIImage(systemName: "star")?.pngData())
        let original = try await destinationStore.importImage(
            data: originalData,
            suggestedName: "original.png"
        )

        let importedID = readerStyleFixtureUUID(91)
        let manifest = ReaderStylePackageManifest(
            version: ReaderStylePackageManifest.currentVersion,
            payload: try ReaderStylePackagePayload.encode(
                ChapterTitleStyle.default,
                kind: .chapterTitle,
                assetIDs: [importedID]
            ),
            assets: [
                ReaderStylePackageAsset(
                    id: importedID,
                    relativePath: "assets/\(importedID.uuidString.lowercased()).png",
                    sha256: String(repeating: "0", count: 64),
                    byteCount: originalData.count
                )
            ]
        )
        let archive = try await makeArchive(
            manifest: manifest,
            assets: [manifest.assets[0].relativePath: originalData]
        )

        await #expect(throws: ReaderStylePackageError.hashMismatch(
            manifest.assets[0].relativePath
        )) {
            try await ReaderStylePackage.import(archive, assetStore: destinationStore)
        }
        #expect(await destinationStore.assets().map(\.id) == [original.id])
    }

    @Test("legacy chapter title JSON is sanitized")
    func legacyJSONIsSanitized() throws {
        var style = ChapterTitleStyle.default
        style.size = 10_000
        let decoded = try ReaderStylePackage.decodeLegacyChapterTitleJSON(
            JSONEncoder().encode(style)
        )

        #expect(decoded.size == ChapterTitleStyle.sizeRange.upperBound)
    }

    @Test("unexpected package kind is rejected before importing assets")
    func rejectsUnexpectedKindBeforeMutation() async throws {
        let sourceRoot = try readerStyleTemporaryDirectory()
        let destinationRoot = try readerStyleTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let sourceStore = ReaderStyleAssetStore(rootURL: sourceRoot)
        let image = try #require(UIImage(systemName: "book")?.pngData())
        let asset = try await sourceStore.importImage(data: image, suggestedName: "book.png")
        let payload = try ReaderStylePackagePayload.encode(
            ChapterTitleStyle.default,
            kind: .chapterTitle,
            assetIDs: [asset.id]
        )
        let archive = try await ReaderStylePackage.export(payload, assetStore: sourceStore)
        let destinationStore = ReaderStyleAssetStore(rootURL: destinationRoot)

        await #expect(throws: ReaderStylePackageError.unexpectedKind(
            expected: .appearance,
            actual: .chapterTitle
        )) {
            try await ReaderStylePackage.import(
                archive,
                assetStore: destinationStore,
                expectedKind: .appearance
            )
        }
        #expect(await destinationStore.assets().isEmpty)
    }

    @Test("package images still pass through the store dimension limit")
    func packageImagesAreNormalized() async throws {
        let destinationRoot = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 5_000, height: 10),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 5_000, height: 10))
        }
        let data = try #require(image.pngData())
        let id = readerStyleFixtureUUID(92)
        let path = "assets/\(id.uuidString.lowercased()).png"
        let manifest = ReaderStylePackageManifest(
            version: ReaderStylePackageManifest.currentVersion,
            payload: try ReaderStylePackagePayload.encode(
                ChapterTitleStyle.default,
                kind: .chapterTitle,
                assetIDs: [id]
            ),
            assets: [
                ReaderStylePackageAsset(
                    id: id,
                    relativePath: path,
                    sha256: SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    byteCount: data.count
                )
            ]
        )
        let archive = try await makeArchive(manifest: manifest, assets: [path: data])
        let store = ReaderStyleAssetStore(rootURL: destinationRoot)

        _ = try await ReaderStylePackage.import(archive, assetStore: store)
        let imported = try #require(await store.assets().first)

        #expect(max(imported.pixelWidth, imported.pixelHeight) <= ReaderStyleAssetStore.maximumStoredDimension)
    }

    private func makeArchive(
        manifest: ReaderStylePackageManifest,
        assets: [String: Data]
    ) async throws -> Data {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("fixture.yuedustyle")
        let manifestURL = root.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        let archive = try await Archive(url: archiveURL, accessMode: .create)
        try await archive.addEntry(with: "manifest.json", fileURL: manifestURL)
        for (path, data) in assets {
            let fileURL = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: fileURL)
            try await archive.addEntry(with: path, fileURL: fileURL)
        }
        return try Data(contentsOf: archiveURL)
    }
}
