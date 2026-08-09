import CryptoKit
import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    static let readerStyleAssetsDidChange = Notification.Name(
        "YDReaderStyleAssetsDidChange"
    )
}

actor ReaderStyleAssetStore {
    static let revisionUserInfoKey = "revision"
    static let shared = ReaderStyleAssetStore(rootURL: defaultRootURL())
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumDecodedPixels = 80_000_000
    static let maximumStoredDimension = 4_096
    static let thumbnailDimension = 256

    private static let manifestVersion = 1

    private struct Manifest: Codable {
        var version: Int
        var revision: UInt64
        var assets: [ReaderStyleAsset]
    }

    private struct PreparedImage {
        let image: UIImage
        let data: Data
        let thumbnailData: Data
        let fileExtension: String
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let hasAlpha: Bool
        let sha256: String
    }

    private let rootURL: URL
    private let manifestURL: URL
    private let imageCache: ReaderStyleAssetImageCache
    private var storedAssets: [ReaderStyleAsset]
    private var referencesByAssetID: [UUID: [ReaderStyleAssetReference]] = [:]
    private var referencesByScope: [String: [UUID: [ReaderStyleAssetReference]]] = [:]
    private var initializationError: ReaderStyleAssetStoreError?
    private(set) var revision: UInt64

    init(rootURL: URL) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.manifestURL = standardizedRoot.appendingPathComponent(
            "manifest.json",
            isDirectory: false
        )
        self.imageCache = .shared

        do {
            let manifest = try Self.loadManifest(
                at: standardizedRoot.appendingPathComponent("manifest.json", isDirectory: false)
            )
            self.storedAssets = manifest.assets
            self.revision = manifest.revision
            self.initializationError = nil
        } catch {
            self.storedAssets = []
            self.revision = 0
            self.initializationError = .writeFailed
        }
    }

    func importImage(data: Data, suggestedName: String) async throws -> ReaderStyleAsset {
        try ensureStoreIsReadable()
        let prepared = try Self.prepareImage(data: data)

        if let existing = storedAssets.first(where: { $0.sha256 == prepared.sha256 }) {
            let imageURL = rootURL.appendingPathComponent(existing.fileName, isDirectory: false)
            let thumbnailURL = rootURL.appendingPathComponent(
                existing.thumbnailFileName,
                isDirectory: false
            )
            if !FileManager.default.fileExists(atPath: imageURL.path)
                || !FileManager.default.fileExists(atPath: thumbnailURL.path) {
                try write(prepared.data, to: imageURL)
                try write(prepared.thumbnailData, to: thumbnailURL)
            }
            revision &+= 1
            do {
                try persistManifest()
            } catch {
                revision &-= 1
                throw error
            }
            imageCache.insert(prepared.image, for: existing.id)
            postRevisionChange()
            return existing
        }

        let id = UUID()
        let fileName = Self.fileName(
            id: id,
            sha256: prepared.sha256,
            suffix: nil,
            fileExtension: prepared.fileExtension
        )
        let thumbnailFileName = Self.fileName(
            id: id,
            sha256: prepared.sha256,
            suffix: "thumb",
            fileExtension: prepared.fileExtension
        )
        let asset = ReaderStyleAsset(
            id: id,
            name: Self.normalizedName(suggestedName, sha256: prepared.sha256),
            mimeType: prepared.mimeType,
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight,
            hasAlpha: prepared.hasAlpha,
            sha256: prepared.sha256,
            fileName: fileName,
            thumbnailFileName: thumbnailFileName
        )

        let imageURL = rootURL.appendingPathComponent(fileName, isDirectory: false)
        let thumbnailURL = rootURL.appendingPathComponent(thumbnailFileName, isDirectory: false)
        do {
            try write(prepared.data, to: imageURL)
            try write(prepared.thumbnailData, to: thumbnailURL)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw Self.storeError(from: error)
        }

        storedAssets.append(asset)
        revision &+= 1
        do {
            try persistManifest()
        } catch {
            storedAssets.removeAll { $0.id == id }
            revision &-= 1
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw Self.storeError(from: error)
        }

        imageCache.insert(prepared.image, for: id)
        postRevisionChange()
        return asset
    }

    func replaceImage(
        id: UUID,
        data: Data,
        suggestedName: String
    ) async throws -> ReaderStyleAsset {
        try ensureStoreIsReadable()
        guard let index = storedAssets.firstIndex(where: { $0.id == id }) else {
            throw ReaderStyleAssetStoreError.assetNotFound(id)
        }
        let prepared = try Self.prepareImage(data: data)
        let previous = storedAssets[index]
        let replacement = ReaderStyleAsset(
            id: id,
            name: Self.normalizedName(suggestedName, sha256: prepared.sha256),
            mimeType: prepared.mimeType,
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight,
            hasAlpha: prepared.hasAlpha,
            sha256: prepared.sha256,
            fileName: Self.fileName(
                id: id,
                sha256: prepared.sha256,
                suffix: nil,
                fileExtension: prepared.fileExtension
            ),
            thumbnailFileName: Self.fileName(
                id: id,
                sha256: prepared.sha256,
                suffix: "thumb",
                fileExtension: prepared.fileExtension
            )
        )

        let imageURL = rootURL.appendingPathComponent(replacement.fileName, isDirectory: false)
        let thumbnailURL = rootURL.appendingPathComponent(
            replacement.thumbnailFileName,
            isDirectory: false
        )
        do {
            try write(prepared.data, to: imageURL)
            try write(prepared.thumbnailData, to: thumbnailURL)
        } catch {
            if replacement.fileName != previous.fileName {
                try? FileManager.default.removeItem(at: imageURL)
            }
            if replacement.thumbnailFileName != previous.thumbnailFileName {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
            throw Self.storeError(from: error)
        }

        storedAssets[index] = replacement
        revision &+= 1
        do {
            try persistManifest()
        } catch {
            storedAssets[index] = previous
            revision &-= 1
            if replacement.fileName != previous.fileName {
                try? FileManager.default.removeItem(at: imageURL)
            }
            if replacement.thumbnailFileName != previous.thumbnailFileName {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
            throw Self.storeError(from: error)
        }

        imageCache.insert(prepared.image, for: id)
        removeOrphanedFile(named: previous.fileName, keeping: replacement.fileName)
        removeOrphanedFile(
            named: previous.thumbnailFileName,
            keeping: replacement.thumbnailFileName
        )
        postRevisionChange()
        return replacement
    }

    func assets() -> [ReaderStyleAsset] {
        storedAssets
    }

    func imageData(for id: UUID) throws -> Data {
        try ensureStoreIsReadable()
        guard let asset = storedAssets.first(where: { $0.id == id }) else {
            throw ReaderStyleAssetStoreError.assetNotFound(id)
        }
        do {
            return try Data(
                contentsOf: rootURL.appendingPathComponent(asset.fileName, isDirectory: false)
            )
        } catch {
            throw ReaderStyleAssetStoreError.writeFailed
        }
    }

    func cachedImage(for id: UUID) -> UIImage? {
        imageCache.image(for: id)
    }

    /// Returns a synchronous-draw-ready image, hydrating the process cache from
    /// the persisted store when an app launch has not warmed it yet.
    func loadCachedImage(for id: UUID) throws -> UIImage {
        if let cached = imageCache.image(for: id) {
            return cached
        }
        let data = try imageData(for: id)
        guard let image = UIImage(data: data) else {
            throw ReaderStyleAssetStoreError.invalidImage
        }
        imageCache.insert(image, for: id)
        return image
    }

    /// Warms only enabled rules for the requested appearance. Drawing remains
    /// synchronous and never performs file I/O; individual asset failures are
    /// diagnosed without suppressing the rule's color/border/shadow layers.
    func prewarmRegexHighlightAssets(
        configuration: RegexHighlightConfiguration,
        appearance: ReaderStyleAppearance
    ) {
        guard configuration.isEnabled else { return }
        let assetIDs = Set(configuration.evaluationRules.compactMap { rule -> UUID? in
            guard rule.isEnabled else { return nil }
            let style = appearance == .light ? rule.lightStyle : rule.darkStyle
            return style.decoration.backgroundImage?.assetID
        })
        for assetID in assetIDs where imageCache.image(for: assetID) == nil {
            do {
                _ = try loadCachedImage(for: assetID)
            } catch {
                AppLogger.render(
                    "regex highlight background image prewarm failed",
                    context: [
                        "assetID": assetID.uuidString,
                        "appearance": appearance.rawValue,
                        "error": String(describing: error),
                    ]
                )
            }
        }
    }

    func references(for id: UUID) -> [ReaderStyleAssetReference] {
        referencesByAssetID[id] ?? []
    }

    func replaceReferences(
        _ values: [UUID: [ReaderStyleAssetReference]],
        scope: String = "legacy"
    ) {
        referencesByScope[scope] = values.filter { !$0.value.isEmpty }
        var combined: [UUID: [ReaderStyleAssetReference]] = [:]
        for scopedValues in referencesByScope.values {
            for (assetID, references) in scopedValues {
                for reference in references where !combined[assetID, default: []].contains(reference) {
                    combined[assetID, default: []].append(reference)
                }
            }
        }
        referencesByAssetID = combined
    }

    func rename(_ id: UUID, to name: String) throws {
        try ensureStoreIsReadable()
        guard let index = storedAssets.firstIndex(where: { $0.id == id }) else {
            throw ReaderStyleAssetStoreError.assetNotFound(id)
        }

        let previousName = storedAssets[index].name
        storedAssets[index].name = Self.normalizedName(name, sha256: storedAssets[index].sha256)
        revision &+= 1
        do {
            try persistManifest()
        } catch {
            storedAssets[index].name = previousName
            revision &-= 1
            throw Self.storeError(from: error)
        }
        postRevisionChange()
    }

    func delete(_ id: UUID, removingReferences: Bool) throws {
        try ensureStoreIsReadable()
        guard let index = storedAssets.firstIndex(where: { $0.id == id }) else {
            throw ReaderStyleAssetStoreError.assetNotFound(id)
        }
        let references = referencesByAssetID[id] ?? []
        if !removingReferences, !references.isEmpty {
            throw ReaderStyleAssetStoreError.assetInUse(
                assetID: id,
                references: references
            )
        }

        let removed = storedAssets.remove(at: index)
        revision &+= 1
        do {
            try persistManifest()
        } catch {
            storedAssets.insert(removed, at: index)
            revision &-= 1
            throw Self.storeError(from: error)
        }

        referencesByAssetID.removeValue(forKey: id)
        imageCache.remove(id)
        removeOrphanedFile(named: removed.fileName, keeping: nil)
        removeOrphanedFile(named: removed.thumbnailFileName, keeping: nil)
        postRevisionChange()
    }

    /// Commits already package-validated assets as one manifest transaction.
    ///
    /// Package import deliberately preserves IDs because the decoded style payload refers to
    /// those IDs. Files are written under content-addressed names first; the persisted manifest
    /// becomes authoritative only after every asset is ready. A failure before that point removes
    /// newly-created files and restores the in-memory snapshot.
    func importValidatedPackageAssets(
        _ assets: [ReaderStylePackageAsset],
        from extractionRoot: URL
    ) async throws {
        try ensureStoreIsReadable()
        guard Set(assets.map(\.id)).count == assets.count else {
            throw ReaderStylePackageError.malformedManifest
        }

        struct PackageImport {
            let prepared: PreparedImage
            let asset: ReaderStyleAsset
        }

        var imports: [PackageImport] = []
        imports.reserveCapacity(assets.count)
        for descriptor in assets {
            let sourceURL = extractionRoot
                .appendingPathComponent(descriptor.relativePath, isDirectory: false)
                .standardizedFileURL
            let rootPath = extractionRoot.standardizedFileURL.path + "/"
            guard sourceURL.path.hasPrefix(rootPath) else {
                throw ReaderStylePackageError.unsafePath(descriptor.relativePath)
            }
            let data: Data
            do {
                data = try Data(contentsOf: sourceURL)
            } catch {
                throw ReaderStylePackageError.missingAsset(descriptor.id)
            }
            guard data.count == descriptor.byteCount else {
                throw ReaderStylePackageError.malformedManifest
            }
            let prepared = try Self.prepareValidatedPackageImage(
                data: data,
                expectedSHA256: descriptor.sha256,
                relativePath: descriptor.relativePath
            )
            let previous = storedAssets.first(where: { $0.id == descriptor.id })
            let name = previous?.name ?? Self.normalizedName(
                (descriptor.relativePath as NSString).lastPathComponent,
                sha256: prepared.sha256
            )
            imports.append(
                PackageImport(
                    prepared: prepared,
                    asset: ReaderStyleAsset(
                        id: descriptor.id,
                        name: name,
                        mimeType: prepared.mimeType,
                        pixelWidth: prepared.pixelWidth,
                        pixelHeight: prepared.pixelHeight,
                        hasAlpha: prepared.hasAlpha,
                        sha256: prepared.sha256,
                        fileName: Self.fileName(
                            id: descriptor.id,
                            sha256: prepared.sha256,
                            suffix: nil,
                            fileExtension: prepared.fileExtension
                        ),
                        thumbnailFileName: Self.fileName(
                            id: descriptor.id,
                            sha256: prepared.sha256,
                            suffix: "thumb",
                            fileExtension: prepared.fileExtension
                        )
                    )
                )
            )
        }

        let previousAssets = storedAssets
        let previousRevision = revision
        var resultingAssets = storedAssets
        for item in imports {
            if let index = resultingAssets.firstIndex(where: { $0.id == item.asset.id }) {
                resultingAssets[index] = item.asset
            } else {
                resultingAssets.append(item.asset)
            }
        }

        var newlyCreatedURLs: [URL] = []
        var didChange = false
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            for item in imports {
                let imageURL = rootURL.appendingPathComponent(item.asset.fileName)
                let thumbnailURL = rootURL.appendingPathComponent(item.asset.thumbnailFileName)
                try writePackageFileIfNeeded(
                    item.prepared.data,
                    expectedSHA256: item.prepared.sha256,
                    to: imageURL,
                    newlyCreatedURLs: &newlyCreatedURLs
                )
                try writePackageFileIfNeeded(
                    item.prepared.thumbnailData,
                    expectedSHA256: nil,
                    to: thumbnailURL,
                    newlyCreatedURLs: &newlyCreatedURLs
                )
            }

            didChange = resultingAssets != previousAssets || !newlyCreatedURLs.isEmpty
            if didChange {
                storedAssets = resultingAssets
                revision &+= 1
                try persistManifest()
            }
        } catch {
            storedAssets = previousAssets
            revision = previousRevision
            for url in newlyCreatedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw Self.storeError(from: error)
        }

        for item in imports {
            imageCache.insert(item.prepared.image, for: item.asset.id)
        }
        for previous in previousAssets {
            guard let replacement = resultingAssets.first(where: { $0.id == previous.id }) else {
                continue
            }
            removeOrphanedFile(named: previous.fileName, keeping: replacement.fileName)
            removeOrphanedFile(
                named: previous.thumbnailFileName,
                keeping: replacement.thumbnailFileName
            )
        }
        if didChange {
            postRevisionChange()
        }
    }

    private func ensureStoreIsReadable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func postRevisionChange() {
        NotificationCenter.default.post(
            name: .readerStyleAssetsDidChange,
            object: nil,
            userInfo: [Self.revisionUserInfoKey: NSNumber(value: revision)]
        )
    }

    private func write(_ data: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ReaderStyleAssetStoreError.writeFailed
        }
    }

    private func writePackageFileIfNeeded(
        _ data: Data,
        expectedSHA256: String?,
        to destination: URL,
        newlyCreatedURLs: inout [URL]
    ) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let existing = try? Data(contentsOf: destination) else {
                throw ReaderStyleAssetStoreError.writeFailed
            }
            if let expectedSHA256 {
                guard Self.sha256(existing) == expectedSHA256 else {
                    throw ReaderStyleAssetStoreError.writeFailed
                }
            } else {
                guard existing == data else {
                    throw ReaderStyleAssetStoreError.writeFailed
                }
            }
            return
        }
        try write(data, to: destination)
        newlyCreatedURLs.append(destination)
    }

    private func persistManifest() throws {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let manifest = Manifest(
                version: Self.manifestVersion,
                revision: revision,
                assets: storedAssets
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw ReaderStyleAssetStoreError.writeFailed
        }
    }

    private func removeOrphanedFile(named fileName: String, keeping keptName: String?) {
        guard fileName != keptName else { return }
        let url = rootURL.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // The manifest is the committed source of truth. Cleanup happens only after that commit;
        // an OS-level removal failure may leave an unreachable file, but cannot resurrect a
        // deleted asset or invalidate the successfully saved metadata.
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadManifest(at manifestURL: URL) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return Manifest(version: manifestVersion, revision: 0, assets: [])
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == manifestVersion,
              Set(manifest.assets.map(\.id)).count == manifest.assets.count else {
            throw ReaderStyleAssetStoreError.writeFailed
        }
        return manifest
    }

    private static func prepareImage(data: Data) throws -> PreparedImage {
        guard data.count <= maximumInputBytes else {
            throw ReaderStyleAssetStoreError.inputTooLarge(
                actual: data.count,
                maximum: maximumInputBytes
            )
        }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let pixelWidth = integerProperty(properties[kCGImagePropertyPixelWidth]),
              let pixelHeight = integerProperty(properties[kCGImagePropertyPixelHeight]),
              pixelWidth > 0,
              pixelHeight > 0 else {
            throw ReaderStyleAssetStoreError.invalidImage
        }

        let (decodedPixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        let reportedPixels = overflow ? Int.max : decodedPixels
        guard !overflow, decodedPixels <= maximumDecodedPixels else {
            throw ReaderStyleAssetStoreError.decodedImageTooLarge(
                actualPixels: reportedPixels,
                maximumPixels: maximumDecodedPixels
            )
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumStoredDimension
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ReaderStyleAssetStoreError.invalidImage
        }

        let hasAlpha = Self.hasAlpha(cgImage)
        let image = UIImage(cgImage: cgImage)
        guard let normalized = ImportedImageNormalizer.encode(
            resized: image,
            preservingPNG: hasAlpha
        ) else {
            throw ReaderStyleAssetStoreError.invalidImage
        }
        let thumbnail = Self.thumbnail(from: image, hasAlpha: hasAlpha)
        let thumbnailData: Data?
        if hasAlpha {
            thumbnailData = thumbnail.pngData()
        } else {
            thumbnailData = thumbnail.jpegData(compressionQuality: 0.9)
        }
        guard let thumbnailData else {
            throw ReaderStyleAssetStoreError.invalidImage
        }

        let hash = SHA256.hash(data: normalized.data)
            .map { String(format: "%02x", $0) }
            .joined()
        return PreparedImage(
            image: image,
            data: normalized.data,
            thumbnailData: thumbnailData,
            fileExtension: normalized.fileExtension,
            mimeType: normalized.fileExtension == "png" ? "image/png" : "image/jpeg",
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            hasAlpha: hasAlpha,
            sha256: hash
        )
    }

    private static func prepareValidatedPackageImage(
        data: Data,
        expectedSHA256: String,
        relativePath: String
    ) throws -> PreparedImage {
        guard sha256(data) == expectedSHA256.lowercased() else {
            throw ReaderStylePackageError.hashMismatch(relativePath)
        }
        // The archive hash authenticates the transported bytes; the store still
        // runs its single normalization path so a hand-authored package cannot
        // bypass decoded-pixel checks or persist an image larger than 4096 px.
        return try prepareImage(data: data)
    }

    private static func thumbnail(from image: UIImage, hasAlpha: Bool) -> UIImage {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        let ratio = min(
            1,
            CGFloat(thumbnailDimension) / max(width, height)
        )
        let size = CGSize(
            width: max(1, (width * ratio).rounded()),
            height: max(1, (height * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            false
        }
    }

    private static func integerProperty(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func fileName(
        id: UUID,
        sha256: String,
        suffix: String?,
        fileExtension: String
    ) -> String {
        let suffixComponent = suffix.map { "-\($0)" } ?? ""
        return "\(id.uuidString.lowercased())-\(sha256.prefix(16))\(suffixComponent).\(fileExtension)"
    }

    private static func normalizedName(_ suggestedName: String, sha256: String) -> String {
        let name = (suggestedName as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "asset-\(sha256.prefix(8))" : name
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func storeError(from error: Error) -> ReaderStyleAssetStoreError {
        error as? ReaderStyleAssetStoreError ?? .writeFailed
    }

    private static func defaultRootURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ReaderStyleAssets", isDirectory: true)
    }
}

final class ReaderStyleAssetImageCache: @unchecked Sendable {
    static let shared = ReaderStyleAssetImageCache()

    private let lock = NSLock()
    private var images: [UUID: UIImage] = [:]

    func image(for id: UUID) -> UIImage? {
        lock.withLock { images[id] }
    }

    func insert(_ image: UIImage, for id: UUID) {
        lock.withLock { images[id] = image }
    }

    func remove(_ id: UUID) {
        _ = lock.withLock { images.removeValue(forKey: id) }
    }
}
