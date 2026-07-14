import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader overlay SVG asset store")
struct ReaderOverlaySVGAssetStoreTests {
    @Test("Invalid SVG is rejected before an asset file or metadata entry is written")
    func validatesBeforeWriting() async throws {
        let fixture = try Fixture()
        let invalidURL = try fixture.writeImport(
            name: "unsafe.svg",
            source: #"<svg viewBox="0 0 100 40"><script>alert(1)</script></svg>"#
        )
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        await #expect(throws: ReaderBatterySVGError.forbiddenElement("script")) {
            try await store.importSVG(from: invalidURL)
        }

        #expect(try await store.assets().isEmpty)
        let storedSVGs = try FileManager.default.contentsOfDirectory(
            at: fixture.storeURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "svg" }
        #expect(storedSVGs.isEmpty)
    }

    @Test("Versioned metadata and display names survive a store reload")
    func metadataSurvivesReload() async throws {
        let fixture = try Fixture()
        let importURL = try fixture.writeImport(name: "My / Battery.svg", source: Self.safeSVG)
        let firstStore = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        let imported = try await firstStore.importSVG(from: importURL)
        let renamed = try await firstStore.rename(id: imported.id, displayName: "Night / Battery")
        let secondStore = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        #expect(try await secondStore.assets() == [renamed])
        #expect(renamed.displayName == "Night Battery")
        #expect(renamed.validationVersion == ReaderBatterySVGTemplate.validationVersion)

        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.storeURL.appendingPathComponent("assets.json"))
        ) as? [String: Any]
        #expect(metadata?["version"] as? Int == ReaderOverlaySVGAssetStore.metadataVersion)
    }

    @Test("Canonical validated content is deduplicated by SHA-256")
    func duplicateContentIsDeduplicated() async throws {
        let fixture = try Fixture()
        let firstURL = try fixture.writeImport(name: "First.svg", source: Self.safeSVG)
        let secondURL = try fixture.writeImport(name: "Second.svg", source: Self.safeSVG)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        async let first = store.importSVG(from: firstURL)
        async let second = store.importSVG(from: secondURL)
        let (firstAsset, secondAsset) = try await (first, second)

        #expect(firstAsset == secondAsset)
        #expect(try await store.assets().count == 1)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.storeURL,
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension.lowercased() == "svg" }.count == 1)

        let digest = SHA256.hash(data: Data(try await store.source(for: firstAsset.id).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(firstAsset.contentHash == digest)
        #expect(firstAsset.fileName == "\(digest).svg")
    }

    @Test("Atomic writes leave only the manifest and content-addressed SVG")
    func atomicWritesDoNotLeaveTemporaryFiles() async throws {
        let fixture = try Fixture()
        let importURL = try fixture.writeImport(name: "Battery.svg", source: Self.safeSVG)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        let asset = try await store.importSVG(from: importURL)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: fixture.storeURL.path))

        #expect(names == ["assets.json", asset.fileName])
    }

    @Test("Source and export preserve validated dynamic markers")
    func sourceAndExportPreserveMarkers() async throws {
        let fixture = try Fixture()
        let importURL = try fixture.writeImport(name: "Battery.svg", source: Self.safeSVG)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)
        let asset = try await store.importSVG(from: importURL)

        let source = try await store.source(for: asset.id)
        let exportURL = try await store.exportURL(for: asset.id, in: fixture.exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)

        #expect(source == exported)
        #expect(exported.contains(#"data-yuedu-role="battery-level""#))
        #expect(exported.contains(#"data-yuedu-role="battery-percent""#))
        #expect(exported.contains(#"data-yuedu-visible="charging""#))
        #expect(exportURL.pathExtension.lowercased() == "svg")
        #expect(exportURL.deletingLastPathComponent().standardizedFileURL == fixture.exportURL.standardizedFileURL)
    }

    @Test("Delete removes metadata and its unreferenced content file")
    func deleteRemovesAsset() async throws {
        let fixture = try Fixture()
        let importURL = try fixture.writeImport(name: "Battery.svg", source: Self.safeSVG)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)
        let asset = try await store.importSVG(from: importURL)

        try await store.delete(id: asset.id)

        #expect(try await store.assets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.storeURL.appendingPathComponent(asset.fileName).path))
        await #expect(throws: ReaderOverlaySVGAssetStoreError.assetNotFound) {
            try await store.source(for: asset.id)
        }
    }

    @Test("Missing and corrupt files resolve to the system battery fallback")
    func missingAndCorruptFilesFallBack() async throws {
        let fixture = try Fixture()
        let firstURL = try fixture.writeImport(name: "First.svg", source: Self.safeSVG)
        let secondURL = try fixture.writeImport(name: "Second.svg", source: Self.alternateSafeSVG)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)
        let missing = try await store.importSVG(from: firstURL)
        let corrupt = try await store.importSVG(from: secondURL)

        try FileManager.default.removeItem(at: fixture.storeURL.appendingPathComponent(missing.fileName))
        try #"<svg><script/></svg>"#.write(
            to: fixture.storeURL.appendingPathComponent(corrupt.fileName),
            atomically: true,
            encoding: .utf8
        )

        #expect(try await store.resolveTemplate(for: missing.id) == .systemBattery)
        #expect(try await store.resolveTemplate(for: corrupt.id) == .systemBattery)
        #expect(try await store.resolveTemplate(for: UUID()) == .systemBattery)
    }

    @Test("Different store actors coordinate concurrent import rename and delete transactions")
    func differentStoresDoNotLoseUpdates() async throws {
        let fixture = try Fixture()
        let firstURL = try fixture.writeImport(name: "First.svg", source: Self.safeSVG)
        let secondURL = try fixture.writeImport(name: "Second.svg", source: Self.alternateSafeSVG)
        let firstStore = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)
        let secondStore = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        async let firstImport = firstStore.importSVG(from: firstURL)
        async let secondImport = secondStore.importSVG(from: secondURL)
        let (first, second) = try await (firstImport, secondImport)
        #expect(try await firstStore.assets().count == 2)
        #expect(try await secondStore.assets().count == 2)

        async let renamed = firstStore.rename(id: first.id, displayName: "Renamed")
        async let deleted: Void = secondStore.delete(id: second.id)
        let renamedAsset = try await renamed
        try await deleted

        let finalAssets = try await ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL).assets()
        #expect(finalAssets == [renamedAsset])
    }

    @Test("Oversized imports write nothing and oversized stored sources fall back")
    func boundedReadsRejectOversizedSources() async throws {
        let fixture = try Fixture()
        let oversized = Data(repeating: 0x20, count: ReaderBatterySVGTemplate.maximumSourceSize + 1)
        let oversizedURL = fixture.importURL.appendingPathComponent("Oversized.svg")
        try oversized.write(to: oversizedURL)
        let store = ReaderOverlaySVGAssetStore(rootDirectory: fixture.storeURL)

        await #expect(throws: ReaderBatterySVGError.sourceTooLarge) {
            try await store.importSVG(from: oversizedURL)
        }
        #expect(try await store.assets().isEmpty)
        let filesAfterReject = try FileManager.default.contentsOfDirectory(
            at: fixture.storeURL,
            includingPropertiesForKeys: nil
        )
        #expect(filesAfterReject.filter { $0.pathExtension == "svg" }.isEmpty)

        let validURL = try fixture.writeImport(name: "Valid.svg", source: Self.safeSVG)
        let asset = try await store.importSVG(from: validURL)
        try oversized.write(to: fixture.storeURL.appendingPathComponent(asset.fileName), options: .atomic)
        #expect(try await store.resolveTemplate(for: asset.id) == .systemBattery)
    }

    @Test("An orphan cleanup failure does not undo or report a logical delete failure")
    func deleteIgnoresOrphanCleanupFailure() async throws {
        let fixture = try Fixture()
        let importURL = try fixture.writeImport(name: "Battery.svg", source: Self.safeSVG)
        let store = ReaderOverlaySVGAssetStore(
            rootDirectory: fixture.storeURL,
            orphanRemover: { _ in throw CleanupFailure.expected }
        )
        let asset = try await store.importSVG(from: importURL)

        try await store.delete(id: asset.id)

        #expect(try await store.assets().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.storeURL.appendingPathComponent(asset.fileName).path))
    }

    private static let safeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="100" height="40">
      <rect data-yuedu-role="battery-level" fill="currentColor" width="100" height="40"/>
      <text data-yuedu-role="battery-percent">0%</text>
      <path data-yuedu-visible="charging" d="M40 5L30 22H45L38 35L70 15H52Z"/>
    </svg>
    """

    private static let alternateSafeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 32">
      <rect data-yuedu-role="battery-level" width="80" height="32"/>
    </svg>
    """
}

