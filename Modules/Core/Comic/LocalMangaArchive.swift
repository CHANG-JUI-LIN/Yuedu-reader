import Foundation
import ReadiumZIPFoundation
import UIKit

struct LocalMangaComicInfo: Equatable {
    var title: String?
    var series: String?
    var number: String?
    var volume: Int?
    var summary: String?
    var writer: String?
    var penciller: String?
    var manga: String?
}

struct LocalMangaImportInfo: Equatable {
    let title: String
    let author: String
    let chapterTitle: String
    let pageCount: Int
    let comicInfo: LocalMangaComicInfo?
}

enum LocalMangaArchiveError: LocalizedError {
    case invalidFileType
    case cannotReadArchive
    case noImagesFound
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return localized("不支援的漫畫格式")
        case .cannotReadArchive:
            return localized("無法讀取漫畫壓縮檔")
        case .noImagesFound:
            return localized("漫畫壓縮檔中未找到圖片")
        case .extractionFailed:
            return localized("漫畫圖片解壓失敗")
        }
    }
}

// MARK: - Local comic archive
//
// A local comic is its archive: the `.cbz` / `.zip` the user imported stays in Documents,
// and every page is read straight out of it, one entry at a time, when the reader asks
// for it. Nothing is extracted to disk — not at import, not when reading. (Builds up to
// 2.0.7 extracted every page into `Application Support/local_manga/<bookId>/` at import,
// writing the book a second time; see `discardLegacyExtractedPages`.)
//
// Formats: only ZIP containers (`.cbz`, `.zip`) are imported — `LocalBookImportService`
// routes nothing else here — and ZIP is random-access through its central directory,
// so one entry is read without touching the rest. There is no RAR / 7z reader in the
// project, so `.cbr` / `.cb7` are not importable at all (unchanged).

enum LocalMangaArchive {
    static let allowedArchiveExtensions = Set(["cbz", "zip"])
    static let allowedImageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"])

