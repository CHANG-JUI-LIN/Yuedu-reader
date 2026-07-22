import CryptoKit
import Foundation

enum ChapterCacheWriteError: LocalizedError, Equatable, Sendable {
    case emptyContent
    case createDirectory(String)
    case writeBody(String)
    case writeMetadata(String)
    case writeArtifact(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Chapter content is empty"
        case .createDirectory(let message):
            return "Unable to create chapter cache directory: \(message)"
        case .writeBody(let message):
            return "Unable to write chapter body: \(message)"
        case .writeMetadata(let message):
            return "Unable to write chapter metadata: \(message)"
        case .writeArtifact(let message):
            return "Unable to write chapter artifact: \(message)"
        case .verificationFailed:
            return "Chapter cache verification failed"
        }
    }
}

struct ChapterCacheRepository: Sendable {
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("online_cache", isDirectory: true)
    }

    func loadCachedChapterSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return nil
        }
        let url = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return nil
        }
        let url = chapterNormalizedHTMLPath(bookId: bookId, chapterIndex: chapterIndex)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return false
        }
        let url = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Upgrade legacy entries that predate the .package.json artifact so that
        // loadChapterPackageSync (which requires the artifact) can validate them.
        upgradeLegacyChapterCacheIfNeeded(bookId: bookId, chapterIndex: chapterIndex)
        return true
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        try? FileManager.default.removeItem(at: cachePath(bookId: bookId, chapterIndex: chapterIndex))
        try? FileManager.default.removeItem(at: cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex))
        try? FileManager.default.removeItem(at: chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex))
        try? FileManager.default.removeItem(at: chapterRawHTMLPath(bookId: bookId, chapterIndex: chapterIndex))
        try? FileManager.default.removeItem(
            at: chapterNormalizedHTMLPath(bookId: bookId, chapterIndex: chapterIndex)
        )
    }

    func clearAllChapterCache(bookId: UUID) {
        try? FileManager.default.removeItem(at: cacheDir(for: bookId))
    }

    @discardableResult
    func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil,
        storeNormalizedHTML: Bool = true
    ) throws -> String {
        let canonicalTitle = extractedTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let displayTOCTitle = tocTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let effectiveTitle = canonicalTitle?.isEmpty == false ? canonicalTitle! : (displayTOCTitle ?? "")
        let normalizedHTML = storeNormalizedHTML
            ? ChapterFetcher.shared.buildNormalizedHTML(title: effectiveTitle, content: content)
            : nil
        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: displayTOCTitle?.isEmpty == false ? displayTOCTitle : nil,
            canonicalTitle: canonicalTitle?.isEmpty == false ? canonicalTitle : nil,
            content: content,
            contentChecksum: cacheChecksum(for: content),
            rawHTMLFilename: rawHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "\(chapterIndex).raw.html" : nil,
            normalizedHTMLFilename: storeNormalizedHTML ? "\(chapterIndex).normalized.xhtml" : nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        return try saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML
        )
    }

    @discardableResult
    func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String?
    ) throws -> String {
        guard !package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChapterCacheWriteError.emptyContent
        }

        let dir = cacheDir(for: package.bookId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ChapterCacheWriteError.createDirectory(error.localizedDescription)
        }

        let filename = "\(package.chapterIndex).txt"
        let contentPath = cachePath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let checksum = cacheChecksum(for: package.content)

        do {
            try package.content.write(to: contentPath, atomically: true, encoding: .utf8)
        } catch {
            clearChapterCache(bookId: package.bookId, chapterIndex: package.chapterIndex)
            throw ChapterCacheWriteError.writeBody(error.localizedDescription)
        }

        let metadata = CachedChapterMetadata(
            sourceURL: package.sourceURL,
            tocTitle: package.tocTitle,
            extractedTitle: package.canonicalTitle,
            contentChecksum: checksum,
            savedAt: package.savedAt,
            state: .cached,
            failureReason: nil
        )
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(
                to: cacheMetadataPath(bookId: package.bookId, chapterIndex: package.chapterIndex),
                options: .atomic
            )
        } catch {
            clearChapterCache(bookId: package.bookId, chapterIndex: package.chapterIndex)
            throw ChapterCacheWriteError.writeMetadata(error.localizedDescription)
        }

        do {
            try saveChapterArtifact(
                package: package,
                contentChecksum: checksum,
                rawHTML: rawHTML,
                normalizedHTML: normalizedHTML
            )
        } catch let error as ChapterCacheWriteError {
            clearChapterCache(bookId: package.bookId, chapterIndex: package.chapterIndex)
            throw error
        } catch {
            clearChapterCache(bookId: package.bookId, chapterIndex: package.chapterIndex)
            throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
        }

        guard
            let verified = loadChapterPackageSync(
                bookId: package.bookId,
                chapterIndex: package.chapterIndex,
                expectedSourceURL: package.sourceURL,
                expectedTOCTitle: package.tocTitle
            ),
            verified.state == .cached,
            verified.content == package.content,
            verified.contentChecksum == checksum
        else {
            clearChapterCache(bookId: package.bookId, chapterIndex: package.chapterIndex)
            throw ChapterCacheWriteError.verificationFailed
        }
        return filename
    }

    func saveFailureMarker(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        reason: String? = nil
    ) {
        let dir = cacheDir(for: bookId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)

        let metadata = CachedChapterMetadata(
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            contentChecksum: "",
            savedAt: Date(),
            state: .failed,
            failureReason: reason
        )
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(
                to: cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex),
                options: .atomic
            )
        }
    }

    func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        let url = cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedChapterMetadata.self, from: data)
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        // The package loader is the reading pipeline's source of truth. Upgrade
        // old offline downloads here (not only from `isChapterCached`) so opening
        // an already-downloaded chapter can never miss its valid `.txt` body.
        upgradeLegacyChapterCacheIfNeeded(bookId: bookId, chapterIndex: chapterIndex)
        guard let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            print("[CacheDebug] ch=\(chapterIndex) FAIL: no metadata")
            return nil
        }
        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            print("[CacheDebug] ch=\(chapterIndex) FAIL: URL mismatch saved=\(metadata.sourceURL ?? "nil") expected=\(expectedSourceURL)")
            return nil
        }
        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                print("[CacheDebug] ch=\(chapterIndex) FAIL: title mismatch saved='\(normalizedCached)' expected='\(normalizedExpected)'")
                return nil
            }
        }

        let packageURL = chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex)
        let bodyURL = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        let artifactData = try? Data(contentsOf: packageURL)
        let artifact = artifactData.flatMap { try? JSONDecoder().decode(ChapterPackageArtifact.self, from: $0) }
        let body = (try? String(contentsOf: bodyURL, encoding: .utf8)) ?? ""
        let cachedTitle = metadata.extractedTitle ?? metadata.tocTitle ?? ""

        if metadata.state == .cached {
            guard let artifact, !body.isEmpty, artifact.contentChecksum == cacheChecksum(for: body) else {
                print("[CacheDebug] ch=\(chapterIndex) FAIL: artifact=\(artifact != nil) bodyLen=\(body.count) checksumMatch=\(artifact.map { $0.contentChecksum == cacheChecksum(for: body) } ?? false)")
                return nil
            }
            if ChapterFetcher.shared.isRejectedChapterContent(body, title: cachedTitle) {
                print("[CacheDebug] ch=\(chapterIndex) FAIL: content rejected bodyLen=\(body.count) title='\(cachedTitle)'")
                return nil
            }
            return ChapterPackage(
                bookId: bookId,
                chapterIndex: chapterIndex,
                sourceURL: artifact.sourceURL ?? metadata.sourceURL,
                tocTitle: artifact.tocTitle ?? metadata.tocTitle,
                canonicalTitle: artifact.canonicalTitle ?? metadata.extractedTitle,
                content: body,
                contentChecksum: artifact.contentChecksum,
                rawHTMLFilename: artifact.rawHTMLFilename,
                normalizedHTMLFilename: artifact.normalizedHTMLFilename,
                savedAt: artifact.savedAt,
                state: .cached,
                failureReason: nil
            )
        }

        return ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: metadata.sourceURL,
            tocTitle: metadata.tocTitle,
            canonicalTitle: metadata.extractedTitle,
            content: "",
            contentChecksum: metadata.contentChecksum,
            rawHTMLFilename: artifact?.rawHTMLFilename,
            normalizedHTMLFilename: artifact?.normalizedHTMLFilename,
            savedAt: metadata.savedAt,
            state: .failed,
            failureReason: metadata.failureReason
        )
    }

    private func isCachedChapterMetadataValid(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        let textPath = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: textPath.path) else { return false }
        guard let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            return expectedSourceURL == nil && expectedTOCTitle == nil
        }

        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            return false
        }

        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                return false
            }
        }

        return true
    }

    private func cacheDir(for bookId: UUID) -> URL {
        rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    private func cachePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).txt")
    }

    private func cacheMetadataPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).meta.json")
    }

    private func chapterPackagePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).package.json")
    }

    private func chapterRawHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).raw.html")
    }

    private func chapterNormalizedHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).normalized.xhtml")
    }

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }

    private func normalizeCacheTitle(_ title: String) -> String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    private func cacheChecksum(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Synthesises a missing `.package.json` artifact from the existing `.txt` and
    /// `.meta.json` files.  Chapters cached by older app versions lack the artifact,
    /// which makes `loadChapterPackageSync` (and therefore `isChapterContentAvailable`)
    /// always return `nil` even though the content is valid — causing a permanent
    /// "loading" state in the reader.
    private func upgradeLegacyChapterCacheIfNeeded(bookId: UUID, chapterIndex: Int) {
        let packageURL = chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex)
        guard !FileManager.default.fileExists(atPath: packageURL.path) else { return }

        let bodyURL = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard
            let body = try? String(contentsOf: bodyURL, encoding: .utf8),
            !body.isEmpty,
            let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex),
            metadata.state == .cached || metadata.state == nil
        else { return }

        let checksum = cacheChecksum(for: body)

        // Write upgraded .package.json using the existing body checksum.
        let artifact = ChapterPackageArtifact(
            sourceURL: metadata.sourceURL,
            tocTitle: metadata.tocTitle,
            canonicalTitle: metadata.extractedTitle,
            contentChecksum: checksum,
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: metadata.savedAt
        )
        if let data = try? JSONEncoder().encode(artifact) {
            try? data.write(to: packageURL, options: .atomic)
        }

        // Backfill both fields used by the current package loader. Some legacy
        // metadata already has a checksum but predates the explicit state field.
        if metadata.contentChecksum != checksum || metadata.state != .cached {
            let updated = CachedChapterMetadata(
                sourceURL: metadata.sourceURL,
                tocTitle: metadata.tocTitle,
                extractedTitle: metadata.extractedTitle,
                contentChecksum: checksum,
                savedAt: metadata.savedAt,
                state: .cached,
                failureReason: nil
            )
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(
                    to: cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex),
                    options: .atomic
                )
            }
        }
    }

    private func saveChapterArtifact(
        package: ChapterPackage,
        contentChecksum: String,
        rawHTML: String?,
        normalizedHTML: String?
    ) throws {
        let rawPath = chapterRawHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let normalizedPath = chapterNormalizedHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex)
        let packagePath = chapterPackagePath(bookId: package.bookId, chapterIndex: package.chapterIndex)

        let rawFilename: String?
        if let rawHTML, !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try rawHTML.write(to: rawPath, atomically: true, encoding: .utf8)
                rawFilename = rawPath.lastPathComponent
            } catch {
                throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
            }
        } else {
            if FileManager.default.fileExists(atPath: rawPath.path) {
                try FileManager.default.removeItem(at: rawPath)
            }
            rawFilename = nil
        }

        let normalizedFilename: String?
        if let normalizedHTML {
            do {
                try normalizedHTML.write(to: normalizedPath, atomically: true, encoding: .utf8)
            } catch {
                throw ChapterCacheWriteError.writeArtifact(error.localizedDescription)
            }
            normalizedFilename = normalizedPath.lastPathComponent
        } else {
            if FileManager.default.fileExists(atPath: normalizedPath.path) {
                try FileManager.default.removeItem(at: normalizedPath)
            }
            normalizedFilename = nil
        }

        let artifact = ChapterPackageArtifact(
            sourceURL: package.sourceURL,
            tocTitle: package.tocTitle,
            canonicalTitle: package.canonicalTitle,
            contentChecksum: contentChecksum,
            rawHTMLFilename: rawFilename,
            normalizedHTMLFilename: normalizedFilename,
            savedAt: package.savedAt
        )
        let data = try JSONEncoder().encode(artifact)
        try data.write(to: packagePath, options: .atomic)
    }
}
