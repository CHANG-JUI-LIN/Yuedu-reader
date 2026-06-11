import CryptoKit
import Foundation

final class SearchResultCache {
    static let shared = SearchResultCache()

    struct Entry: Codable {
        var books: [CachedBook]
        var timestamp: Date
    }

    struct CachedBook: Codable {
        var name: String
        var author: String
        var intro: String
        var coverUrl: String
        var bookUrl: String
        var tocUrl: String
        var wordCount: String
        var lastChapter: String
        var kind: String
        var runtimeVariables: [String: String]?

        init(_ book: OnlineBook) {
            name = book.name
            author = book.author
            intro = book.intro
            coverUrl = book.coverUrl
            bookUrl = book.bookUrl
            tocUrl = book.tocUrl
            wordCount = book.wordCount
            lastChapter = book.lastChapter
            kind = book.kind
            runtimeVariables = book.runtimeVariables
        }

        func onlineBook(for source: BookSource) -> OnlineBook {
            OnlineBook(
                name: name,
                author: author,
                intro: intro,
                coverUrl: coverUrl,
                bookUrl: bookUrl,
                tocUrl: tocUrl,
                wordCount: wordCount,
                lastChapter: lastChapter,
                kind: kind,
                sourceId: source.id,
                sourceName: source.bookSourceName,
                runtimeVariables: runtimeVariables
            )
        }
    }

    private let queue = DispatchQueue(label: "com.yuedu.searchResultCache")
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SearchResultCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func freshBooks(
        query: String,
        source: BookSource,
        days: Int,
        now: Date = Date()
    ) -> [OnlineBook]? {
        guard days > 0, let key = cacheKey(query: query, source: source) else { return nil }
        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL(for: key)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data)
            else { return nil }
            let maxAge = TimeInterval(days) * 86_400
            guard now.timeIntervalSince(entry.timestamp) < maxAge else { return nil }
            return entry.books.map { $0.onlineBook(for: source) }
        }
    }

    func store(
        books: [OnlineBook],
        query: String,
        source: BookSource,
        days: Int,
        now: Date = Date()
    ) {
        guard days > 0, let key = cacheKey(query: query, source: source) else { return }
        let entry = Entry(books: books.map(CachedBook.init), timestamp: now)
        queue.sync {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: fileURL(for: key), options: .atomic)
        }
    }

    func clear(query: String, source: BookSource) {
        guard let key = cacheKey(query: query, source: source) else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(for: key))
        }
    }

    func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private func cacheKey(query: String, source: BookSource) -> String? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }
        let rawKey = [
            normalizedQuery,
            source.bookSourceUrl,
            source.searchUrl,
            source.ruleSearch.bookList,
            source.ruleSearch.name,
            source.ruleSearch.author,
            source.ruleSearch.bookUrl,
            source.lastUpdateTime.description
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
