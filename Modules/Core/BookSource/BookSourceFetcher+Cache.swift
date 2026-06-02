import CryptoKit
import Foundation

// MARK: - TOC + BookInfo Cache Management

extension BookSourceFetcher {

    nonisolated func tocCacheDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("toc_cache")
    }

    nonisolated func bookInfoCacheDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("book_info_cache")
    }

    nonisolated func loadTOCPackageSync(tocUrl: String, source: BookSource) -> TOCPackage? {
        let path = tocPackagePath(tocUrl: tocUrl, source: source)
        guard let data = try? Data(contentsOf: path),
            let package = try? JSONDecoder().decode(TOCPackage.self, from: data),
            normalizedURLKey(package.tocURL) == normalizedURLKey(tocUrl),
            package.sourceId == source.id
        else {
            return nil
        }
        return package
    }

    nonisolated func loadBookInfoPackageSync(url: String, source: BookSource) -> BookInfoPackage? {
        let path = bookInfoPackagePath(url: url, source: source)
        guard let data = try? Data(contentsOf: path),
            let package = try? JSONDecoder().decode(BookInfoPackage.self, from: data),
            normalizedURLKey(package.bookURL) == normalizedURLKey(url),
            package.sourceId == source.id
        else {
            return nil
        }
        return package
    }

    @discardableResult
    nonisolated func saveTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        chapters: [OnlineChapterRef],
        rawHTML: String?
    ) -> TOCPackage {
        let dir = tocCacheDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawPath = tocRawHTMLPath(tocUrl: tocUrl, source: source)
        // rawHTML may have been written to disk by caller page by page; check if file exists
        let hasRawHTML = (rawHTML?.isEmpty == false)
            || FileManager.default.fileExists(atPath: rawPath.path)
        let package = TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: tocUrl,
            runtimeVariables: runtimeVariables,
            chapters: chapters,
            rawHTMLFilename: hasRawHTML ? rawPath.lastPathComponent : nil,
            savedAt: Date()
        )
        if let rawHTML, !rawHTML.isEmpty {
            try? rawHTML.write(to: rawPath, atomically: true, encoding: .utf8)
        }
        if let data = try? JSONEncoder().encode(package) {
            try? data.write(to: tocPackagePath(tocUrl: tocUrl, source: source), options: .atomic)
        }
        return package
    }

    @discardableResult
    nonisolated func saveBookInfoPackage(
        info: OnlineBook,
        source: BookSource,
        rawHTML: String?
    ) -> BookInfoPackage {
        let dir = bookInfoCacheDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawPath = bookInfoRawHTMLPath(url: info.bookUrl, source: source)
        if let rawHTML, !rawHTML.isEmpty {
            try? rawHTML.write(to: rawPath, atomically: true, encoding: .utf8)
        }
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
            rawHTMLFilename: rawHTML?.isEmpty == false ? rawPath.lastPathComponent : nil,
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

    private nonisolated func tocPackagePath(tocUrl: String, source: BookSource) -> URL {
        tocCacheDir().appendingPathComponent("\(tocCacheKey(tocUrl: tocUrl, source: source)).json")
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
