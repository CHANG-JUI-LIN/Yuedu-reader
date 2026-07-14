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

    private struct Manifest: Codable, Sendable {
        var version: Int
        var assets: [ReaderOverlaySVGAsset]
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private var cachedAssets: [ReaderOverlaySVGAsset]?

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
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
        try loadAssets().sorted(by: Self.assetSort)
    }

    func importSVG(from url: URL) throws -> ReaderOverlaySVGAsset {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = String(data: data, encoding: .utf8) else {
            throw ReaderBatterySVGError.malformedXML
        }

        // Validation deliberately happens before directory creation or metadata loading, so an
        // unsafe import cannot mutate the store in any way.
        let template = try ReaderBatterySVGTemplate(source: source)
        let validatedSource = template.validatedSource
        let contentHash = Self.sha256(validatedSource)
        var currentAssets = try loadAssets()

        if let duplicateIndex = currentAssets.firstIndex(where: { $0.contentHash == contentHash }) {
            var duplicate = currentAssets[duplicateIndex]
            // Repair a missing same-content file from the newly validated import without creating
            // a second logical asset. Reimport also upgrades equal canonical content to the latest
            // validation contract, so a future validation-version bump cannot return an asset that
            // immediately resolves as corrupt.
            if duplicate.validationVersion != ReaderBatterySVGTemplate.validationVersion
                || (try? validatedSourceForAsset(duplicate)) == nil {
                try ensureRootDirectory()
                try writeValidatedSource(validatedSource, for: duplicate)
            }
            if duplicate.validationVersion != ReaderBatterySVGTemplate.validationVersion {
                duplicate.validationVersion = ReaderBatterySVGTemplate.validationVersion
                currentAssets[duplicateIndex] = duplicate
                try persist(currentAssets)
                cachedAssets = currentAssets
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
            cachedAssets = currentAssets
            return asset
        } catch {
            if createdContentFile {
                try? fileManager.removeItem(at: fileURL)
            }
            throw error
        }
    }

    func rename(id: UUID, displayName: String) throws -> ReaderOverlaySVGAsset {
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
        cachedAssets = currentAssets
        return currentAssets[index]
    }

    func source(for id: UUID) throws -> String {
        let currentAssets = try loadAssets()
        guard let asset = currentAssets.first(where: { $0.id == id }) else {
            throw ReaderOverlaySVGAssetStoreError.assetNotFound
        }
        return try validatedSourceForAsset(asset)
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

    func delete(id: UUID) throws {
        var currentAssets = try loadAssets()
        guard let index = currentAssets.firstIndex(where: { $0.id == id }) else {
            throw ReaderOverlaySVGAssetStoreError.assetNotFound
        }
        let removed = currentAssets.remove(at: index)

        // Commit metadata first. If removing the content file fails afterward, the result is only
        // an unreachable orphan rather than a manifest entry that resolves to a missing file.
        try persist(currentAssets)
        cachedAssets = currentAssets
        if !currentAssets.contains(where: { $0.contentHash == removed.contentHash }) {
            let fileURL = try sourceFileURL(for: removed, mustExist: false)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    private var manifestURL: URL {
        rootDirectory.appendingPathComponent("assets.json", isDirectory: false)
    }

    private func loadAssets() throws -> [ReaderOverlaySVGAsset] {
        if let cachedAssets { return cachedAssets }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            cachedAssets = []
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
        cachedAssets = manifest.assets
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
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
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
