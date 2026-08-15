import CryptoKit
import Foundation
import ReadiumZIPFoundation
import UniformTypeIdentifiers

struct ReaderStylePackageManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var payload: ReaderStylePackagePayload
    var assets: [ReaderStylePackageAsset]
}

struct ReaderStylePackageAsset: Codable, Equatable, Sendable {
    var id: UUID
    var relativePath: String
    var sha256: String
    var byteCount: Int
}

enum ReaderStylePackageKind: String, Codable, Sendable {
    case chapterTitle
    case regexHighlights
    case appearance
    /// 整套閱讀設定 — layout parameters plus both style halves. See
    /// `ReaderSettingsBundle`.
    case readerSettings
}

struct ReaderStylePackagePayload: Codable, Equatable, Sendable {
    var kind: ReaderStylePackageKind
    var encodedModel: Data
    var assetIDs: [UUID]

    static func encode<Value: Encodable & Sendable>(
        _ value: Value,
        kind: ReaderStylePackageKind,
        assetIDs: [UUID]
    ) throws -> ReaderStylePackagePayload {
        ReaderStylePackagePayload(
            kind: kind,
            encodedModel: try JSONEncoder().encode(value),
            assetIDs: assetIDs
        )
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: encodedModel)
    }
}

enum ReaderStylePackageError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case unsafePath(String)
    case tooManyFiles(Int)
    case expandedDataTooLarge(Int)
    case hashMismatch(String)
    case missingAsset(UUID)
    case malformedManifest
    case unexpectedKind(expected: ReaderStylePackageKind, actual: ReaderStylePackageKind)
}

enum ReaderStylePackage {
    static let maximumFileCount = 128
    static let maximumExpandedBytes = 100 * 1_024 * 1_024

    private static let manifestPath = "manifest.json"
    private static let assetDirectory = "assets"

    static func export(
        _ payload: ReaderStylePackagePayload,
        assetStore: ReaderStyleAssetStore
    ) async throws -> Data {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-style-export-\(UUID().uuidString)", isDirectory: true)
        defer { removeTemporaryDirectory(temporaryRoot) }

        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let assetRoot = temporaryRoot.appendingPathComponent(assetDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)

        let availableAssets = await assetStore.assets()
        let assetsByID = Dictionary(uniqueKeysWithValues: availableAssets.map { ($0.id, $0) })
        var seenAssetIDs: Set<UUID> = []
        var packageAssets: [ReaderStylePackageAsset] = []

        for id in payload.assetIDs where seenAssetIDs.insert(id).inserted {
            guard let asset = assetsByID[id] else {
                throw ReaderStylePackageError.missingAsset(id)
            }
            let data = try await assetStore.imageData(for: id)
            let relativePath = "\(assetDirectory)/\(id.uuidString.lowercased()).\(assetExtension(asset))"
            let hash = sha256(data)
            guard hash == asset.sha256.lowercased() else {
                throw ReaderStylePackageError.hashMismatch(relativePath)
            }
            let outputURL = try containedURL(for: relativePath, under: temporaryRoot)
            try data.write(to: outputURL, options: .atomic)
            packageAssets.append(
                ReaderStylePackageAsset(
                    id: id,
                    relativePath: relativePath,
                    sha256: hash,
                    byteCount: data.count
                )
            )
        }

        let manifest = ReaderStylePackageManifest(
            version: ReaderStylePackageManifest.currentVersion,
            payload: payload,
            assets: packageAssets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = temporaryRoot.appendingPathComponent(manifestPath, isDirectory: false)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let archiveURL = temporaryRoot.appendingPathComponent("style.yuedustyle", isDirectory: false)
        let archive = try await Archive(url: archiveURL, accessMode: .create)
        try await archive.addEntry(
            with: manifestPath,
            fileURL: manifestURL,
            compressionMethod: .deflate
        )
        for asset in packageAssets {
            let fileURL = try containedURL(for: asset.relativePath, under: temporaryRoot)
            try await archive.addEntry(
                with: asset.relativePath,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
        return try Data(contentsOf: archiveURL)
    }

    static func `import`(
        _ archiveData: Data,
        assetStore: ReaderStyleAssetStore,
        expectedKind: ReaderStylePackageKind? = nil
    ) async throws -> ReaderStylePackagePayload {
        guard archiveData.count <= maximumExpandedBytes else {
            throw ReaderStylePackageError.expandedDataTooLarge(archiveData.count)
        }

        let extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-style-import-\(UUID().uuidString)", isDirectory: true)
        defer { removeTemporaryDirectory(extractionRoot) }

        try FileManager.default.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: true
        )
        let archiveURL = extractionRoot.appendingPathComponent("source.yuedustyle", isDirectory: false)
        try archiveData.write(to: archiveURL, options: .atomic)

        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ReaderStylePackageError.malformedManifest
        }

        let entries: [Entry]
        do {
            entries = try await archive.entries()
        } catch {
            throw ReaderStylePackageError.malformedManifest
        }
        guard entries.count <= maximumFileCount else {
            throw ReaderStylePackageError.tooManyFiles(entries.count)
        }
        try validateEntryPaths(entries.map(\.path))
        guard Set(entries.map(\.path)).count == entries.count else {
            throw ReaderStylePackageError.malformedManifest
        }

        var expandedBytes: UInt64 = 0
        for entry in entries {
            guard entry.type != .symlink else {
                throw ReaderStylePackageError.unsafePath(entry.path)
            }
            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            expandedBytes = sum
            guard !overflow, expandedBytes <= UInt64(maximumExpandedBytes) else {
                throw ReaderStylePackageError.expandedDataTooLarge(
                    expandedBytes > UInt64(Int.max) ? Int.max : Int(expandedBytes)
                )
            }
        }

        let contentRoot = extractionRoot.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        for entry in entries {
            let destination = try containedURL(for: entry.path, under: contentRoot)
            do {
                _ = try await archive.extract(entry, to: destination)
            } catch {
                throw ReaderStylePackageError.malformedManifest
            }
        }

        let manifestURL = contentRoot.appendingPathComponent(manifestPath, isDirectory: false)
        let manifest: ReaderStylePackageManifest
        do {
            manifest = try JSONDecoder().decode(
                ReaderStylePackageManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ReaderStylePackageError.malformedManifest
        }
        guard manifest.version == ReaderStylePackageManifest.currentVersion else {
            throw ReaderStylePackageError.unsupportedVersion(manifest.version)
        }
        try validateManifest(manifest, entries: entries, extractionRoot: contentRoot)
        if let expectedKind, manifest.payload.kind != expectedKind {
            throw ReaderStylePackageError.unexpectedKind(
                expected: expectedKind,
                actual: manifest.payload.kind
            )
        }

        try await assetStore.importValidatedPackageAssets(
            manifest.assets,
            from: contentRoot
        )
        return manifest.payload
    }

    static func validateEntryPaths(_ paths: [String]) throws {
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let hasWindowsDrivePrefix = path.count >= 2
                && path[path.index(after: path.startIndex)] == ":"
            guard !path.isEmpty,
                  !path.contains("\\"),
                  !path.contains("\0"),
                  !path.hasPrefix("/"),
                  !hasWindowsDrivePrefix,
                  !(path as NSString).isAbsolutePath,
                  !components.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ReaderStylePackageError.unsafePath(path)
            }
        }
    }