    static func supports(_ url: URL) -> Bool {
        allowedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// The user's own archive file (`.cbz` / `.zip`), so it stays in Documents.
    static func archiveURL(for filename: String) -> URL {
        StorageLocations.bookFile(filename)
    }

    static func inspect(url: URL) async throws -> LocalMangaImportInfo {
        guard supports(url) else { throw LocalMangaArchiveError.invalidFileType }
        let index = try await LocalMangaArchiveIndex.open(url)

        let comicInfo = await comicInfo(in: index)
        let fallbackTitle = cleanTitle(url.deletingPathExtension().lastPathComponent)
        let title = firstNonEmpty(comicInfo?.series, fallbackTitle)
        let chapterTitle = firstNonEmpty(comicInfo?.title, fallbackTitle)
        let author = firstNonEmpty(comicInfo?.writer, comicInfo?.penciller, localized("未知作者"))
        return LocalMangaImportInfo(
            title: title,
            author: author,
            chapterTitle: chapterTitle,
            pageCount: index.imagePaths.count,
            comicInfo: comicInfo
        )
    }

    /// The archive's page images in reading order (natural sort of their paths).
    static func imageEntryPaths(in archiveURL: URL) async throws -> [String] {
        guard supports(archiveURL) else { throw LocalMangaArchiveError.invalidFileType }
        return try await LocalMangaArchiveIndex.open(archiveURL).imagePaths
    }

    /// A chapter's pages, each one an entry of the archive in Documents. Opening goes
    /// through the reader's shared archive, so the pages that follow read from an index
    /// that is already in memory.
    static func pages(archiveFilename: String) async throws -> [FixedPage] {
        let archiveURL = Self.archiveURL(for: archiveFilename)
        guard supports(archiveURL) else { throw LocalMangaArchiveError.invalidFileType }
        let paths = try await LocalMangaArchiveReader.shared.imageEntryPaths(in: archiveURL)
        return paths.enumerated().map { index, path in
            FixedPage(
                id: index,
                imageURL: path,
                headers: [:],
                localURL: nil,
                renderSource: .archiveImage(sourceFilename: archiveFilename, entryPath: path)
            )
        }
    }

    static func coverImageData(from archiveURL: URL) async -> (data: Data, fileExtension: String)? {
        do {
            let index = try await LocalMangaArchiveIndex.open(archiveURL)
            guard let firstPath = index.imagePaths.first else { return nil }
            let data = try await index.data(forEntryPath: firstPath)
            return (data, (firstPath as NSString).pathExtension.lowercased())
        } catch {
            // The import goes on without a cover (the shelf draws a generated one); the
            // archive itself was already read by `inspect`, so this is worth a log line.
            AppLogger.parse(
                "Comic archive cover could not be read",
                error: error,
                context: ["archive": archiveURL.lastPathComponent],
                level: .warning
            )
            return nil
        }
    }

    private static func comicInfo(in index: LocalMangaArchiveIndex) async -> LocalMangaComicInfo? {
        // Most archives carry no ComicInfo.xml at all; that is not a failure.
        guard let path = index.entriesByPath.keys
            .filter({ $0.lowercased().hasSuffix("comicinfo.xml") })
            .min()
        else { return nil }
        do {
            let data = try await index.data(forEntryPath: path)
            guard let xml = String(data: data, encoding: .utf8) else {
                AppLogger.parse(
                    "Comic archive ComicInfo.xml is not UTF-8; importing without it",
                    context: ["archive": index.url.lastPathComponent],
                    level: .warning
                )
                return nil
            }
            return LocalMangaComicInfoParser.parse(xml)
        } catch {
            AppLogger.parse(
                "Comic archive ComicInfo.xml could not be read; importing without it",
                error: error,
                context: ["archive": index.url.lastPathComponent],
                level: .warning
            )
            return nil
        }
    }

    // MARK: Legacy extracted pages (builds up to 2.0.7)

    /// Where builds up to 2.0.7 extracted every page of a local comic at import:
    /// `Application Support/local_manga/<bookId>/<chapter>/<n>.<ext>`. Nothing reads
    /// it any more; it is only ever deleted.
    static var legacyExtractedPagesRoot: URL {
        StorageLocations.applicationSupportRoot.appendingPathComponent("local_manga", isDirectory: true)
    }

    static func legacyExtractedPagesDirectory(bookId: UUID, root: URL = legacyExtractedPagesRoot) -> URL {
        root.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    /// Migration for books imported before pages were read from the archive: once the
    /// book's own archive has opened and listed at least one page, its extracted copy
    /// is dead weight (as large as the book), so it goes — once, the first time the
    /// book is opened (`FixedPageReaderViewController.loadLocalChapter`).
    ///
    /// The archive is verified here rather than assumed: `Documents` is visible in the
    /// Files app, and a user who deleted the `.cbz` there may have the extracted pages
    /// as the only copy left. Those are kept (and logged), never deleted.
    ///
    /// Returns whether a legacy directory was removed.
    @discardableResult
    static func discardLegacyExtractedPages(
        bookId: UUID,
        archiveURL: URL,
        root: URL = legacyExtractedPagesRoot
    ) async -> Bool {
        let directory = legacyExtractedPagesDirectory(bookId: bookId, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        do {
            // Its own open, not the reader's: verifying many books (a sweep) must not
            // evict the archive of the book being read. Throws when no page is listed.
            _ = try await LocalMangaArchiveIndex.open(archiveURL)
        } catch {
            AppLogger.cache(
                "Legacy extracted comic pages kept: the book's archive cannot be read",
                error: error,
                context: ["book": bookId.uuidString, "archive": archiveURL.lastPathComponent],
                level: .warning
            )
            return false
        }
        return removeLegacyExtractedPages(bookId: bookId, root: root)
    }

    /// Delete a book's legacy extracted pages, and the `local_manga` root once nothing is
    /// left in it. A book with none (everything imported since, every PDF and fixed-layout
    /// EPUB) is not an error. Returns whether a directory was removed.
    @discardableResult
    static func removeLegacyExtractedPages(bookId: UUID, root: URL = legacyExtractedPagesRoot) -> Bool {
        let fileManager = FileManager.default
        let directory = legacyExtractedPagesDirectory(bookId: bookId, root: root)
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            AppLogger.cache(
                "Legacy extracted comic pages could not be removed",
                error: error,
                context: ["book": bookId.uuidString]
            )
            return false
        }
        AppLogger.cache("Removed legacy extracted comic pages", context: ["book": bookId.uuidString])
        do {
            if try fileManager.contentsOfDirectory(atPath: root.path).isEmpty {
                try fileManager.removeItem(at: root)
            }
        } catch {
            AppLogger.cache("Legacy local_manga root could not be tidied", error: error)
        }
        return true
    }

    // MARK: Helpers

    fileprivate static func isImageEntryPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.hasPrefix(".") else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
        return allowedImageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func cleanTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-,"))
    }
}

// MARK: - Archive index

/// An opened comic archive: its central directory read once into a path lookup, and its
/// page images in reading order. Reading a page is one entry's bytes, in memory.
struct LocalMangaArchiveIndex: Sendable {
    let url: URL
    let archive: Archive
    /// First entry wins for a duplicated path, as `Archive.get(_:)` does.
    let entriesByPath: [String: Entry]
    let imagePaths: [String]

