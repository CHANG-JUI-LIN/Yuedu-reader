import CryptoKit
import Foundation

// MARK: - TOC + BookInfo Cache Management

extension BookSourceFetcher {

    nonisolated func tocCacheDir() -> URL {
        StorageLocations.tocCache
    }

    nonisolated func bookInfoCacheDir() -> URL {
        StorageLocations.bookInfoCache
    }

    /// - Parameter maximumAge: reject a package older than this. Defaults to
    ///   `AppConfig.tocCacheTTL`; pass `nil` only where a stale list is genuinely better than
    ///   none. See `AppConfig.tocCacheTTL` for why serving these forever was a bug.
    nonisolated func loadTOCPackageSync(
        tocUrl: String,
        source: BookSource,
        maximumAge: TimeInterval? = AppConfig.tocCacheTTL
    ) -> TOCPackage? {
        let path = tocPackagePath(tocUrl: tocUrl, source: source)
        guard let data = try? Data(contentsOf: path),
            let package = try? JSONDecoder().decode(TOCPackage.self, from: data),
            normalizedURLKey(package.tocURL) == normalizedURLKey(tocUrl),
            package.sourceId == source.id
        else {
            return nil
        }
        if let maximumAge, Date().timeIntervalSince(lastConfirmed(package.savedAt, file: path)) > maximumAge {
            return nil
        }
        return package
    }