    static func decodeLegacyChapterTitleJSON(_ data: Data) throws -> ChapterTitleStyle {
        try JSONDecoder().decode(ChapterTitleStyle.self, from: data).sanitized()
    }

    private static func validateManifest(
        _ manifest: ReaderStylePackageManifest,
        entries: [Entry],
        extractionRoot: URL
    ) throws {
        let assetIDs = manifest.assets.map(\.id)
        let assetPaths = manifest.assets.map(\.relativePath)
        guard Set(assetIDs).count == assetIDs.count,
              Set(assetPaths).count == assetPaths.count else {
            throw ReaderStylePackageError.malformedManifest
        }
        try validateEntryPaths(assetPaths)

        let fileEntryPaths = Set(entries.lazy.filter { $0.type == .file }.map(\.path))
        let manifestAssetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        for id in Set(manifest.payload.assetIDs) where manifestAssetsByID[id] == nil {
            throw ReaderStylePackageError.missingAsset(id)
        }

        for asset in manifest.assets {
            guard asset.relativePath.hasPrefix("\(assetDirectory)/"),
                  asset.byteCount >= 0,
                  fileEntryPaths.contains(asset.relativePath) else {
                throw ReaderStylePackageError.missingAsset(asset.id)
            }
            let fileURL = try containedURL(for: asset.relativePath, under: extractionRoot)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ReaderStylePackageError.missingAsset(asset.id)
            }
            guard data.count == asset.byteCount else {
                throw ReaderStylePackageError.malformedManifest
            }
            guard sha256(data) == asset.sha256.lowercased() else {
                throw ReaderStylePackageError.hashMismatch(asset.relativePath)
            }
        }
    }

    private static func containedURL(for relativePath: String, under root: URL) throws -> URL {
        try validateEntryPaths([relativePath])
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot
            .appendingPathComponent(relativePath, isDirectory: relativePath.hasSuffix("/"))
            .standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ReaderStylePackageError.unsafePath(relativePath)
        }
        return candidate
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func assetExtension(_ asset: ReaderStyleAsset) -> String {
        switch asset.mimeType.lowercased() {
        case "image/png": "png"
        default: "jpg"
        }
    }

    private static func removeTemporaryDirectory(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Temporary package data is never authoritative. A cleanup failure can only leave an
        // unreachable cache directory and must not change an otherwise successful transaction.
        try? FileManager.default.removeItem(at: url)
    }
}

extension UTType {
    static let yueduReaderStyle = UTType(
        exportedAs: "app.yuedu.reader-style",
        conformingTo: .data
    )
}
