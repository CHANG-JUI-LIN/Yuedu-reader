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
        let fields = TOCFieldDigests(chapters: chapters, runtimeVariables: runtimeVariables)
        do {
            var stored: String?
            if manager.fileExists(atPath: path.path), manager.fileExists(atPath: fingerprintPath.path) {
                stored = try String(contentsOf: fingerprintPath, encoding: .utf8)
            }
            // The first line is the whole-list fingerprint; files written before the field
            // digests were added hold only that line, and still match.
            let storedLines = stored?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            if let first = storedLines.first, String(first) == fingerprint {
                try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                return package
            }
            try manager.createDirectory(at: tocCacheDir(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(package)
            try data.write(to: path, options: .atomic)
            let fingerprintData = Data((fingerprint + "\n" + fields.serialized).utf8)
            try fingerprintData.write(to: fingerprintPath, options: .atomic)
            let previous = storedLines.count > 1 ? TOCFieldDigests(serialized: String(storedLines[1])) : nil
            DiskWriteTally.record(
                Self.tocDiskWriteTallyName,
                reason: fields.changeReason(from: previous, hadPackage: stored != nil),
                bytes: data.count + fingerprintData.count
            )
            SourcePerfTrace.record("toc.cache.write", "bytes=\(data.count) \(source.bookSourceName)", since: SourcePerfTrace.now)
        } catch {
            AppLogger.cache("TOC cache not saved", error: error, context: ["source": source.bookSourceName])
        }
        return package
    }

    /// The writer `saveTOCPackage` counts its writes under (`DiskWriteTally`).
    nonisolated static let tocDiskWriteTallyName = "toc"

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
            // Only when present: a list without update times keeps the fingerprint it had,
            // so adding the field rewrote no cached table of contents.
            if let updateTime = chapter.updateTime { add("⏱"); add(updateTime) }
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
        // The page's raw HTML used to be written beside it; nothing ever read it.
        let package = makeBookInfoPackage(info: info, source: source)
        do {
            try FileManager.default.createDirectory(at: bookInfoCacheDir(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(package)
            try data.write(to: bookInfoPackagePath(url: info.bookUrl, source: source), options: .atomic)
            DiskWriteTally.record("bookInfo", reason: source.bookSourceName, bytes: data.count)
        } catch {
            AppLogger.cache("Book info cache not saved", error: error, context: ["source": source.bookSourceName])
        }
        return package
    }

    /// Fetched book info as `saveBookInfoPackage` would cache it, without caching it.
    nonisolated func makeBookInfoPackage(info: OnlineBook, source: BookSource) -> BookInfoPackage {
        BookInfoPackage(
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
            savedAt: Date(),
            tocHtml: info.tocHtml
        )
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

/// A cached table of contents, digested field by field, so a rewrite can say what changed.
///
/// `saveTOCPackage` rewrites the whole package (≈1 MB for a long novel) whenever the
/// whole-list fingerprint differs. Two field reports (3.0.1 (146), 1 GB in a day each) could
/// not say whether those rewrites were new chapters — real work — or a list that came back
/// the same length with something churning in it (a per-request token in every URL, a
/// relative update time, runtime variables). The digests ride on the fingerprint file's second
/// line and name the churning field in the `toc` tally's reason.
struct TOCFieldDigests: Equatable {
    var count: Int
    /// Field name → hex digest over that field of every chapter, in order.
    var fields: [String: String]

    nonisolated static let fieldNames = ["titles", "urls", "updateTimes", "flags", "cachedFilenames", "chapterVariables", "media", "variables"]

    nonisolated init(chapters: [OnlineChapterRef], runtimeVariables: [String: String]?) {
        var hashers = Dictionary(uniqueKeysWithValues: Self.fieldNames.map { ($0, SHA256()) })
        func add(_ field: String, _ text: String) {
            hashers[field]?.update(data: Data(text.utf8))
            hashers[field]?.update(data: Data([0]))
        }
        func variables(_ values: [String: String]?) -> String {
            guard let values else { return "∅" }
            return values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\u{1f}")
        }
        add("variables", variables(runtimeVariables))
        for chapter in chapters {
            add("titles", "\(chapter.index)|\(chapter.title)")
            add("urls", chapter.url)
            add("updateTimes", chapter.updateTime ?? "∅")
            add("flags", "\(chapter.isVolume)\(chapter.isVip)\(chapter.isPay)")
            add("cachedFilenames", chapter.cachedFilename ?? "∅")
            add("chapterVariables", variables(chapter.runtimeVariables))
            add("media", "\(chapter.audioStartSeconds ?? -1)|\(chapter.audioDurationSeconds ?? -1)|\(chapter.pdfPageCount ?? -1)")
        }
        count = chapters.count
        // 8 bytes of each digest is plenty to tell "changed" from "same".
        fields = hashers.mapValues { $0.finalize().prefix(8).map { String(format: "%02x", $0) }.joined() }
    }

    /// Reads `serialized`; nil for a line this type did not write.
    nonisolated init?(serialized: String) {
        var count: Int?
        var fields: [String: String] = [:]
        for pair in serialized.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0] == "n" { count = Int(parts[1]) } else { fields[parts[0]] = parts[1] }
        }
        guard let count else { return nil }
        self.count = count
        self.fields = fields
    }

    nonisolated var serialized: String {
        (["n=\(count)"] + Self.fieldNames.map { "\($0)=\(fields[$0] ?? "")" }).joined(separator: ";")
    }

    /// Why a package is being written over `previous`: new chapters, lost chapters, or the
    /// same number of chapters with the named fields changed.
    nonisolated func changeReason(from previous: TOCFieldDigests?, hadPackage: Bool) -> String {
        guard hadPackage else { return "new n=\(count)" }
        guard let previous else { return "changed n=\(count) fields=unknown" }
        let changed = Self.fieldNames.filter { fields[$0] != previous.fields[$0] }
        if count > previous.count { return "grew+\(count - previous.count) n=\(count)" }
        if count < previous.count { return "shrank-\(previous.count - count) n=\(count)" }
        return "sameCount n=\(count) fields=\(changed.isEmpty ? "none" : changed.joined(separator: ","))"
    }
}
