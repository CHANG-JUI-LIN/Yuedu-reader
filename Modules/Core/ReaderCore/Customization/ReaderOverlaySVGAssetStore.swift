import CryptoKit
import Foundation

struct ReaderOverlaySVGAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var fileName: String
    var contentHash: String
    var validationVersion: Int
    var createdAt: Date
}

enum ReaderOverlaySVGAssetResolution: Equatable, Sendable {
    case template(ReaderBatterySVGTemplate)
    case systemBattery
}

enum ReaderOverlaySVGAssetStoreError: Error, Equatable, Sendable {
    case assetNotFound
    case invalidDisplayName
    case invalidMetadata
    case unsupportedMetadataVersion(Int)
    case unsafeAssetPath
    case corruptAsset
}

actor ReaderOverlaySVGAssetStore {
    static let metadataVersion = 1

    typealias OrphanRemover = @Sendable (URL) throws -> Void

    private static let transactionCoordinator = ReaderOverlaySVGAssetTransactionCoordinator()

    private struct Manifest: Codable, Sendable {
        var version: Int
        var assets: [ReaderOverlaySVGAsset]
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let orphanRemover: OrphanRemover

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        orphanRemover: @escaping OrphanRemover = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.orphanRemover = orphanRemover
    }

    static func live() throws -> ReaderOverlaySVGAssetStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("ReaderOverlay", isDirectory: true)
            .appendingPathComponent("SVG", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return ReaderOverlaySVGAssetStore(rootDirectory: root)
    }

    func assets() throws -> [ReaderOverlaySVGAsset] {
        try Self.transactionCoordinator.withLock {
            try loadAssets().sorted(by: Self.assetSort)
        }
    }

    func importSVG(from url: URL) throws -> ReaderOverlaySVGAsset {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try boundedData(from: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw ReaderBatterySVGError.malformedXML
        }

        // Validation deliberately happens before directory creation or metadata loading, so an
        // unsafe import cannot mutate the store in any way.
        let template = try ReaderBatterySVGTemplate(source: source)
        let validatedSource = template.validatedSource
        guard validatedSource.utf8.count <= ReaderBatterySVGTemplate.maximumSourceSize else {
            throw ReaderBatterySVGError.sourceTooLarge
        }
        let contentHash = Self.sha256(validatedSource)

        return try Self.transactionCoordinator.withLock {
            var currentAssets = try loadAssets()

            if let duplicateIndex = currentAssets.firstIndex(where: { $0.contentHash == contentHash }) {
                var duplicate = currentAssets[duplicateIndex]
                // Repair a missing same-content file from the newly validated import without
                // creating a second logical asset. Reimport also upgrades equal canonical content
                // to the latest validation contract.
                if duplicate.validationVersion != ReaderBatterySVGTemplate.validationVersion
                    || (try? validatedSourceForAsset(duplicate)) == nil {
                    try ensureRootDirectory()
                    try writeValidatedSource(validatedSource, for: duplicate)
                }
                if duplicate.validationVersion != ReaderBatterySVGTemplate.validationVersion {
                    duplicate.validationVersion = ReaderBatterySVGTemplate.validationVersion
                    currentAssets[duplicateIndex] = duplicate
                    try persist(currentAssets)
                }
                return duplicate
            }

            try ensureRootDirectory()
            let asset = ReaderOverlaySVGAsset(
                id: UUID(),
                displayName: Self.sanitizedDisplayName(
                    url.deletingPathExtension().lastPathComponent,
                    fallbackHash: contentHash
                ),
                fileName: "\(contentHash).svg",
                contentHash: contentHash,
                validationVersion: ReaderBatterySVGTemplate.validationVersion,
                createdAt: Date()
            )
            let fileURL = try sourceFileURL(for: asset, mustExist: false)
            let createdContentFile = !fileManager.fileExists(atPath: fileURL.path)

            do {
                if createdContentFile {
                    try Data(validatedSource.utf8).write(to: fileURL, options: .atomic)
                }
                currentAssets.append(asset)
                try persist(currentAssets)
                return asset
            } catch {
                if createdContentFile {
                    try? fileManager.removeItem(at: fileURL)
                }
                throw error
            }
        }
    }

    func rename(id: UUID, displayName: String) throws -> ReaderOverlaySVGAsset {
        try Self.transactionCoordinator.withLock {
            var currentAssets = try loadAssets()
            guard let index = currentAssets.firstIndex(where: { $0.id == id }) else {
                throw ReaderOverlaySVGAssetStoreError.assetNotFound
            }
            let sanitized = Self.sanitizedDisplayName(displayName, fallbackHash: "")
            guard !sanitized.isEmpty else {
                throw ReaderOverlaySVGAssetStoreError.invalidDisplayName
            }
            currentAssets[index].displayName = sanitized
            try persist(currentAssets)
            return currentAssets[index]
        }
    }

    func source(for id: UUID) throws -> String {
        try Self.transactionCoordinator.withLock {
            let currentAssets = try loadAssets()
            guard let asset = currentAssets.first(where: { $0.id == id }) else {
                throw ReaderOverlaySVGAssetStoreError.assetNotFound
            }
            return try validatedSourceForAsset(asset)
        }
    }

    func resolveTemplate(for id: UUID?) throws -> ReaderOverlaySVGAssetResolution {
        guard let id else { return .systemBattery }
        do {
            return .template(try ReaderBatterySVGTemplate(source: source(for: id)))
        } catch {
            return .systemBattery
        }
    }

    func exportURL(for id: UUID, in directory: URL) throws -> URL {
        try Self.transactionCoordinator.withLock {
            let currentAssets = try loadAssets()
            guard let asset = currentAssets.first(where: { $0.id == id }) else {
                throw ReaderOverlaySVGAssetStoreError.assetNotFound
            }
            let source = try validatedSourceForAsset(asset)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let safeName = Self.sanitizedDisplayName(asset.displayName, fallbackHash: asset.contentHash)
            let suffix = asset.id.uuidString.prefix(8).lowercased()
            let destination = directory
                .appendingPathComponent("\(safeName)-\(suffix)")
                .appendingPathExtension("svg")
            try Data(source.utf8).write(to: destination, options: .atomic)
            return destination
        }
    }

    func delete(id: UUID) throws {
        try Self.transactionCoordinator.withLock {
            var currentAssets = try loadAssets()
            guard let index = currentAssets.firstIndex(where: { $0.id == id }) else {
                throw ReaderOverlaySVGAssetStoreError.assetNotFound
            }
            let removed = currentAssets.remove(at: index)

            // Metadata is the logical transaction. Orphan cleanup is deliberately best-effort so
            // a filesystem cleanup failure cannot make UI state contradict the committed delete.
            try persist(currentAssets)
            if !currentAssets.contains(where: { $0.contentHash == removed.contentHash }),
               let fileURL = try? sourceFileURL(for: removed, mustExist: false),
               fileManager.fileExists(atPath: fileURL.path) {
                try? orphanRemover(fileURL)
            }
        }
    }

    private var manifestURL: URL {
        rootDirectory.appendingPathComponent("assets.json", isDirectory: false)
    }

    private func loadAssets() throws -> [ReaderOverlaySVGAsset] {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return []
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw ReaderOverlaySVGAssetStoreError.invalidMetadata
        }
        guard manifest.version == Self.metadataVersion else {
            throw ReaderOverlaySVGAssetStoreError.unsupportedMetadataVersion(manifest.version)
        }
        guard Set(manifest.assets.map(\.id)).count == manifest.assets.count else {
            throw ReaderOverlaySVGAssetStoreError.invalidMetadata
        }
        for asset in manifest.assets {
            try validateMetadata(asset)
        }
        return manifest.assets
    }

    private func persist(_ assets: [ReaderOverlaySVGAsset]) throws {
        try ensureRootDirectory()
        let manifest = Manifest(version: Self.metadataVersion, assets: assets.sorted(by: Self.assetSort))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private func validatedSourceForAsset(_ asset: ReaderOverlaySVGAsset) throws -> String {
        let fileURL = try sourceFileURL(for: asset, mustExist: true)
        let data: Data
        do {
            data = try boundedData(from: fileURL)
        } catch ReaderBatterySVGError.sourceTooLarge {
            throw ReaderOverlaySVGAssetStoreError.corruptAsset
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ReaderOverlaySVGAssetStoreError.corruptAsset
        }
        let template: ReaderBatterySVGTemplate
        do {
            template = try ReaderBatterySVGTemplate(source: source)
        } catch {
            throw ReaderOverlaySVGAssetStoreError.corruptAsset
        }
        guard template.validatedSource == source,
              Self.sha256(source) == asset.contentHash,
              asset.validationVersion == ReaderBatterySVGTemplate.validationVersion else {
            throw ReaderOverlaySVGAssetStoreError.corruptAsset
        }
        return source
    }

    private func writeValidatedSource(_ source: String, for asset: ReaderOverlaySVGAsset) throws {
        guard Self.sha256(source) == asset.contentHash else {
            throw ReaderOverlaySVGAssetStoreError.corruptAsset
        }
        let fileURL = try sourceFileURL(for: asset, mustExist: false)
        try Data(source.utf8).write(to: fileURL, options: .atomic)
    }

    private func sourceFileURL(
        for asset: ReaderOverlaySVGAsset,
        mustExist: Bool
    ) throws -> URL {
        try validateMetadata(asset)
        let candidate = rootDirectory.appendingPathComponent(asset.fileName, isDirectory: false)
        guard candidate.standardizedFileURL.deletingLastPathComponent() == rootDirectory else {
            throw ReaderOverlaySVGAssetStoreError.unsafeAssetPath
        }
        if mustExist {
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw ReaderOverlaySVGAssetStoreError.assetNotFound
            }
            let resolvedRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedCandidate.deletingLastPathComponent() == resolvedRoot else {
                throw ReaderOverlaySVGAssetStoreError.unsafeAssetPath
            }
        }
        return candidate
    }

    private func validateMetadata(_ asset: ReaderOverlaySVGAsset) throws {
        let hash = asset.contentHash
        guard hash.count == 64,
              hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              asset.fileName == "\(hash).svg",
              asset.validationVersion > 0,
              !asset.displayName.isEmpty else {
            throw ReaderOverlaySVGAssetStoreError.invalidMetadata
        }
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func boundedData(from url: URL) throws -> Data {
        let maximumSize = ReaderBatterySVGTemplate.maximumSourceSize
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maximumSize {
            throw ReaderBatterySVGError.sourceTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximumSize {
            let remaining = maximumSize + 1 - result.count
            guard remaining > 0,
                  let chunk = try handle.read(upToCount: min(remaining, 64 * 1_024)),
                  !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        guard result.count <= maximumSize else {
            throw ReaderBatterySVGError.sourceTooLarge
        }
        return result
    }

    private static func sha256(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sanitizedDisplayName(_ rawValue: String, fallbackHash: String) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let scalars = rawValue.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = scalars
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limited = String(collapsed.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !limited.isEmpty { return limited }
        guard !fallbackHash.isEmpty else { return "" }
        return "SVG-\(fallbackHash.prefix(8))"
    }

    private static func assetSort(_ lhs: ReaderOverlaySVGAsset, _ rhs: ReaderOverlaySVGAsset) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private final class ReaderOverlaySVGAssetTransactionCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
