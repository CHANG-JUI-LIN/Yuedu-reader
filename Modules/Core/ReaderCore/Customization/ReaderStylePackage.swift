import CryptoKit
import Foundation
import ReadiumZIPFoundation
import UniformTypeIdentifiers

struct ReaderStylePackageManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var payload: ReaderStylePackagePayload
    var assets: [ReaderStylePackageAsset]
    /// Files the payload names by `ReaderStylePackageFile.id` that are not reader-style
    /// images: font files and saved reading-background pictures, which belong to stores of
    /// their own (2026-11-14, 匯出閱讀設定 carrying everything). Nil in packages written
    /// before; a build that predates the key ignores it and the files under `files/`.
    var files: [ReaderStylePackageFile]? = nil
}

/// One `files/` entry of a package, as the manifest lists it.
struct ReaderStylePackageFile: Codable, Equatable, Sendable {
    var id: String
    var relativePath: String
    var sha256: String
    var byteCount: Int
}

/// A `files/` entry's bytes: what an export is handed and what an import gives back,
/// keyed by the id the payload refers to it by.
struct ReaderStylePackageAttachment: Equatable, Sendable {
    var id: String
    /// Lower-case extension without the dot, kept so a font importer can tell TTF from OTF.
    var fileExtension: String
    var data: Data
}

/// An imported package: the payload and every attachment it carried, by id.
struct ReaderStylePackageContents: Sendable {
    var payload: ReaderStylePackagePayload
    var attachments: [String: ReaderStylePackageAttachment]
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
    private static let fileDirectory = "files"

    static func export(
        _ payload: ReaderStylePackagePayload,
        assetStore: ReaderStyleAssetStore,
        attachments: [ReaderStylePackageAttachment] = []
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

        var packageFiles: [ReaderStylePackageFile] = []
        if !attachments.isEmpty {
            let fileRoot = temporaryRoot.appendingPathComponent(fileDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        }
        var seenAttachmentIDs: Set<String> = []
        for (index, attachment) in attachments.enumerated()
        where seenAttachmentIDs.insert(attachment.id).inserted {
            // Named by position, not by id: an id is the payload's to choose and may not be
            // a safe file name.
            let ext = attachment.fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            let relativePath = "\(fileDirectory)/\(index)" + (ext.isEmpty ? "" : ".\(ext)")
            let outputURL = try containedURL(for: relativePath, under: temporaryRoot)
            try attachment.data.write(to: outputURL, options: .atomic)
            packageFiles.append(ReaderStylePackageFile(
                id: attachment.id,
                relativePath: relativePath,
                sha256: sha256(attachment.data),
                byteCount: attachment.data.count
            ))
        }

        let manifest = ReaderStylePackageManifest(
            version: ReaderStylePackageManifest.currentVersion,
            payload: payload,
            assets: packageAssets,
            files: packageFiles.isEmpty ? nil : packageFiles
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
        for relativePath in packageAssets.map(\.relativePath) + packageFiles.map(\.relativePath) {
            let fileURL = try containedURL(for: relativePath, under: temporaryRoot)
            try await archive.addEntry(
                with: relativePath,
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
        try await importContents(
            archiveData,
            assetStore: assetStore,
            expectedKind: expectedKind
        ).payload
    }

    /// `import` plus the package's `files/` attachments, read into memory. Nothing is
    /// installed from them here: what they are for is the payload's to say, and its
    /// importer installs them only once the user has confirmed.
    static func importContents(
        _ archiveData: Data,
        assetStore: ReaderStyleAssetStore,
        expectedKind: ReaderStylePackageKind? = nil
    ) async throws -> ReaderStylePackageContents {
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
        var attachments: [String: ReaderStylePackageAttachment] = [:]
        for file in manifest.files ?? [] {
            let fileURL = try containedURL(for: file.relativePath, under: contentRoot)
            attachments[file.id] = ReaderStylePackageAttachment(
                id: file.id,
                fileExtension: (file.relativePath as NSString).pathExtension.lowercased(),
                data: try Data(contentsOf: fileURL)
            )
        }
        return ReaderStylePackageContents(payload: manifest.payload, attachments: attachments)
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
        let files = manifest.files ?? []
        let fileIDs = files.map(\.id)
        let assetPaths = manifest.assets.map(\.relativePath) + files.map(\.relativePath)
        guard Set(assetIDs).count == assetIDs.count,
              Set(fileIDs).count == fileIDs.count,
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

        for file in files {
            guard file.relativePath.hasPrefix("\(fileDirectory)/"),
                  file.byteCount >= 0,
                  fileEntryPaths.contains(file.relativePath) else {
                throw ReaderStylePackageError.malformedManifest
            }
            let fileURL = try containedURL(for: file.relativePath, under: extractionRoot)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ReaderStylePackageError.malformedManifest
            }
            guard data.count == file.byteCount else {
                throw ReaderStylePackageError.malformedManifest
            }
            guard sha256(data) == file.sha256.lowercased() else {
                throw ReaderStylePackageError.hashMismatch(file.relativePath)
            }
        }
    }

    /// Resolves `relativePath` under `root`, refusing anything that escapes it. Shared with
    /// `QiThemeImporter`, which unpacks a foreign archive and needs the same guarantee — one
    /// path-safety implementation, not a second copy that can drift out of step.
    static func containedURL(for relativePath: String, under root: URL) throws -> URL {
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