@Suite("Reader battery SVG raster requests")
struct ReaderBatterySVGRasterRequestTests {
    @Test("Rejects huge pixel buffers and extreme display scales before rasterization")
    func rejectsUnsafeRasterRequests() {
        #expect(throws: ReaderBatterySVGRasterizerError.invalidRenderSize) {
            try ReaderBatterySVGRasterRequestValidator.validate(
                pixelSize: CGSize(width: 4_096, height: 4_096),
                displayScale: 2
            )
        }
        #expect(throws: ReaderBatterySVGRasterizerError.invalidRenderSize) {
            try ReaderBatterySVGRasterRequestValidator.validate(
                pixelSize: CGSize(width: 200, height: 100),
                displayScale: 0.000_1
            )
        }
        #expect(throws: ReaderBatterySVGRasterizerError.invalidRenderSize) {
            try ReaderBatterySVGRasterRequestValidator.validate(
                pixelSize: CGSize(width: 200, height: 100),
                displayScale: 100
            )
        }
        #expect(throws: ReaderBatterySVGRasterizerError.invalidRenderSize) {
            try ReaderBatterySVGRasterRequestValidator.validate(
                pixelSize: CGSize(width: 4_096, height: 1),
                displayScale: 0.5
            )
        }
    }

    @Test("Valid requests retain exact display-scale cache identity")
    func retainsExactDisplayScaleIdentity() throws {
        let first = try ReaderBatterySVGRasterRequestValidator.validate(
            pixelSize: CGSize(width: 216, height: 96),
            displayScale: 2.000_01
        )
        let second = try ReaderBatterySVGRasterRequestValidator.validate(
            pixelSize: CGSize(width: 216, height: 96),
            displayScale: 2.000_02
        )

        #expect(first.pointSize.width > 0)
        #expect(first.pointSize.height > 0)
        #expect(first.displayScaleCacheKey != second.displayScaleCacheKey)
    }
}

private enum CleanupFailure: Error {
    case expected
}

private struct Fixture {
    let rootURL: URL
    let storeURL: URL
    let importURL: URL
    let exportURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOverlaySVGAssetStoreTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = rootURL.appendingPathComponent("Store", isDirectory: true)
        importURL = rootURL.appendingPathComponent("Imports", isDirectory: true)
        exportURL = rootURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importURL, withIntermediateDirectories: true)
    }

    func writeImport(name: String, source: String) throws -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = importURL.appendingPathComponent(safeName)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