    /// A refresh that finds the same list does not rewrite the package; it touches the file
    /// (`saveTOCPackage`). So a package was last confirmed current at the later of its own
    /// `savedAt` and the file's modification date.
    private nonisolated func lastConfirmed(_ savedAt: Date, file: URL) -> Date {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let modified = attributes[.modificationDate] as? Date else { return savedAt }
            return max(savedAt, modified)
        } catch {
            AppLogger.cache("TOC cache date unreadable", error: error, context: ["file": file.lastPathComponent])
            return savedAt
        }
    }

    /// Drops the cached table of contents and book info for one book's source binding.
    ///
    /// Required wherever a book's cached *content* is discarded: after 移除下載 every chapter
    /// goes back to the network for the first time in however long, and doing that against
    /// chapter URLs the cache has been replaying since they were first fetched is what made a
    /// removal take the whole book down with it.
    nonisolated func clearTOCAndBookInfoCache(
        tocUrl: String?,
        bookURL: String?,
        source: BookSource
    ) {
        let manager = FileManager.default
        if let tocUrl, !tocUrl.isEmpty {
            try? manager.removeItem(at: tocPackagePath(tocUrl: tocUrl, source: source))
            try? manager.removeItem(at: tocFingerprintPath(tocUrl: tocUrl, source: source))
            // Written by builds before 2026-10; nothing reads it.
            try? manager.removeItem(at: tocRawHTMLPath(tocUrl: tocUrl, source: source))
        }
        if let bookURL, !bookURL.isEmpty {
            try? manager.removeItem(at: bookInfoPackagePath(url: bookURL, source: source))
            try? manager.removeItem(at: bookInfoRawHTMLPath(url: bookURL, source: source))
        }
    }

    nonisolated func loadBookInfoPackageSync(
        url: String,
        source: BookSource,
        maximumAge: TimeInterval? = AppConfig.tocCacheTTL
    ) -> BookInfoPackage? {
        let path = bookInfoPackagePath(url: url, source: source)
        guard let data = try? Data(contentsOf: path),
            let package = try? JSONDecoder().decode(BookInfoPackage.self, from: data),
            normalizedURLKey(package.bookURL) == normalizedURLKey(url),
            package.sourceId == source.id
        else {
            return nil
        }
        if let maximumAge, Date().timeIntervalSince(package.savedAt) > maximumAge {
            return nil
        }
        return package
    }

    /// A fetched table of contents as `saveTOCPackage` would cache it, without caching it.
    nonisolated func makeTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        chapters: [OnlineChapterRef]
    ) -> TOCPackage {
        TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: tocUrl,
            runtimeVariables: runtimeVariables,
            chapters: chapters,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    /// Caches a fetched table of contents, unless it is the one already cached.
    ///
    /// Every launch's "check for new chapters" passes through here for every online book. It
    /// used to write the full package JSON plus the page's raw HTML each time — several MB
    /// per book, rewritten whether anything changed or not, which with the shelf rewrite
    /// added up to the ≈1 GB `disk-write-exception` reports within a minute of launch. The raw
    /// HTML was never read by anything and is no longer written. The package is written only
    /// when its content fingerprint (chapter ids excluded: every parse invents new ones)
    /// differs from the stored one; otherwise the file is only touched, which renews its TTL.
    @discardableResult
    nonisolated func saveTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        chapters: [OnlineChapterRef]
    ) -> TOCPackage {
        let package = makeTOCPackage(
            tocUrl: tocUrl, source: source, runtimeVariables: runtimeVariables, chapters: chapters
        )
        let manager = FileManager.default
        let path = tocPackagePath(tocUrl: tocUrl, source: source)
        let fingerprintPath = tocFingerprintPath(tocUrl: tocUrl, source: source)
        let fingerprint = Self.tocFingerprint(chapters: chapters, runtimeVariables: runtimeVariables)
        do {
            if manager.fileExists(atPath: path.path), manager.fileExists(atPath: fingerprintPath.path),
               try String(contentsOf: fingerprintPath, encoding: .utf8) == fingerprint {
                try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                return package
            }
            try manager.createDirectory(at: tocCacheDir(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(package)
            try data.write(to: path, options: .atomic)
            try Data(fingerprint.utf8).write(to: fingerprintPath, options: .atomic)
            SourcePerfTrace.record("toc.cache.write", "bytes=\(data.count) \(source.bookSourceName)", since: SourcePerfTrace.now)
        } catch {
            AppLogger.cache("TOC cache not saved", error: error, context: ["source": source.bookSourceName])
        }
        return package
    }

    /// SHA-256 over everything a cached list carries except chapter ids.
    nonisolated static func tocFingerprint(chapters: [OnlineChapterRef], runtimeVariables: [String: String]?) -> String {
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        func add(_ variables: [String: String]?) {
            guard let variables else { return add("∅") }
            for key in variables.keys.sorted() { add(key); add(variables[key] ?? "") }
            add("§")
        }
        add(runtimeVariables)
        for chapter in chapters {
            add("\(chapter.index)"); add(chapter.title); add(chapter.url)
            add("\(chapter.isVolume)\(chapter.isVip)\(chapter.isPay)")
            add(chapter.cachedFilename ?? "∅")
            add(chapter.runtimeVariables)
            add("\(chapter.audioStartSeconds ?? -1)|\(chapter.audioDurationSeconds ?? -1)|\(chapter.pdfPageCount ?? -1)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated func saveBookInfoPackage(
        info: OnlineBook,
        source: BookSource
    ) -> BookInfoPackage {
        let dir = bookInfoCacheDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The page's raw HTML used to be written beside it; nothing ever read it.
        let package = BookInfoPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookURL: info.bookUrl,
            name: info.name,
            author: info.author,
            intro: info.intro,
            coverUrl: info.coverUrl,
            tocUrl: info.tocUrl,
            wordCount: info.wordCount,
            lastChapter: info.lastChapter,
            kind: info.kind,
            runtimeVariables: info.runtimeVariables,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(package) {
            try? data.write(to: bookInfoPackagePath(url: info.bookUrl, source: source), options: .atomic)
        }
        return package
    }

    // MARK: - Private Helpers

    private nonisolated func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }

    private nonisolated func tocCacheKey(tocUrl: String, source: BookSource) -> String {
        let seed = "\(source.id.uuidString)|\(normalizedURLKey(tocUrl))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated func tocPackagePath(tocUrl: String, source: BookSource) -> URL {
        tocCacheDir().appendingPathComponent("\(tocCacheKey(tocUrl: tocUrl, source: source)).json")
    }

    nonisolated func tocFingerprintPath(tocUrl: String, source: BookSource) -> URL {
        tocCacheDir().appendingPathComponent("\(tocCacheKey(tocUrl: tocUrl, source: source)).sha256")
    }

    nonisolated func tocRawHTMLPath(tocUrl: String, source: BookSource) -> URL {
        tocCacheDir().appendingPathComponent(
            "\(tocCacheKey(tocUrl: tocUrl, source: source)).raw.html")
    }

    private nonisolated func bookInfoCacheKey(url: String, source: BookSource) -> String {
        let seed = "\(source.id.uuidString)|\(normalizedURLKey(url))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func bookInfoPackagePath(url: String, source: BookSource) -> URL {
        bookInfoCacheDir().appendingPathComponent(
            "\(bookInfoCacheKey(url: url, source: source)).json")
    }

    private nonisolated func bookInfoRawHTMLPath(url: String, source: BookSource) -> URL {
        bookInfoCacheDir().appendingPathComponent(
            "\(bookInfoCacheKey(url: url, source: source)).raw.html")
    }

    nonisolated static func cleanChapterContent(_ text: String) -> String {
        ChapterFetcher.shared.cleanChapterContent(text)
    }
}