    static func open(_ archiveURL: URL) async throws -> LocalMangaArchiveIndex {
        let archive: Archive
        let entries: [Entry]
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
            entries = try await archive.entries()
        } catch {
            AppLogger.parse(
                "Comic archive could not be opened",
                error: error,
                context: ["archive": archiveURL.lastPathComponent]
            )
            throw LocalMangaArchiveError.cannotReadArchive
        }

        var entriesByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file && entriesByPath[entry.path] == nil {
            entriesByPath[entry.path] = entry
        }
        let imagePaths = entriesByPath.keys
            .filter(LocalMangaArchive.isImageEntryPath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !imagePaths.isEmpty else { throw LocalMangaArchiveError.noImagesFound }
        return LocalMangaArchiveIndex(
            url: archiveURL,
            archive: archive,
            entriesByPath: entriesByPath,
            imagePaths: imagePaths
        )
    }

    /// One entry's uncompressed bytes. Nothing touches the disk but the read itself.
    func data(forEntryPath path: String) async throws -> Data {
        guard let entry = entriesByPath[path] else {
            AppLogger.parse(
                "Comic archive has no entry at the requested path",
                context: ["archive": url.lastPathComponent, "entry": (path as NSString).lastPathComponent],
                level: .error
            )
            throw LocalMangaArchiveError.cannotReadArchive
        }
        // The declared size only reserves capacity; capped, so a lying header cannot ask for gigabytes up front.
        let buffer = EntryBuffer(capacity: Int(clamping: min(entry.uncompressedSize, 32 << 20)))
        _ = try await archive.extract(entry, skipCRC32: true) { chunk in
            try Task.checkCancellation()
            buffer.append(chunk)
        }
        return buffer.data
    }
}

/// Collects one entry's chunks. `Archive.extract` calls its consumer sequentially, one
/// chunk at a time, so the buffer is never touched from two places at once.
private final class EntryBuffer: @unchecked Sendable {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data(capacity: capacity)
    }

    func append(_ chunk: Data) {
        data.append(chunk)
    }
}

// MARK: - Reader

/// The archive of the comic being read, kept open for the whole reading session so a page
/// turn is one entry read, never a reopen and re-scan of the central directory. Holds one
/// book at a time — opening another replaces it — and no file descriptor while idle (each
/// read opens and closes its own), so keeping it after the reader closes costs only the
/// in-memory index. There is no disk cache: decoded pages live in Nuke's memory cache,
/// keyed by `FixedPageImageLoader.request(for:)`.
actor LocalMangaArchiveReader {
    static let shared = LocalMangaArchiveReader()

    private var current: LocalMangaArchiveIndex?
    /// In-flight opens, so a chapter load and the page loads racing it open the archive once.
    private var openTasks: [URL: Task<LocalMangaArchiveIndex, Error>] = [:]

    func imageEntryPaths(in archiveURL: URL) async throws -> [String] {
        try await index(for: archiveURL).imagePaths
    }

    func data(entryPath: String, in archiveURL: URL) async throws -> Data {
        let opened = try await index(for: archiveURL)
        let t0 = SourcePerfTrace.now
        let data = try await opened.data(forEntryPath: entryPath)
        SourcePerfTrace.record(
            "comic.archive.page",
            "\((entryPath as NSString).lastPathComponent) bytes=\(data.count)",
            since: t0,
            thresholdMs: 2
        )
        return data
    }

    private func index(for archiveURL: URL) async throws -> LocalMangaArchiveIndex {
        if let current, current.url == archiveURL { return current }
        if let task = openTasks[archiveURL] { return try await task.value }

        let task = Task {
            try await SourcePerfTrace.spanAsync("comic.archive.open", archiveURL.lastPathComponent) {
                try await LocalMangaArchiveIndex.open(archiveURL)
            }
        }
        openTasks[archiveURL] = task
        defer { openTasks[archiveURL] = nil }
        let opened = try await task.value
        current = opened
        return opened
    }
}

private final class LocalMangaComicInfoParser: NSObject, XMLParserDelegate {
    private var currentValue = ""

    private var title: String?
    private var series: String?
    private var number: String?
    private var volume: Int?
    private var summary: String?
    private var writer: String?
    private var penciller: String?
    private var manga: String?

    static func parse(_ xml: String) -> LocalMangaComicInfo? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = LocalMangaComicInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return LocalMangaComicInfo(
            title: delegate.title,
            series: delegate.series,
            number: delegate.number,
            volume: delegate.volume,
            summary: delegate.summary,
            writer: delegate.writer,
            penciller: delegate.penciller,
            manga: delegate.manga
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch elementName {
            case "Title": title = value
            case "Series": series = value
            case "Number": number = value
            case "Volume": volume = Int(value)
            case "Summary": summary = value
            case "Writer": writer = value
            case "Penciller": penciller = value
            case "Manga": manga = value
            default: break
            }
        }
        currentValue = ""
    }
}
