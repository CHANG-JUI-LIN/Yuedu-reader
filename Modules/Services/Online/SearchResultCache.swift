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

        init(_ book: OnlineBook, source: BookSource) {
            name = book.name
            author = book.author
            intro = book.intro
            coverUrl = SearchResultCoverURLPolicy.normalizedString(
                book.coverUrl,
                baseURL: source.bookSourceUrl
            )
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
                coverUrl: SearchResultCoverURLPolicy.normalizedString(
                    coverUrl,
                    baseURL: source.bookSourceUrl
                ),
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

    /// Writes only. There is deliberately NO lock or serial queue around reads:
    /// every entry lives in its own file keyed by a content hash, and writes are
    /// atomic (temp file + rename), so a concurrent reader sees either the old or
    /// the new bytes, never a torn one. The previous `DispatchQueue.sync` protected
    /// nothing that atomicity does not already give — but it did funnel every
    /// source's cache I/O through one lane AND block a Swift cooperative-pool
    /// thread while it waited, so a wide search fan-out could stall the pool before
    /// its requests even went out.
    private let writeQueue = DispatchQueue(
        label: "com.yuedu.searchResultCache.write", qos: .utility
    )
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
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        let maxAge = TimeInterval(days) * 86_400
        guard now.timeIntervalSince(entry.timestamp) < maxAge else { return nil }
        // Never serve an empty cached result. A transient 0 (request timed out,
        // searched before logging in, server hiccup) must not get pinned for
        // `days` — fall through to a live re-fetch instead of returning [].
        guard !entry.books.isEmpty else { return nil }
        return entry.books.map { $0.onlineBook(for: source) }
    }

    func store(
        books: [OnlineBook],
        query: String,
        source: BookSource,
        days: Int,
        now: Date = Date()
    ) {
        // Don't persist empty results: caching a 0 would make a transient failure
        // (timeout / not-yet-logged-in / server hiccup) sticky for `days`.
        guard days > 0, !books.isEmpty, let key = cacheKey(query: query, source: source) else { return }
        let entry = Entry(
            books: books.map { CachedBook($0, source: source) },
            timestamp: now
        )
        // Fire-and-forget: nothing waits on the cache being written, and encoding a
        // 500-book aggregate result is heavy enough that doing it inline made the
        // search path pay for the *next* search's speed-up. Losing an entry to an
        // app kill just costs one re-fetch.
        let url = fileURL(for: key)
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func clear(query: String, source: BookSource) {
        guard let key = cacheKey(query: query, source: source) else { return }
        let url = fileURL(for: key)
        writeQueue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearAll() {
        let directory = self.directory
        writeQueue.sync {
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
        var parts = [
            normalizedQuery,
            source.bookSourceUrl,
            source.searchUrl,
            source.ruleSearch.bookList,
            source.ruleSearch.name,
            source.ruleSearch.author,
            source.ruleSearch.bookUrl,
            source.lastUpdateTime.description
        ]
        if let settings = Self.searchScopeSettings(for: source) {
            parts.append(settings)
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The rule text alone does not determine what a source searches: aggregate sources
    /// (光遇/大灰狼/书山…) resolve their sub-site filter from the `更多设置` bucket the user
    /// edits in the source's own 书源设置 page (`sourcesKey = 更多设置[搜索模式]`). Ticking
    /// 默认搜索网站 therefore has to change the cache key, or the previously cached 全部
    /// results keep being served for the whole TTL and the setting looks broken.
    ///
    /// Only this bucket is included: the rest of the runtime variable is churn (线路,
    /// 云端配置, tokens, 发现页 state) that would make the cache useless without ever
    /// changing what search returns. Nothing to include for sources that don't use it.
    private static func searchScopeSettings(for source: BookSource) -> String? {
        let variables = BookSourceRuntimeStateStore.shared.sourceVariables(for: source.bookSourceUrl)
        guard let settings = variables["更多设置"] as? [String: Any], !settings.isEmpty,
              JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(
                  withJSONObject: settings, options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }
}
